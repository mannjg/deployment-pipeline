#!/usr/bin/env bash
#
# Reset Demo State
#
# Cleans up GitLab MRs and resets app version for fresh validation runs.
# Does NOT touch k8s-deployments environment branches - those have valid
# CI/CD-managed images that should be preserved.
#
# Usage:
#   ./scripts/03-pipelines/reset-demo-state.sh
#
# What it does:
#   1. Closes open promotion MRs (promote-stage-*, promote-prod-*)
#   2. Closes open update-dev MRs (update-dev-*)
#   3. Resets example-app/pom.xml version to 1.0.0-SNAPSHOT
#
# What it does NOT do:
#   - Delete or modify k8s-deployments environment branches
#   - Touch env.cue files (they have valid CI/CD-managed images)
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
    echo "This script cleans up for fresh validation runs WITHOUT destroying"
    echo "the k8s-deployments environment branches (which have valid images)."
    echo ""

    get_credentials

    # Close promotion MRs in k8s-deployments
    log_step "Closing promotion MRs in k8s-deployments..."
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^promote-stage-" "stage"
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^promote-prod-" "prod"

    # Close update-dev MRs in k8s-deployments
    log_step "Closing update-dev MRs in k8s-deployments..."
    close_mrs_matching "$DEPLOYMENTS_REPO_PATH" "^update-dev-" "dev"

    # Reset app version
    reset_app_version "1.0.0-SNAPSHOT"

    echo ""
    echo "=== Reset Complete ==="
    echo ""
    log_info "Next steps:"
    log_info "  1. Commit the version change: git add -A && git commit -m 'chore: reset demo state'"
    log_info "  2. Push to GitHub: git push origin main"
    log_info "  3. Run validation: ./scripts/test/validate-pipeline.sh"
    echo ""
    log_warn "Note: Environment branches (dev/stage/prod) were NOT modified."
    log_warn "They retain their valid CI/CD-managed images."
}

main "$@"
