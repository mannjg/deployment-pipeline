#!/bin/bash
# Script to trigger Jenkins builds using the REST API
# Usage: ./trigger-build.sh <job-name> [PARAM1=value1 PARAM2=value2 ...]

set -e

JENKINS_URL="${JENKINS_URL:-http://jenkins.local}"
JOB_NAME="${1:-example-app-ci}"
shift  # Remove job name from arguments

# Get Jenkins admin password from Kubernetes secret
echo "Getting Jenkins credentials..."
JENKINS_PASSWORD=$(microk8s kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

# Create temporary files for cookies and crumb
COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"

# Get crumb with cookies
echo "Getting CSRF crumb..."
curl -c "$COOKIE_JAR" -b "$COOKIE_JAR" -s "${JENKINS_URL}/crumbIssuer/api/json" \
  -u "admin:${JENKINS_PASSWORD}" \
  > "$CRUMB_FILE"

CRUMB=$(jq -r '.crumb' "$CRUMB_FILE")
echo "Crumb: ${CRUMB:0:16}..."

# Build curl command with parameters
CURL_CMD="curl -X POST \"${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters\" \
  -c \"$COOKIE_JAR\" -b \"$COOKIE_JAR\" \
  -u \"admin:${JENKINS_PASSWORD}\" \
  -H \"Jenkins-Crumb: ${CRUMB}\""

# Add custom parameters or defaults
if [ $# -gt 0 ]; then
  echo "Triggering build for job: $JOB_NAME"
  echo "Parameters:"
  for param in "$@"; do
    echo "  $param"
    CURL_CMD="$CURL_CMD -d \"$param\""
  done
else
  echo "Triggering build for job: $JOB_NAME"
  echo "Using default parameters for example-app-ci"
  CURL_CMD="$CURL_CMD -d \"SKIP_INTEGRATION_TESTS=false\" -d \"SKIP_STAGE_PROMOTION=true\" -d \"SKIP_PROD_PROMOTION=true\""
fi

# Execute curl
CURL_CMD="$CURL_CMD -w \"%{http_code}\" -s -o /dev/null"
HTTP_STATUS=$(eval $CURL_CMD)

# Cleanup
rm -f "$COOKIE_JAR" "$CRUMB_FILE"

if [ "$HTTP_STATUS" = "201" ]; then
  echo "✓ Build triggered successfully (HTTP $HTTP_STATUS)"

  # Wait a moment and get the latest build number
  sleep 2
  BUILD_NUMBER=$(curl -s "${JENKINS_URL}/job/${JOB_NAME}/api/json" \
    -u "admin:${JENKINS_PASSWORD}" \
    | jq -r '.lastBuild.number')

  echo "✓ Build #${BUILD_NUMBER} started"
  echo "  View at: ${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}/console"
else
  echo "✗ Failed to trigger build (HTTP $HTTP_STATUS)"
  exit 1
fi
