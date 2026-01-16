#!/bin/bash
# Sync k8s-deployments to GitLab
# Pushes dev, stage, and prod branches to the p2c/k8s-deployments GitLab repo
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)

K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

log_header "Syncing k8s-deployments to GitLab"
log_info "GitLab: ${GITLAB_HOST_EXTERNAL}"
log_info "Group: ${GITLAB_GROUP}"
echo ""

cd "$K8S_DEPLOYMENTS_DIR"

# Configure remote with token
git remote set-url origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST_EXTERNAL}/${GITLAB_GROUP}/k8s-deployments.git" 2>/dev/null || \
    git remote add origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST_EXTERNAL}/${GITLAB_GROUP}/k8s-deployments.git"

# Branches to sync
BRANCHES="${1:-dev stage prod}"

for branch in $BRANCHES; do
    log_step "Pushing ${branch}..."
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        GIT_SSL_NO_VERIFY=true git push origin "$branch" --force
        log_pass "${branch} pushed"
    else
        log_warn "Branch ${branch} not found locally, skipping"
    fi
done

echo ""
log_header "Sync Complete"
