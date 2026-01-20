#!/usr/bin/env bash
#
# Reset Demo State
#
# Establishes a well-defined starting point for demos by cleaning up ALL
# demo artifacts, regardless of which demo was run.
#
# Usage:
#   ./scripts/03-pipelines/reset-demo-state.sh
#
# Clean Starting Point:
#   - No open MRs targeting dev, stage, or prod branches
#   - Jenkinsfile on all env branches synced from main
#   - CUE configuration on dev matches main (no demo modifications)
#   - Manifests on dev have no demo-specific labels
#   - App version at 1.0.0-SNAPSHOT
#
# What it does:
#   1. Closes ALL open MRs targeting environment branches (dev, stage, prod)
#      - Feature branch MRs (uc-c1-*, update-dev-*, etc.)
#      - Promotion MRs (promote-stage-*, promote-prod-*)
#      - GitOps promotion MRs (dev→stage, stage→prod)
#   2. Deletes feature branches (but preserves dev/stage/prod/main)
#   3. Syncs Jenkinsfile from main to all env branches
#   4. Resets CUE configuration files on dev to match main
#   5. Removes demo-specific labels (cost-center) from dev manifests
#   6. Resets example-app/pom.xml version to 1.0.0-SNAPSHOT
#
# What it preserves:
#   - env.cue files (they have valid CI/CD-managed images)
#   - Environment branches (dev, stage, prod, main)
#   - Environment-specific configuration (namespaces, replicas, etc.)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${BLUE}[->]${NC} $*"; }

# Load infrastructure config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
    source "$REPO_ROOT/config/infra.env"
else
    log_error "Cannot find config/infra.env"
    exit 1
fi

# =============================================================================
# Get Credentials
# =============================================================================
get_credentials() {
    log_step "Loading credentials..."

    # Get GITLAB_TOKEN (env var or K8s secret)
    GITLAB_TOKEN="${GITLAB_TOKEN:-}"
    if [[ -z "$GITLAB_TOKEN" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "${GITLAB_API_TOKEN_SECRET}" -n "${GITLAB_NAMESPACE}" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "$GITLAB_TOKEN" ]]; then
        log_error "GITLAB_TOKEN not set and could not retrieve from K8s secret"
        exit 1
    fi

    GITLAB_URL="https://${GITLAB_HOST_EXTERNAL}"
    log_info "GitLab: $GITLAB_URL"
}

# =============================================================================
# Close ALL open MRs targeting environment branches
# =============================================================================
# This ensures a clean starting point regardless of what demo was run.
# The GitOps promotion flow creates MRs from various sources:
# - Feature branches (uc-c1-*, update-dev-*, promote-*)
# - Environment branches (dev→stage, stage→prod)
# All of these need to be closed for a clean reset.
close_all_env_mrs() {
    local project_path="$1"
    local encoded_project=$(echo "$project_path" | sed 's/\//%2F/g')

    log_info "Closing ALL open MRs targeting environment branches..."

    # Close MRs targeting each environment branch
    for target_branch in dev stage prod; do
        local api_url="$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_branch"
        local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$api_url" 2>/dev/null)

        if [[ -z "$mrs" ]] || [[ "$mrs" == "[]" ]]; then
            log_info "  $target_branch: no open MRs"
            continue
        fi

        # Get all MRs (no pattern filtering)
        local all_mrs=$(echo "$mrs" | jq -r '.[] | "\(.iid):\(.source_branch)"')

        if [[ -z "$all_mrs" ]]; then
            log_info "  $target_branch: no open MRs"
            continue
        fi

        local count=0
        while IFS=: read -r mr_iid source_branch; do
            if [[ -n "$mr_iid" ]]; then
                log_info "  Closing MR !$mr_iid ($source_branch → $target_branch)..."

                # Close the MR
                curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid" \
                    -d "state_event=close" >/dev/null 2>&1 || true

                # Delete the source branch ONLY if it's not an environment branch
                if [[ "$source_branch" != "dev" && "$source_branch" != "stage" && "$source_branch" != "prod" && "$source_branch" != "main" ]]; then
                    curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$source_branch" \
                        >/dev/null 2>&1 || true
                fi

                count=$((count + 1))
            fi
        done <<< "$all_mrs"

        log_info "  $target_branch: closed $count MRs"
    done
}

