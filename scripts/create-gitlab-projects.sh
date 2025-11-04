#!/bin/bash
set -e

GITLAB_TOKEN="glpat-9m86y9YHyGf77Kr8bRjX"
GITLAB_URL="http://gitlab.local"

echo "=== Creating GitLab Projects ==="

# Create group
echo "Creating group 'example'..."
curl -s -X POST "$GITLAB_URL/api/v4/groups" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"name": "example", "path": "example", "visibility": "private"}' > /dev/null 2>&1 || echo "  (group may already exist)"

# Get group ID
GROUP_ID=$(curl -s "$GITLAB_URL/api/v4/groups/example" --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
echo "Group ID: $GROUP_ID"

# Create example-app project
echo "Creating project 'example-app'..."
curl -s -X POST "$GITLAB_URL/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"example-app\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 || echo "  (project may already exist)"

# Create k8s-deployments project
echo "Creating project 'k8s-deployments'..."
curl -s -X POST "$GITLAB_URL/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"k8s-deployments\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 || echo "  (project may already exist)"

echo "✓ Projects created!"
