#!/bin/bash
# Sync k8s-deployments to GitLab
# Pushes dev, stage, and prod branches to the p2c/k8s-deployments GitLab repo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source centralized config if available
if [[ -f "${PROJECT_ROOT}/config/gitlab.env" ]]; then
    source "${PROJECT_ROOT}/config/gitlab.env"
fi

# Get GitLab token from Kubernetes secret or environment
get_gitlab_token() {
    local token
    # Try k8s secret first
    token=$(kubectl get secret gitlab-api-token -n gitlab -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
    if [[ -z "$token" ]]; then
        # Check for local env file (not committed)
        if [[ -f "${PROJECT_ROOT}/config/local.env" ]]; then
            source "${PROJECT_ROOT}/config/local.env"
            token="$GITLAB_TOKEN"
        fi
    fi
    if [[ -z "$token" ]]; then
        echo "Error: GITLAB_TOKEN not found. Set it in environment, config/local.env, or ensure k8s secret exists." >&2
        exit 1
    fi
    echo "$token"
}

GITLAB_TOKEN="${GITLAB_TOKEN:-$(get_gitlab_token)}"
GITLAB_HOST="${GITLAB_HOST_EXTERNAL:-gitlab.jmann.local}"
GITLAB_GROUP="${GITLAB_GROUP:-p2c}"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Syncing k8s-deployments to GitLab"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "GitLab: ${GITLAB_HOST}"
echo "Group: ${GITLAB_GROUP}"
echo ""

cd "$K8S_DEPLOYMENTS_DIR"

# Configure remote with token
git remote set-url origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GITLAB_GROUP}/k8s-deployments.git" 2>/dev/null || \
    git remote add origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${GITLAB_GROUP}/k8s-deployments.git"

# Branches to sync
BRANCHES="${1:-dev stage prod}"

for branch in $BRANCHES; do
    echo "Pushing ${branch}..."
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        GIT_SSL_NO_VERIFY=true git push origin "$branch" --force
        echo "✓ ${branch} pushed"
    else
        echo "⚠ Branch ${branch} not found locally, skipping"
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Sync complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
