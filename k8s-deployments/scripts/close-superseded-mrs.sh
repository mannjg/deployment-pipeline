#!/bin/bash
set -euo pipefail

# Close superseded GitLab merge requests before creating a new one (JENKINS-27)
#
# When rapid builds create multiple MRs to the same target, this script closes
# the stale ones so operators only see the latest.
#
# Usage: ./close-superseded-mrs.sh <target_branch> <branch_prefix> <new_branch>
#
# Environment:
#   GITLAB_TOKEN          - GitLab API token
#   GITLAB_URL_INTERNAL   - GitLab base URL
#   GITLAB_GROUP          - Project group (e.g., p2c)
#
# Exit code: 0 for all operational outcomes (supersession is best-effort).
#   Preflight failures (missing config) are fatal by design.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load preflight library and local config
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Preflight checks
preflight_check_required GITLAB_URL_INTERNAL GITLAB_GROUP GITLAB_TOKEN

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Validate arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <target_branch> <branch_prefix> <new_branch>"
    echo ""
    echo "Closes open MRs whose source branch starts with <branch_prefix>"
    echo "and targets <target_branch>, excluding <new_branch>."
    echo ""
    echo "Example:"
    echo "  $0 dev update-dev update-dev-1.0.0-SNAPSHOT-abc123"
    exit 0  # Not an error — script is best-effort
fi

TARGET_BRANCH=$1
BRANCH_PREFIX=$2
NEW_BRANCH=$3

# GitLab configuration (from preflight-validated environment)
GITLAB_URL=${GITLAB_URL_INTERNAL}
PROJECT_PATH="${GITLAB_GROUP}/k8s-deployments"
PROJECT_PATH_ENCODED=$(echo "$PROJECT_PATH" | sed 's/\//%2F/g')

# Query open MRs targeting the specified branch
RESPONSE=$(curl -sf \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}/merge_requests?state=opened&target_branch=${TARGET_BRANCH}&per_page=100" \
    2>/dev/null) || {
    log_warn "Could not query open MRs (non-fatal)"
    exit 0
}

# Filter: source_branch starts with prefix AND is not the new branch
STALE_MRS=$(echo "$RESPONSE" | jq -r \
    --arg prefix "${BRANCH_PREFIX}" \
    --arg exclude "${NEW_BRANCH}" \
    '.[] | select(.source_branch | startswith($prefix)) | select(.source_branch != $exclude) | "\(.iid) \(.source_branch)"') || {
    log_warn "Could not parse MR response (non-fatal)"
    exit 0
}

if [ -z "${STALE_MRS}" ]; then
    log_info "No superseded MRs found for ${TARGET_BRANCH}"
    exit 0
fi

echo "${STALE_MRS}" | while read -r MR_IID MR_BRANCH; do
    [ -z "${MR_IID}" ] && continue
    log_info "Closing superseded MR !${MR_IID} (branch: ${MR_BRANCH})"

    # Add comment explaining supersession
    JSON_PAYLOAD=$(jq -n --arg body "Superseded by \`${NEW_BRANCH}\`" '{body: $body}')
    curl -sf -X POST \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}/merge_requests/${MR_IID}/notes" \
        >/dev/null 2>&1 || log_warn "Could not add comment to MR !${MR_IID}"

    # Close the MR
    curl -sf -X PUT \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"state_event":"close"}' \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}/merge_requests/${MR_IID}" \
        >/dev/null 2>&1 || log_warn "Could not close MR !${MR_IID}"

    # Delete the stale source branch (GitLab only auto-deletes on merge, not close)
    ENCODED_BRANCH=$(echo "${MR_BRANCH}" | sed 's/\//%2F/g')
    curl -sf -X DELETE \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}/repository/branches/${ENCODED_BRANCH}" \
        >/dev/null 2>&1 || log_warn "Could not delete branch ${MR_BRANCH}"
done

log_info "Superseded MR cleanup complete"
