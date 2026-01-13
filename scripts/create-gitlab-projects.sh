#!/bin/bash
set -e

# Source centralized GitLab configuration
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-9m86y9YHyGf77Kr8bRjX}"

echo "=== Creating GitLab Projects ==="

# Create group
echo "Creating group '${GITLAB_GROUP}'..."
curl -s -X POST "${GITLAB_URL_EXTERNAL}/api/v4/groups" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${GITLAB_GROUP}\", \"path\": \"${GITLAB_GROUP}\", \"visibility\": \"private\"}" > /dev/null 2>&1 || echo "  (group may already exist)"

# Get group ID
GROUP_ID=$(curl -s "${GITLAB_URL_EXTERNAL}/api/v4/groups/${GITLAB_GROUP}" --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
echo "Group ID: $GROUP_ID"

# Create example-app project
echo "Creating project '${APP_REPO_NAME}'..."
curl -s -X POST "${GITLAB_URL_EXTERNAL}/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${APP_REPO_NAME}\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 || echo "  (project may already exist)"

# Create k8s-deployments project
echo "Creating project '${DEPLOYMENTS_REPO_NAME}'..."
curl -s -X POST "${GITLAB_URL_EXTERNAL}/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${DEPLOYMENTS_REPO_NAME}\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 || echo "  (project may already exist)"

echo "Projects created!"
