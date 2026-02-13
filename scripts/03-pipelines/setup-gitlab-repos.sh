#!/usr/bin/env bash
#
# setup-gitlab-repos.sh
# Initialize and push repositories to GitLab
#
# Prerequisites:
# 1. GitLab is running at http://gitlab.local
# 2. GitLab projects created: p2c/example-app and p2c/k8s-deployments
# 3. GitLab personal access token created
#
# Usage:
#   export GITLAB_TOKEN="your-gitlab-token-here"
#   ./scripts/setup-gitlab-repos.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== GitLab Repositories Setup ===${NC}\n"

# Check prerequisites
if [ -z "$GITLAB_TOKEN" ]; then
    echo -e "${RED}ERROR: GITLAB_TOKEN environment variable not set${NC}"
    echo "Please set it first:"
    echo "  export GITLAB_TOKEN='your-token-here'"
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/../lib/infra.sh"

# Alias for backward compatibility
GITLAB_URL="${GITLAB_URL_INTERNAL}"
GITLAB_USER="${GITLAB_USER:-root}"

echo -e "${YELLOW}Using GitLab at: ${GITLAB_URL}${NC}"
echo -e "${YELLOW}GitLab user: ${GITLAB_USER}${NC}\n"

# Function to push repository
push_repo() {
    local repo_path=$1
    local repo_name=$2
    local remote_url="http://${GITLAB_USER}:${GITLAB_TOKEN}@${GITLAB_HOST_INTERNAL}/${GITLAB_GROUP}/${repo_name}.git"

    echo -e "${GREEN}Pushing ${repo_name}...${NC}"

    cd "$repo_path"

    # Check if remote already exists
    if git remote get-url gitlab &>/dev/null; then
        echo "  Remote 'gitlab' already exists, removing it..."
        git remote remove gitlab
    fi

    # Add remote
    git remote add gitlab "$remote_url"

    # Push
    git push -u gitlab main 2>/dev/null || git push -u gitlab master 2>/dev/null || {
        echo -e "${RED}  ERROR: Failed to push ${repo_name}${NC}"
        echo "  Make sure the GitLab project exists: ${GITLAB_GROUP}/${repo_name}"
        return 1
    }

    echo -e "${GREEN}  ✓ ${repo_name} pushed successfully${NC}\n"
    cd - > /dev/null
}

# Function to setup k8s-deployments with branches
setup_k8s_deployments() {
    echo -e "${GREEN}Setting up k8s-deployments repository with branches...${NC}"

    local repo_path="./k8s-deployments"
    local remote_url="http://${GITLAB_USER}:${GITLAB_TOKEN}@${GITLAB_HOST_INTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"

    cd "$repo_path"

    # Check if remote already exists
    if git remote get-url origin &>/dev/null; then
        echo "  Remote 'origin' already exists, removing it..."
        git remote remove origin
    fi

    # Add remote
    git remote add origin "$remote_url"

    # Ensure we're on master/main
    current_branch=$(git branch --show-current)
    echo "  Current branch: ${current_branch}"

    # Push master/main
    echo "  Pushing master branch..."
    git push -u origin master || git push -u origin main

    # Create and push dev branch
    echo "  Creating dev branch..."
    git checkout -b dev 2>/dev/null || git checkout dev
    echo "  Pushing dev branch..."
    git push -u origin dev

    # Create and push stage branch
    echo "  Creating stage branch..."
    git checkout -b stage 2>/dev/null || git checkout stage
    echo "  Pushing stage branch..."
    git push -u origin stage

    # Create and push prod branch
    echo "  Creating prod branch..."
    git checkout -b prod 2>/dev/null || git checkout prod
    echo "  Pushing prod branch..."
    git push -u origin prod

    # Return to master
    git checkout master 2>/dev/null || git checkout main

    echo -e "${GREEN}  ✓ k8s-deployments setup complete with branches: dev, stage, prod${NC}\n"
    cd - > /dev/null
}

# Main execution
echo -e "${YELLOW}Step 1: Push example-app repository${NC}"
push_repo "." "example-app"

echo -e "${YELLOW}Step 2: Setup k8s-deployments repository${NC}"
setup_k8s_deployments

echo -e "\n${GREEN}=== All repositories pushed successfully! ===${NC}\n"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Configure Jenkins credentials (gitlab-credentials, maven-repo-credentials, container-registry-credentials)"
echo "2. Create Jenkins pipeline job 'example-app-ci' pointing to GitLab"
echo "3. Configure ArgoCD to watch k8s-deployments repository"
echo "4. Trigger a build to test the end-to-end flow"
echo ""
echo -e "${GREEN}See SETUP_CHECKLIST.md for detailed instructions${NC}"
