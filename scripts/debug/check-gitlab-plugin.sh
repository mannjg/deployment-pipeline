#!/bin/bash
# Check GitLab plugin installation and configuration

set -e

JENKINS_URL="http://jenkins.local"

echo "Getting Jenkins credentials..."
JENKINS_PASSWORD=$(kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

echo "Checking GitLab plugin installation..."
GITLAB_PLUGINS=$(curl -s -u "admin:${JENKINS_PASSWORD}" "${JENKINS_URL}/pluginManager/api/json?depth=1" | \
  jq -r '.plugins[] | select(.shortName | contains("gitlab")) | "\(.shortName): \(.version) (active: \(.active))"')

if [ -z "$GITLAB_PLUGINS" ]; then
    echo "✗ GitLab plugin not found"
    echo ""
    echo "To install:"
    echo "  1. Visit: ${JENKINS_URL}/manage/pluginManager/available"
    echo "  2. Search: gitlab"
    echo "  3. Install: GitLab Plugin"
    exit 1
else
    echo "✓ GitLab plugin(s) found:"
    echo "$GITLAB_PLUGINS"
fi

echo ""
echo "Checking GitLab connection configuration..."
# Check if connection is configured
curl -s -u "admin:${JENKINS_PASSWORD}" "${JENKINS_URL}/configure" | \
  grep -q "gitlab" && echo "✓ GitLab configuration present" || echo "⚠ GitLab connection may need configuration"

echo ""
echo "Next steps:"
echo "  1. Configure connection: ${JENKINS_URL}/manage/configure"
echo "  2. Look for 'GitLab' section"
echo "  3. Add connection with gitlab.local URL and API token"
