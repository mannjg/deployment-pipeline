#!/usr/bin/env bash
# Verify credentials are valid and can access their respective APIs
# Use this to detect credential drift or expiration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

log_header "Credential Verification"
echo ""

FAILED=0

# Test GitLab token
log_step "Testing GitLab token..."
GITLAB_TOKEN=$(require_gitlab_token)
GITLAB_USER=$(curl -sfk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/user" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('username', ''))" 2>/dev/null) || true

if [[ -n "$GITLAB_USER" ]]; then
    log_pass "GitLab: authenticated as '$GITLAB_USER'"
else
    log_fail "GitLab: token invalid or API unreachable"
    FAILED=1
fi

# Test Jenkins credentials
log_step "Testing Jenkins credentials..."
JENKINS_CREDS=$(require_jenkins_credentials)
JENKINS_RESPONSE=$(curl -sfk -u "$JENKINS_CREDS" \
    "${JENKINS_URL_EXTERNAL}/api/json" 2>/dev/null) || true

if [[ -n "$JENKINS_RESPONSE" ]]; then
    log_pass "Jenkins: authentication successful"
else
    log_fail "Jenkins: credentials invalid or API unreachable"
    FAILED=1
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
    log_header "All Credentials Valid"
    exit 0
else
    log_header "Credential Issues Detected"
    exit 1
fi
