#!/bin/bash
# Configure GitLab connection in Jenkins
# Documents the manual steps required for GitLab plugin setup
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)
JENKINS_CREDS=$(require_jenkins_credentials)
JENKINS_USER="${JENKINS_CREDS%%:*}"
JENKINS_PASS="${JENKINS_CREDS#*:}"

CONNECTION_NAME="gitlab-local"

log_header "GitLab Connection Setup for Jenkins"
log_info "Jenkins: ${JENKINS_URL_EXTERNAL}"
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Connection: $CONNECTION_NAME"
echo ""

COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"
trap 'rm -f "$COOKIE_JAR" "$CRUMB_FILE"' EXIT

# Get CSRF crumb
log_step "Getting CSRF crumb..."
if curl -sf -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    "${JENKINS_URL_EXTERNAL}/crumbIssuer/api/json" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    > "$CRUMB_FILE"; then
    log_pass "CSRF crumb obtained"
else
    log_warn "Could not get CSRF crumb (Jenkins may have CSRF disabled)"
fi

echo ""
log_header "Manual Configuration Required"
echo ""
echo "The GitLab plugin requires manual configuration in Jenkins UI:"
echo ""
echo "Step 1: Add GitLab API Token Credential"
echo "  URL: ${JENKINS_URL_EXTERNAL}/manage/credentials/store/system/domain/_/"
echo "  1. Click 'Add Credentials'"
echo "  2. Kind: GitLab API token"
echo "  3. API token: (use token from K8s secret or GITLAB_TOKEN env)"
echo "  4. ID: gitlab-api-token"
echo "  5. Description: GitLab API Token for status reporting"
echo "  6. Click 'Create'"
echo ""
echo "Step 2: Configure GitLab Connection"
echo "  URL: ${JENKINS_URL_EXTERNAL}/manage/configure"
echo "  1. Scroll to 'GitLab' section"
echo "  2. Click 'Add GitLab Server'"
echo "  3. Connection name: ${CONNECTION_NAME}"
echo "  4. GitLab host URL: ${GITLAB_URL_EXTERNAL}"
echo "  5. Credentials: Select 'gitlab-api-token'"
echo "  6. Click 'Test Connection' - should show 'Success'"
echo "  7. Click 'Save'"
echo ""
log_header "Setup Instructions Complete"
