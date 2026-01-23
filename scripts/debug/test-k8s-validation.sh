#!/bin/bash
# Quick test script for k8s-deployments validation job

set -e

JENKINS_URL="http://jenkins.local"
JOB_NAME="k8s-deployments-validation"

echo "Getting Jenkins credentials..."
JENKINS_PASSWORD=$(kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

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

# Trigger build
echo "Triggering validation build..."
HTTP_STATUS=$(curl -X POST "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters" \
  -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -u "admin:${JENKINS_PASSWORD}" \
  -H "Jenkins-Crumb: ${CRUMB}" \
  -d "BRANCH_NAME=main" \
  -d "VALIDATE_ALL_ENVS=true" \
  -w "%{http_code}" \
  -s -o /dev/null)

# Cleanup
rm -f "$COOKIE_JAR" "$CRUMB_FILE"

if [ "$HTTP_STATUS" = "201" ]; then
  echo "✓ Build triggered successfully (HTTP $HTTP_STATUS)"

  # Wait and get build number
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
