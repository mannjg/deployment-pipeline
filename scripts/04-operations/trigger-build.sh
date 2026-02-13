#!/bin/bash
# Script to trigger Jenkins builds using the REST API
# Usage: ./trigger-build.sh <job-name> [PARAM1=value1 PARAM2=value2 ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source infrastructure config
source "$PROJECT_ROOT/scripts/lib/infra.sh" "${CLUSTER_CONFIG:-}"
source "$PROJECT_ROOT/scripts/lib/logging.sh"
source "$PROJECT_ROOT/scripts/lib/credentials.sh"

JENKINS_URL="${JENKINS_URL:-$JENKINS_URL_EXTERNAL}"
JOB_NAME="${1:-example-app-ci}"
shift  # Remove job name from arguments

# Get Jenkins credentials
log_info "Getting Jenkins credentials..."
JENKINS_AUTH=$(require_jenkins_credentials)
JENKINS_USER="${JENKINS_AUTH%%:*}"
JENKINS_TOKEN="${JENKINS_AUTH#*:}"

# Create temporary files for cookies and crumb
COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"

# Get crumb with cookies
log_info "Getting CSRF crumb..."
curl -k -c "$COOKIE_JAR" -b "$COOKIE_JAR" -s "${JENKINS_URL}/crumbIssuer/api/json" \
  -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
  > "$CRUMB_FILE"

CRUMB=$(jq -r '.crumb' "$CRUMB_FILE")
log_info "Crumb: ${CRUMB:0:16}..."

# Build curl command with parameters
CURL_CMD="curl -k -X POST \"${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters\" \
  -c \"$COOKIE_JAR\" -b \"$COOKIE_JAR\" \
  -u \"${JENKINS_USER}:${JENKINS_TOKEN}\" \
  -H \"Jenkins-Crumb: ${CRUMB}\""

# Add custom parameters or defaults
if [ $# -gt 0 ]; then
  log_info "Triggering build for job: $JOB_NAME"
  log_info "Parameters:"
  for param in "$@"; do
    log_info "  $param"
    CURL_CMD="$CURL_CMD -d \"$param\""
  done
else
  log_info "Triggering build for job: $JOB_NAME"
  log_info "Using default parameters for example-app-ci"
  CURL_CMD="$CURL_CMD -d \"SKIP_INTEGRATION_TESTS=false\" -d \"SKIP_STAGE_PROMOTION=true\" -d \"SKIP_PROD_PROMOTION=true\""
fi

# Execute curl
CURL_CMD="$CURL_CMD -w \"%{http_code}\" -s -o /dev/null"
HTTP_STATUS=$(eval $CURL_CMD)

# Cleanup
rm -f "$COOKIE_JAR" "$CRUMB_FILE"

if [ "$HTTP_STATUS" = "201" ]; then
  log_pass "Build triggered successfully (HTTP $HTTP_STATUS)"

  # Wait a moment and get the latest build number
  sleep 2
  BUILD_NUMBER=$(curl -sk "${JENKINS_URL}/job/${JOB_NAME}/api/json" \
    -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
    | jq -r '.lastBuild.number')

  log_pass "Build #${BUILD_NUMBER} started"
  log_info "View at: ${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}/console"
else
  log_error "Failed to trigger build (HTTP $HTTP_STATUS)"
  exit 1
fi
