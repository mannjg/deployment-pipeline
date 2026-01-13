#!/bin/bash
# Script to configure GitLab webhook for k8s-deployments repository
# Triggers Jenkins validation pipeline on push and merge request events

set -e

# Source centralized GitLab configuration
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

JENKINS_URL="${JENKINS_URL:-http://jenkins.local}"
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-9m86y9YHyGf77Kr8bRjX}"
PROJECT_ID="2"  # k8s-deployments project ID
JOB_NAME="k8s-deployments-validation"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setting up k8s-deployments webhook"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "GitLab URL: ${GITLAB_URL_EXTERNAL}"
echo "Project ID: $PROJECT_ID"
echo "Jenkins Job: $JOB_NAME"
echo ""

# Construct webhook URL
WEBHOOK_URL="${JENKINS_URL}/project/${JOB_NAME}"

echo "Webhook URL: $WEBHOOK_URL"
echo ""

# Check if webhook already exists
echo "Checking for existing webhooks..."
EXISTING_WEBHOOKS=$(curl -s "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

# Check if our webhook URL is already registered
if echo "$EXISTING_WEBHOOKS" | grep -q "$WEBHOOK_URL"; then
    echo "⚠ Webhook already exists for this URL"

    # Get the webhook ID
    HOOK_ID=$(echo "$EXISTING_WEBHOOKS" | jq -r ".[] | select(.url == \"$WEBHOOK_URL\") | .id")
    echo "Existing webhook ID: $HOOK_ID"

    read -p "Do you want to update it? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping webhook setup"
        exit 0
    fi

    # Delete existing webhook
    echo "Deleting existing webhook..."
    curl -s -X DELETE "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks/${HOOK_ID}" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}"
    echo "✓ Existing webhook deleted"
fi

# Create new webhook
echo "Creating webhook..."
HTTP_STATUS=$(curl -X POST "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  -w "%{http_code}" \
  -o /tmp/webhook-response-$$.json \
  -d "{
    \"url\": \"$WEBHOOK_URL\",
    \"push_events\": true,
    \"merge_requests_events\": true,
    \"enable_ssl_verification\": false,
    \"push_events_branch_filter\": \"\"
  }")

if [ "$HTTP_STATUS" = "201" ]; then
    echo "✓ Webhook created successfully"

    # Extract webhook details
    HOOK_ID=$(jq -r '.id' /tmp/webhook-response-$$.json)
    echo ""
    echo "Webhook Details:"
    echo "  ID: $HOOK_ID"
    echo "  URL: $WEBHOOK_URL"
    echo "  Events: Push, Merge Request"
else
    echo "✗ Failed to create webhook (HTTP $HTTP_STATUS)"
    cat /tmp/webhook-response-$$.json
    rm -f /tmp/webhook-response-$$.json
    exit 1
fi

# Cleanup
rm -f /tmp/webhook-response-$$.json

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Webhook setup complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Testing:"
echo "  Push a change to k8s-deployments to trigger validation"
echo "  Or manually trigger: ${JENKINS_URL}/job/${JOB_NAME}/build"
echo ""
echo "Webhook Management:"
echo "  List webhooks: curl ${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks -H \"PRIVATE-TOKEN: \$GITLAB_TOKEN\""
echo "  Delete webhook: curl -X DELETE ${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks/${HOOK_ID} -H \"PRIVATE-TOKEN: \$GITLAB_TOKEN\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
