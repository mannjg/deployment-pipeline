#!/bin/bash
#
# setup-gitlab-webhook.sh
# Configure GitLab webhook to auto-trigger Jenkins builds
#
# Prerequisites:
# 1. GitLab running at http://gitlab.local
# 2. Jenkins running with pipeline job configured
# 3. GitLab personal access token with api scope
#
# Usage:
#   export GITLAB_TOKEN="your-gitlab-token-here"
#   ./scripts/setup-gitlab-webhook.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== GitLab Webhook Configuration ===${NC}\n"

# Check prerequisites
if [ -z "$GITLAB_TOKEN" ]; then
    echo -e "${RED}ERROR: GITLAB_TOKEN environment variable not set${NC}"
    echo "Please set it first:"
    echo "  export GITLAB_TOKEN='glpat-9m86y9YHyGf77Kr8bRjX'"
    exit 1
fi

GITLAB_URL="http://gitlab.local"
PROJECT_PATH="example/example-app"
PROJECT_PATH_ENCODED="example%2Fexample-app"

# Jenkins webhook URL (using ingress - GitLab rejects cluster-internal DNS)
# GitLab will call this URL when push events occur
# Note: This uses the external ingress URL which GitLab can validate
JENKINS_WEBHOOK_URL="http://jenkins.local/job/example-app-ci/build"

echo -e "${YELLOW}Configuration:${NC}"
echo "  GitLab URL: ${GITLAB_URL}"
echo "  Project: ${PROJECT_PATH}"
echo "  Jenkins Webhook: ${JENKINS_WEBHOOK_URL}"
echo ""

# Get project ID
echo -e "${GREEN}Getting project ID...${NC}"
PROJECT_ID=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}" | \
    python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

echo "  Project ID: ${PROJECT_ID}"

# Check if webhook already exists
echo -e "\n${GREEN}Checking for existing webhooks...${NC}"
EXISTING_WEBHOOKS=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks")

WEBHOOK_COUNT=$(echo "$EXISTING_WEBHOOKS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$WEBHOOK_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}  Found ${WEBHOOK_COUNT} existing webhook(s)${NC}"

    # Check if our webhook already exists
    JENKINS_HOOK_ID=$(echo "$EXISTING_WEBHOOKS" | python3 -c "
import sys, json
hooks = json.load(sys.stdin)
for hook in hooks:
    if 'jenkins' in hook['url'].lower():
        print(hook['id'])
        break
" 2>/dev/null || echo "")

    if [ -n "$JENKINS_HOOK_ID" ]; then
        echo -e "${YELLOW}  Deleting existing Jenkins webhook (ID: ${JENKINS_HOOK_ID})...${NC}"
        curl -s -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks/${JENKINS_HOOK_ID}" > /dev/null
        echo -e "${GREEN}    ✓ Deleted${NC}"
    fi
fi

# Create webhook
echo -e "\n${GREEN}Creating new webhook...${NC}"
WEBHOOK_RESPONSE=$(curl -s -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" \
    -d @- <<EOF
{
    "url": "${JENKINS_WEBHOOK_URL}",
    "push_events": true,
    "push_events_branch_filter": "main",
    "merge_requests_events": false,
    "tag_push_events": false,
    "enable_ssl_verification": false,
    "token": ""
}
EOF
)

# Check if webhook was created successfully
WEBHOOK_ID=$(echo "$WEBHOOK_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))" 2>/dev/null || echo "")

if [ -n "$WEBHOOK_ID" ]; then
    echo -e "${GREEN}  ✓ Webhook created successfully!${NC}"
    echo "    Webhook ID: ${WEBHOOK_ID}"
    echo "    URL: ${JENKINS_WEBHOOK_URL}"
    echo "    Trigger: Push events on 'main' branch"
else
    echo -e "${RED}  ERROR: Failed to create webhook${NC}"
    echo "  Response: ${WEBHOOK_RESPONSE}"
    exit 1
fi

# Verify webhook
echo -e "\n${GREEN}Verifying webhook...${NC}"
WEBHOOK_INFO=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks/${WEBHOOK_ID}")

echo "  URL: $(echo "$WEBHOOK_INFO" | python3 -c "import sys, json; print(json.load(sys.stdin)['url'])")"
echo "  Push events: $(echo "$WEBHOOK_INFO" | python3 -c "import sys, json; print(json.load(sys.stdin)['push_events'])")"
echo "  Branch filter: $(echo "$WEBHOOK_INFO" | python3 -c "import sys, json; print(json.load(sys.stdin).get('push_events_branch_filter', 'all'))")"

echo -e "\n${GREEN}=== Webhook Configuration Complete! ===${NC}\n"
echo -e "${YELLOW}Testing:${NC}"
echo "  To test the webhook, make a commit and push to the main branch:"
echo "    git commit --allow-empty -m 'Test webhook'"
echo "    git push origin main"
echo ""
echo "  Jenkins should automatically start a new build."
echo "  Monitor at: http://jenkins.local/job/example-app-ci/"
