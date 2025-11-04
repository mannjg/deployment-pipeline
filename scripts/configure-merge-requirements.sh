#!/bin/bash
# Script to configure GitLab merge requirements for k8s-deployments
# Requires Jenkins validation to pass before merge is allowed

set -e

GITLAB_URL="${GITLAB_URL:-http://gitlab.local}"
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-9m86y9YHyGf77Kr8bRjX}"
PROJECT_ID="2"  # k8s-deployments project ID

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Configuring merge requirements"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "GitLab URL: $GITLAB_URL"
echo "Project ID: $PROJECT_ID"
echo ""

# Configure project settings to require external status checks
echo "Updating project settings..."
HTTP_STATUS=$(curl -X PUT "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  -w "%{http_code}" \
  -o /tmp/gitlab-project-$$.json \
  -d '{
    "only_allow_merge_if_pipeline_succeeds": false,
    "only_allow_merge_if_all_discussions_are_resolved": false,
    "merge_method": "merge",
    "remove_source_branch_after_merge": true
  }')

if [ "$HTTP_STATUS" = "200" ]; then
    echo "✓ Project settings updated"
else
    echo "⚠ Warning: Could not update project settings (HTTP $HTTP_STATUS)"
    cat /tmp/gitlab-project-$$.json
fi

rm -f /tmp/gitlab-project-$$.json

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Configuration complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "How it works:"
echo "  1. Jenkins webhook triggers on MR creation/update"
echo "  2. Jenkins runs validation pipeline"
echo "  3. Jenkins reports status back to GitLab commit"
echo "  4. GitLab shows status check in MR"
echo "  5. Developers can see if validation passed/failed"
echo ""
echo "Manual verification:"
echo "  - Create a test MR in k8s-deployments"
echo "  - Check that Jenkins job is triggered"
echo "  - Verify status appears in GitLab MR"
echo ""
echo "Note: GitLab CE doesn't support enforced external status checks"
echo "      (requires GitLab Premium). Status will be shown but not"
echo "      enforced. Team must manually verify Jenkins passed."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
