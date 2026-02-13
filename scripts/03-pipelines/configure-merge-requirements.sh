#!/usr/bin/env bash
# Configure GitLab merge requirements for k8s-deployments
# Sets up project settings for merge request workflow
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)

# Get project ID for k8s-deployments
PROJECT_PATH="${DEPLOYMENTS_REPO_PATH//\//%2F}"

log_header "Configuring Merge Requirements"
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Project: ${DEPLOYMENTS_REPO_PATH}"
echo ""

# Get project ID
log_step "Fetching project ID..."
PROJECT_ID=$(curl -sfk "${GITLAB_URL_EXTERNAL}/api/v4/projects/${PROJECT_PATH}" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
log_pass "Project ID: $PROJECT_ID"

# Configure project settings
log_step "Updating project settings..."
HTTP_STATUS=$(curl -sfk -X PUT "${GITLAB_URL_EXTERNAL}/api/v4/projects/${PROJECT_ID}" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  -w "%{http_code}" \
  -o /tmp/gitlab-project-$$.json \
  -d '{
    "only_allow_merge_if_pipeline_succeeds": false,
    "only_allow_merge_if_all_discussions_are_resolved": false,
    "merge_method": "merge",
    "remove_source_branch_after_merge": true
  }')

if [[ "$HTTP_STATUS" == "200" ]]; then
    log_pass "Project settings updated"
else
    log_warn "Could not update project settings (HTTP $HTTP_STATUS)"
    cat /tmp/gitlab-project-$$.json >&2
fi
rm -f /tmp/gitlab-project-$$.json

echo ""
log_header "Configuration Complete"
echo ""
echo "How it works:"
echo "  1. Jenkins webhook triggers on MR creation/update"
echo "  2. Jenkins runs validation pipeline"
echo "  3. Jenkins reports status back to GitLab commit"
echo "  4. GitLab shows status check in MR"
echo ""
echo "Note: GitLab CE doesn't enforce external status checks"
echo "      (requires Premium). Status shown but not enforced."