# =============================================================================
# Close MRs matching pattern (kept for backward compatibility)
# =============================================================================
close_mrs_matching() {
    local project_path="$1"
    local branch_pattern="$2"
    local target_branch="${3:-}"

    local encoded_project=$(echo "$project_path" | sed 's/\//%2F/g')

    # Build API URL
    local api_url="$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened"
    if [[ -n "$target_branch" ]]; then
        api_url="${api_url}&target_branch=$target_branch"
    fi

    # Get open MRs
    local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$api_url" 2>/dev/null)

    if [[ -z "$mrs" ]] || [[ "$mrs" == "[]" ]]; then
        log_info "No open MRs found"
        return 0
    fi

    # Find MRs matching the branch pattern
    local matching_mrs=$(echo "$mrs" | jq -r --arg pattern "$branch_pattern" \
        '.[] | select(.source_branch | test($pattern)) | "\(.iid):\(.source_branch)"')

    if [[ -z "$matching_mrs" ]]; then
        log_info "No MRs matching pattern: $branch_pattern"
        return 0
    fi

    local count=0
    while IFS=: read -r mr_iid source_branch; do
        if [[ -n "$mr_iid" ]]; then
            log_info "Closing MR !$mr_iid ($source_branch)..."

            # Close the MR
            curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid" \
                -d "state_event=close" >/dev/null 2>&1 || true

            # Delete the source branch
            curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$source_branch" \
                >/dev/null 2>&1 || true

            count=$((count + 1))
        fi
    done <<< "$matching_mrs"

    log_info "Closed $count MRs matching: $branch_pattern"
}

# =============================================================================
# Sync file from main to environment branches
# =============================================================================
sync_file_to_env_branches() {
    local file_path="$1"
    local commit_message="${2:-chore: sync $file_path from main}"

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')
    local encoded_file=$(echo "$file_path" | sed 's/\//%2F/g')

    # Get file content from main branch
    local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

    if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
        log_warn "Could not get $file_path from main branch"
        return 1
    fi

    local content_b64=$(echo "$main_content" | jq -r '.content')

    # Update on each environment branch
    for branch in dev stage prod; do
        local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"$commit_message\"}" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

        if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
            log_info "  $branch: synced"
        else
            local error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
            # "A file with this name doesn't exist" means branch doesn't have this file yet
            if [[ "$error" == *"doesn't exist"* ]]; then
                log_info "  $branch: file doesn't exist (skipping)"
            else
                log_warn "  $branch: $error"
            fi
        fi
    done
}

# =============================================================================
# Remove demo labels from manifests on ONLY the dev branch
# =============================================================================
# NOTE: We only clean dev manifests because:
# 1. Jenkins regenerates manifests during MR processing
# 2. Modifying stage/prod manifests creates merge conflicts when
#    the same feature branch is promoted through environments
# 3. Dev is the first target, so it needs to show the diff properly
remove_demo_labels_from_manifests() {
    local label_pattern="$1"  # e.g., "cost-center"

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    # Manifest files to clean
    local manifest_files=(
        "manifests/exampleApp/exampleApp.yaml"
        "manifests/postgres/postgres.yaml"
    )

    # Only clean dev branch - stage/prod will be handled by Jenkins during MR
    local branch="dev"
    log_info "Cleaning manifests on $branch branch..."

    for manifest_path in "${manifest_files[@]}"; do
        local encoded_file=$(echo "$manifest_path" | sed 's/\//%2F/g')

        # Get current manifest
        local file_info=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=$branch" 2>/dev/null)

        if [[ -z "$file_info" ]] || ! echo "$file_info" | jq -e '.content' > /dev/null 2>&1; then
            continue
        fi

        local content=$(echo "$file_info" | jq -r '.content' | base64 -d)

        # Check if label exists in manifest
        if ! echo "$content" | grep -q "$label_pattern"; then
            continue
        fi

        # Remove lines containing the label pattern
        local cleaned_content=$(echo "$content" | grep -v "$label_pattern")
        local cleaned_b64=$(echo "$cleaned_content" | base64 -w0)

        # Update the manifest
        local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$cleaned_b64\", \"commit_message\": \"chore: remove $label_pattern labels for demo reset\"}" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

        if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
            log_info "  $branch/$manifest_path: cleaned"
        fi
    done
}

# =============================================================================
# Sync Jenkinsfile from main to all environment branches
# =============================================================================
# This ensures all env branches have the latest pipeline logic, especially
# important for env-to-env MR support (dev→stage, stage→prod).
sync_jenkinsfile_to_env_branches() {
    log_step "Syncing Jenkinsfile to environment branches..."

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')
    local encoded_file="Jenkinsfile"

    # Get Jenkinsfile from main
    local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

    if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
        log_warn "Could not get Jenkinsfile from main branch"
        return 1
    fi

    local content_b64=$(echo "$main_content" | jq -r '.content')

    # Sync to each environment branch
    for branch in dev stage prod; do
        local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: sync Jenkinsfile from main\"}" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

        if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
            log_info "  $branch: synced"
        else
            local error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
            if [[ "$error" == *"already exists"* ]] || [[ "$error" == *"same content"* ]]; then
                log_info "  $branch: already up to date"
            else
                log_warn "  $branch: $error"
            fi
        fi
    done
}

