#!/bin/bash
# Create GitLab Merge Request via API
# Used by Jenkins pipeline to automate MR creation

set -euo pipefail

# Parameters
SOURCE_BRANCH="${1:-}"
TARGET_BRANCH="${2:-}"
MR_TITLE="${3:-}"
MR_DESCRIPTION="${4:-}"

# Environment variables (should be set by caller)
GITLAB_URL="${GITLAB_URL:-http://gitlab.gitlab.svc.cluster.local}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
PROJECT_ID="${PROJECT_ID:-example%2Fk8s-deployments}"
MR_DRAFT="${MR_DRAFT:-false}"
AUTO_MERGE="${AUTO_MERGE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <source_branch> <target_branch> <title> <description>"
    echo ""
    echo "Create a GitLab Merge Request via API"
    echo ""
    echo "Required arguments:"
    echo "  source_branch   Branch to merge from"
    echo "  target_branch   Branch to merge into"
    echo "  title          MR title"
    echo "  description    MR description (can be multi-line)"
    echo ""
    echo "Required environment variables:"
    echo "  GITLAB_TOKEN   GitLab API token with api scope"
    echo "  GITLAB_URL     GitLab base URL (default: http://gitlab.gitlab.svc.cluster.local)"
    echo ""
    echo "Optional environment variables:"
    echo "  PROJECT_ID     GitLab project ID (default: example%2Fk8s-deployments)"
    echo "  MR_DRAFT       Create as draft MR (default: false)"
    echo "  AUTO_MERGE     Enable auto-merge when pipeline succeeds (default: false)"
    echo ""
    exit 1
}

# Validate inputs
if [[ -z "$SOURCE_BRANCH" || -z "$TARGET_BRANCH" || -z "$MR_TITLE" ]]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    usage
fi

if [[ -z "$GITLAB_TOKEN" ]]; then
    echo -e "${RED}Error: GITLAB_TOKEN environment variable is not set${NC}"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Creating GitLab Merge Request"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Source: $SOURCE_BRANCH"
echo "Target: $TARGET_BRANCH"
echo "Title:  $MR_TITLE"
echo "Draft:  $MR_DRAFT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Escape description for JSON (basic escaping)
ESCAPED_DESC=$(echo "$MR_DESCRIPTION" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

# Build JSON payload
MR_JSON=$(cat <<EOF
{
  "source_branch": "$SOURCE_BRANCH",
  "target_branch": "$TARGET_BRANCH",
  "title": "$MR_TITLE",
  "description": "$ESCAPED_DESC",
  "remove_source_branch": true
}
EOF
)

# Add draft flag if requested
if [ "$MR_DRAFT" = "true" ]; then
    MR_JSON=$(echo "$MR_JSON" | sed 's/}/, "draft": true}/')
fi

# Create the MR
echo "Sending request to GitLab API..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$MR_JSON" \
    "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests")

# Split response body and status code
HTTP_BODY=$(echo "$RESPONSE" | head -n -1)
HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

echo "HTTP Status: $HTTP_STATUS"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    # Success
    MR_IID=$(echo "$HTTP_BODY" | grep -o '"iid":[0-9]*' | head -1 | cut -d: -f2)
    MR_URL=$(echo "$HTTP_BODY" | grep -o '"web_url":"[^"]*"' | head -1 | cut -d'"' -f4)

    echo -e "${GREEN}✓ Merge Request created successfully${NC}"
    echo "MR IID: !$MR_IID"
    echo "MR URL: $MR_URL"

    # Enable auto-merge if requested
    if [ "$AUTO_MERGE" = "true" ] && [ -n "$MR_IID" ]; then
        echo "Enabling auto-merge..."
        AUTO_MERGE_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
            -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID/merge?merge_when_pipeline_succeeds=true")

        AUTO_MERGE_STATUS=$(echo "$AUTO_MERGE_RESPONSE" | tail -n 1)
        if [[ "$AUTO_MERGE_STATUS" =~ ^2[0-9][0-9]$ ]]; then
            echo -e "${GREEN}✓ Auto-merge enabled${NC}"
        else
            echo -e "${YELLOW}⚠ Warning: Could not enable auto-merge${NC}"
            echo "Response: $(echo "$AUTO_MERGE_RESPONSE" | head -n -1)"
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
else
    # Error
    echo -e "${RED}✗ Failed to create Merge Request${NC}"
    echo "Response:"
    echo "$HTTP_BODY" | head -20
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
