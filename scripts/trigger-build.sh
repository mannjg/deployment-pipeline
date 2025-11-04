#!/bin/bash
# Script to trigger Jenkins builds using the REST API
# Usage: ./trigger-build.sh <job-name>

set -e

JENKINS_URL="${JENKINS_URL:-http://jenkins.local}"
JOB_NAME="${1:-example-app-ci}"

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

# Trigger build (use buildWithParameters to work with both parameterized and non-parameterized jobs)
# Skip stage and prod promotions for faster testing
echo "Triggering build for job: $JOB_NAME"
echo "Parameters: SKIP_STAGE_PROMOTION=true, SKIP_PROD_PROMOTION=true"
HTTP_STATUS=$(curl -X POST "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters" \
  -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -u "admin:${JENKINS_PASSWORD}" \
  -H "Jenkins-Crumb: ${CRUMB}" \
  -d "SKIP_INTEGRATION_TESTS=false" \
  -d "SKIP_STAGE_PROMOTION=true" \
  -d "SKIP_PROD_PROMOTION=true" \
  -w "%{http_code}" \
  -s -o /dev/null)

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
  exit 0
else
  echo "✗ Failed to trigger build (HTTP $HTTP_STATUS)"
  exit 1
fi
