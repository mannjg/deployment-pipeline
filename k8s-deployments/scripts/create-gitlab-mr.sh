#!/usr/bin/env bash
set -euo pipefail

# Create a GitLab merge request using the API
# Usage: ./create-gitlab-mr.sh <source_branch> <target_branch> <title> <description>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
GITLAB_API="${SCRIPT_DIR}/gitlab-api.sh"

# Load preflight library and local config
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Preflight checks
preflight_check_required GITLAB_URL_INTERNAL GITLAB_GROUP GITLAB_TOKEN

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate arguments
if [ $# -lt 4 ]; then
    log_error "Insufficient arguments"
    echo "Usage: $0 <source_branch> <target_branch> <title> <description>"
    echo ""
    echo "Example:"
    echo "  $0 dev stage 'Promote example-app:1.0.0-abc123' 'Automatic promotion from dev to stage'"
    exit 1
fi

SOURCE_BRANCH=$1
TARGET_BRANCH=$2
TITLE=$3
DESCRIPTION=$4

# GitLab configuration (from preflight-validated environment)
GITLAB_URL=${GITLAB_URL_INTERNAL}
PROJECT_PATH="${GITLAB_GROUP}/k8s-deployments"
PROJECT_PATH_ENCODED=$(echo "$PROJECT_PATH" | sed 's/\//%2F/g')

# Debug: Show token length (not the actual token)
TOKEN_LENGTH=${#GITLAB_TOKEN}
log_info "GitLab token present (length: $TOKEN_LENGTH characters)"

log_info "Creating merge request in GitLab..."
log_info "Source: $SOURCE_BRANCH → Target: $TARGET_BRANCH"

# Create the merge request using GitLab API
# Documentation: https://docs.gitlab.com/ee/api/merge_requests.html#create-mr

# Construct JSON payload (jq handles all escaping — safe for tabs, unicode, control chars)
JSON_PAYLOAD=$(jq -n \
    --arg src "$SOURCE_BRANCH" \
    --arg tgt "$TARGET_BRANCH" \
    --arg title "$TITLE" \
    --arg desc "$DESCRIPTION" \
    '{source_branch: $src, target_branch: $tgt, title: $title, description: $desc, remove_source_branch: true, squash: false}')

MR_RESPONSE=$("$GITLAB_API" POST \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}/merge_requests" \
    --data "$JSON_PAYLOAD" \
    --with-status)

# Split response and HTTP code
HTTP_CODE=$(echo "$MR_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$MR_RESPONSE" | sed '$d')

# Check HTTP status code
if [ "$HTTP_CODE" -eq 201 ]; then
    # Extract MR details from JSON response
    MR_IID=$(echo "$RESPONSE_BODY" | jq -r '.iid')
    MR_WEB_URL=$(echo "$RESPONSE_BODY" | jq -r '.web_url')

    log_info "✅ Merge request created successfully!"
    echo ""
    echo -e "${BLUE}Merge Request #${MR_IID}${NC}"
    echo -e "${BLUE}URL: ${MR_WEB_URL}${NC}"
    echo ""
    echo "Source: $SOURCE_BRANCH"
    echo "Target: $TARGET_BRANCH"
    echo "Title: $TITLE"
    echo ""
    log_info "Review the changes and merge when ready to promote to $TARGET_BRANCH"

    # Export for use in CI/CD
    echo "MR_IID=$MR_IID" > /tmp/gitlab-mr-info.env
    echo "MR_URL=$MR_WEB_URL" >> /tmp/gitlab-mr-info.env

    exit 0
elif [ "$HTTP_CODE" -eq 409 ]; then
    # MR already exists
    log_warn "Merge request already exists for $SOURCE_BRANCH → $TARGET_BRANCH"

    # Try to find the existing MR
    EXISTING_MR=$("$GITLAB_API" GET \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_PATH_ENCODED}/merge_requests?source_branch=${SOURCE_BRANCH}&target_branch=${TARGET_BRANCH}&state=opened")

    MR_IID=$(echo "$EXISTING_MR" | jq -r '.[0].iid // empty')
    MR_WEB_URL=$(echo "$EXISTING_MR" | jq -r '.[0].web_url // empty')

    if [ -n "$MR_IID" ]; then
        echo ""
        echo -e "${BLUE}Existing Merge Request #${MR_IID}${NC}"
        echo -e "${BLUE}URL: ${MR_WEB_URL}${NC}"
        echo ""

        # Export for use in CI/CD
        echo "MR_IID=$MR_IID" > /tmp/gitlab-mr-info.env
        echo "MR_URL=$MR_WEB_URL" >> /tmp/gitlab-mr-info.env
    fi

    exit 0
else
    log_error "Failed to create merge request (HTTP $HTTP_CODE)"
    echo ""
    echo "Response:"
    echo "$RESPONSE_BODY" | head -20
    echo ""
    echo "Debug info:"
    echo "- GitLab URL: $GITLAB_URL"
    echo "- Project: $PROJECT_PATH (encoded: $PROJECT_PATH_ENCODED)"
    echo "- Source branch: $SOURCE_BRANCH"
    echo "- Target branch: $TARGET_BRANCH"
    echo "- Token length: ${#GITLAB_TOKEN} characters"
    echo ""
    if [ "$HTTP_CODE" -eq 401 ]; then
        log_error "Authentication failed. The GitLab token may be:"
        echo "  1. Incorrect or expired"
        echo "  2. Missing required scopes (needs 'api' scope)"
        echo "  3. Not a personal access token (password won't work)"
    fi
    exit 1
fi
