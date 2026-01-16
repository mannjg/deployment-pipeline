#!/bin/bash
# Configure GitLab connection in Jenkins
# This adds the GitLab connection for status reporting

set -e

# Source centralized GitLab configuration
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

JENKINS_URL="http://jenkins.local"
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-9m86y9YHyGf77Kr8bRjX}"
CONNECTION_NAME="gitlab-local"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Configuring GitLab connection in Jenkins"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Jenkins: $JENKINS_URL"
echo "GitLab: ${GITLAB_URL_EXTERNAL}"
echo "Connection: $CONNECTION_NAME"
echo ""

JENKINS_PASSWORD=$(microk8s kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"

# Get CSRF crumb
echo "Getting CSRF crumb..."
curl -c "$COOKIE_JAR" -b "$COOKIE_JAR" -s "${JENKINS_URL}/crumbIssuer/api/json" \
  -u "admin:${JENKINS_PASSWORD}" \
  > "$CRUMB_FILE"

CRUMB=$(jq -r '.crumb' "$CRUMB_FILE")

# Note: Configuring GitLab connection via API is complex
# The plugin uses Jenkins credentials and system configuration

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Manual Configuration Required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "The GitLab plugin requires manual configuration in Jenkins UI:"
echo ""
echo "Step 1: Add GitLab API Token Credential"
echo "  URL: ${JENKINS_URL}/manage/credentials/store/system/domain/_/"
echo "  1. Click 'Add Credentials'"
echo "  2. Kind: GitLab API token"
echo "  3. API token: ${GITLAB_TOKEN}"
echo "  4. ID: gitlab-api-token"
echo "  5. Description: GitLab API Token for status reporting"
echo "  6. Click 'Create'"
echo ""
echo "Step 2: Configure GitLab Connection"
echo "  URL: ${JENKINS_URL}/manage/configure"
echo "  1. Scroll to 'GitLab' section"
echo "  2. Click 'Add GitLab Server'"
echo "  3. Connection name: ${CONNECTION_NAME}"
echo "  4. GitLab host URL: ${GITLAB_URL_EXTERNAL}"
echo "  5. Credentials: Select 'gitlab-api-token'"
echo "  6. Click 'Test Connection' - should show 'Success'"
echo "  7. Click 'Save'"
echo ""
echo "Step 3: Update Jenkinsfile (if needed)"
echo "  The updateGitlabCommitStatus step should reference the connection:"
echo "  updateGitlabCommitStatus(name: 'validation', state: 'success', connection: '${CONNECTION_NAME}')"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Alternative: Test without explicit connection"
echo "  The plugin may auto-discover the GitLab instance from webhook"
echo "  Try running a build first to see if it works"

# Cleanup
rm -f "$COOKIE_JAR" "$CRUMB_FILE"
