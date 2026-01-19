#!/usr/bin/env bash
#
# Reset Demo State
#
# Cleans up GitLab MRs and resets state for fresh demo/validation runs.
#
# Usage:
#   ./scripts/03-pipelines/reset-demo-state.sh
#
# What it does:
#   1. Closes open promotion MRs (promote-stage-*, promote-prod-*)
#   2. Closes open update-dev MRs (update-dev-*)
#   3. Closes UC-C1 demo MRs and branches (uc-c1-*)
#   4. Resets CUE configuration files on env branches to match main
#   5. Removes demo-specific labels (cost-center) from manifests
#   6. Resets example-app/pom.xml version to 1.0.0-SNAPSHOT
#
# What it preserves:
#   - env.cue files (they have valid CI/CD-managed images)
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
# Close MRs matching pattern
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
# Remove demo labels from manifests on env branches
# =============================================================================
remove_demo_labels_from_manifests() {
    local label_pattern="$1"  # e.g., "cost-center"

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    # Manifest files to clean
    local manifest_files=(
        "manifests/exampleApp/exampleApp.yaml"
        "manifests/postgres/postgres.yaml"
    )

    for branch in dev stage prod; do
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
    done
}

# =============================================================================
# Reset CUE configuration on environment branches
# =============================================================================
reset_cue_config() {
    log_step "Resetting CUE configuration on environment branches..."

    # Files that demos might modify
    local cue_files=(
        "services/core/app.cue"
        "services/resources/deployment.cue"
    )

    for file in "${cue_files[@]}"; do
        log_info "Syncing $file from main..."
        sync_file_to_env_branches "$file" "chore: reset $file from main for demo"
    done

    # Remove demo-specific labels from manifests
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
    echo "This script cleans up for fresh demo/validation runs."
    echo "It resets CUE config on env branches but preserves CI/CD-managed images."
    echo ""

    get_credentials

    # Close promotion MRs in k8s-deployments
    log_step "Closing promotion MRs in k8s-deployments..."
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^promote-stage-" "stage"
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^promote-prod-" "prod"

    # Close update-dev MRs in k8s-deployments
    log_step "Closing update-dev MRs in k8s-deployments..."
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^update-dev-" "dev"

    # Close UC-C1 demo MRs and branches
    log_step "Closing UC-C1 demo MRs in k8s-deployments..."
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^uc-c1-" "dev"
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^uc-c1-" "stage"
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^uc-c1-" "prod"

    # Reset CUE configuration on environment branches
    reset_cue_config

    # Reset app version
    reset_app_version "1.0.0-SNAPSHOT"

    echo ""
    echo "=== Reset Complete ==="
    echo ""
    log_info "Next steps:"
    log_info "  1. Commit any local changes: git add -A && git commit -m 'chore: reset demo state'"
    log_info "  2. Push to GitHub: git push origin main"
    log_info "  3. Run demo: ./scripts/demo/demo-uc-c1-default-label.sh"
    echo ""
    log_info "Note: env.cue files (with CI/CD-managed images) were preserved."
}

main "$@"