# =============================================================================
# Reset CUE configuration on the dev branch only
# =============================================================================
# NOTE: We only reset dev because:
# 1. The demo workflow promotes changes from dev → stage → prod via MRs
# 2. Resetting stage/prod would create merge conflicts when the feature
#    branch (which has the changes) tries to merge to those environments
# 3. Stage/prod will naturally get the changes when MRs are merged
reset_cue_config() {
    log_step "Resetting CUE configuration on dev branch..."

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    # Files that demos might modify
    local cue_files=(
        "services/core/app.cue"
        "services/resources/deployment.cue"
    )

    for file_path in "${cue_files[@]}"; do
        local encoded_file=$(echo "$file_path" | sed 's/\//%2F/g')

        # Get file content from main branch
        local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

        if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
            log_warn "Could not get $file_path from main branch"
            continue
        fi

        local content_b64=$(echo "$main_content" | jq -r '.content')

        # Only update dev branch
        log_info "Syncing $file_path to dev..."
        local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"branch\": \"dev\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: reset $file_path from main for demo\"}" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

        if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
            log_info "  dev: synced"
        else
            local error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
            log_warn "  dev: $error"
        fi
    done

    # Remove demo-specific labels from manifests (dev only)
    log_step "Removing demo labels from manifests..."
    remove_demo_labels_from_manifests "cost-center"
}

# =============================================================================
# Reset App Version
# =============================================================================
reset_app_version() {
    local target_version="${1:-1.0.0-SNAPSHOT}"
    local pom_file="$REPO_ROOT/example-app/pom.xml"

    log_step "Resetting app version to $target_version..."

    if [[ ! -f "$pom_file" ]]; then
        log_error "pom.xml not found at $pom_file"
        return 1
    fi

    # Get current version
    local current_version=$(grep -o '<version>[^<]*</version>' "$pom_file" | head -1 | sed 's/<[^>]*>//g')

    if [[ "$current_version" == "$target_version" ]]; then
        log_info "Version already at $target_version"
        return 0
    fi

    log_info "Current version: $current_version"
    log_info "Target version: $target_version"

    # Update the version (first occurrence only)
    sed -i "0,/<version>$current_version<\/version>/s/<version>$current_version<\/version>/<version>$target_version<\/version>/" "$pom_file"

    # Verify the change
    local new_version=$(grep -o '<version>[^<]*</version>' "$pom_file" | head -1 | sed 's/<[^>]*>//g')
    if [[ "$new_version" == "$target_version" ]]; then
        log_info "Version updated successfully"
    else
        log_error "Version update failed"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "=== Reset Demo State ==="
    echo ""
    echo "This script establishes a well-defined starting point for demos."
    echo ""
    echo "CLEAN STARTING POINT:"
    echo "  - No open MRs targeting dev, stage, or prod branches"
    echo "  - Jenkinsfile synced from main to all env branches"
    echo "  - CUE configuration on dev matches main (no demo modifications)"
    echo "  - Manifests on dev have no demo-specific labels"
    echo "  - env.cue files preserved (valid CI/CD-managed images)"
    echo "  - App version at 1.0.0-SNAPSHOT"
    echo ""

    get_credentials

    # Close ALL open MRs targeting environment branches
    # This handles all scenarios:
    # - Feature branch MRs (uc-c1-*, update-dev-*, etc.)
    # - Promotion MRs (promote-stage-*, promote-prod-*)
    # - GitOps promotion MRs (dev→stage, stage→prod)
    log_step "Closing ALL open MRs targeting environment branches..."
    close_all_env_mrs "$DEPLOYMENTS_REPO_PATH"

    # Sync Jenkinsfile to ensure all env branches have latest pipeline logic
    sync_jenkinsfile_to_env_branches

    # Reset CUE configuration on environment branches
    reset_cue_config

    # Reset app version
    reset_app_version "1.0.0-SNAPSHOT"

    echo ""
    echo "=== Reset Complete ==="
    echo ""
    log_info "Clean starting point established:"
    log_info "  - All env-targeting MRs closed"
    log_info "  - Jenkinsfile synced to all env branches"
    log_info "  - Dev branch CUE config synced from main"
    log_info "  - Dev branch manifests cleaned"
    log_info "  - App version at 1.0.0-SNAPSHOT"
    echo ""
    log_info "Next steps:"
    log_info "  1. Commit any local changes: git add -A && git commit -m 'chore: reset demo state'"
    log_info "  2. Push to GitHub: git push origin main"
    log_info "  3. Run demo: ./scripts/demo/demo-uc-c1-default-label.sh"
    echo ""
    log_info "Note: env.cue files (with CI/CD-managed images) were preserved."
}

main "$@"
