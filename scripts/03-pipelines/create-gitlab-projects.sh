#!/usr/bin/env bash
# Create GitLab projects for the pipeline demo
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)

log_header "Creating GitLab Projects"
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Group: ${GITLAB_GROUP}"
echo ""

# Create group
log_step "Creating group '${GITLAB_GROUP}'..."
curl -sfk -X POST "${GITLAB_URL_EXTERNAL}/api/v4/groups" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${GITLAB_GROUP}\", \"path\": \"${GITLAB_GROUP}\", \"visibility\": \"private\"}" > /dev/null 2>&1 \
  && log_pass "Group created" \
  || log_warn "Group may already exist"

# Get group ID
GROUP_ID=$(curl -sfk "${GITLAB_URL_EXTERNAL}/api/v4/groups/${GITLAB_GROUP}" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
log_info "Group ID: $GROUP_ID"

# Create example-app project
log_step "Creating project '${APP_REPO_NAME}'..."
curl -sfk -X POST "${GITLAB_URL_EXTERNAL}/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${APP_REPO_NAME}\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 \
  && log_pass "Project '${APP_REPO_NAME}' created" \
  || log_warn "Project '${APP_REPO_NAME}' may already exist"

# Create k8s-deployments project
log_step "Creating project '${DEPLOYMENTS_REPO_NAME}'..."
curl -sfk -X POST "${GITLAB_URL_EXTERNAL}/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${DEPLOYMENTS_REPO_NAME}\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 \
  && log_pass "Project '${DEPLOYMENTS_REPO_NAME}' created" \
  || log_warn "Project '${DEPLOYMENTS_REPO_NAME}' may already exist"

echo ""
log_header "Projects Ready"
