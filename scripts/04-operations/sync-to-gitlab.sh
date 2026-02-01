#!/bin/bash
# Sync subtrees to GitLab for CI/CD pipeline execution
#
# This script publishes the example-app and k8s-deployments subfolders
# to their respective GitLab repositories, enabling:
# - GitLab webhooks to trigger Jenkins
# - ArgoCD to watch k8s-deployments
# - Independent CI/CD execution per component
#
# Prerequisites:
# - Remotes configured: gitlab-app, gitlab-deployments
# - GitLab projects exist: p2c/example-app, p2c/k8s-deployments
# - Clean working tree (no uncommitted changes)
#
# Usage:
#   ./scripts/sync-to-gitlab.sh [branch]
#   ./scripts/sync-to-gitlab.sh --pull-only example-app [branch]
#
# Options:
#   --pull-only <repo>  Pull changes from GitLab into local subtree
#                       Repo must be: example-app or k8s-deployments
#
# See docs/GIT_REMOTE_STRATEGY.md for full documentation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

# Parse arguments
PULL_ONLY=""
BRANCH="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull-only)
            PULL_ONLY="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            BRANCH="$1"
            shift
            ;;
    esac
done

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Handle --pull-only mode
if [[ -n "$PULL_ONLY" ]]; then
    echo -e "${GREEN}=== Pulling subtree from GitLab ===${NC}"
    echo "Repo: $PULL_ONLY"
    echo "Branch: $BRANCH"
    echo ""

    case "$PULL_ONLY" in
        example-app)
            if ! git remote get-url gitlab-app &>/dev/null; then
                echo -e "${RED}ERROR: Remote 'gitlab-app' not configured${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Pulling example-app from GitLab...${NC}"
            if GIT_SSL_NO_VERIFY=true git subtree pull --prefix=example-app gitlab-app "$BRANCH" -m "Merge example-app from GitLab" --allow-unrelated-histories 2>&1; then
                echo -e "${GREEN}  ✓ example-app pulled${NC}"
                exit 0
            else
                echo -e "${RED}  ✗ example-app pull failed${NC}"
                exit 1
            fi
            ;;
        k8s-deployments)
            if ! git remote get-url gitlab-deployments &>/dev/null; then
                echo -e "${RED}ERROR: Remote 'gitlab-deployments' not configured${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Pulling k8s-deployments from GitLab...${NC}"
            if GIT_SSL_NO_VERIFY=true git subtree pull --prefix=k8s-deployments gitlab-deployments "$BRANCH" -m "Merge k8s-deployments from GitLab" 2>&1; then
                echo -e "${GREEN}  ✓ k8s-deployments pulled${NC}"
                exit 0
            else
                echo -e "${RED}  ✗ k8s-deployments pull failed${NC}"
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}ERROR: Unknown repo '$PULL_ONLY'${NC}"
            echo "Valid repos: example-app, k8s-deployments"
            exit 1
            ;;
    esac
fi

echo -e "${GREEN}=== Syncing subtrees to GitLab ===${NC}"
echo "Branch: $BRANCH"
echo ""

# Check remotes exist
if ! git remote get-url gitlab-app &>/dev/null; then
    echo -e "${RED}ERROR: Remote 'gitlab-app' not configured${NC}"
    echo "Run: git remote add gitlab-app https://gitlab.jmann.local/p2c/example-app.git"
    exit 1
fi

if ! git remote get-url gitlab-deployments &>/dev/null; then
    echo -e "${RED}ERROR: Remote 'gitlab-deployments' not configured${NC}"
    echo "Run: git remote add gitlab-deployments https://gitlab.jmann.local/p2c/k8s-deployments.git"
    exit 1
fi

# Verify origin points to GitHub (full monorepo should be pushed there first)
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$ORIGIN_URL" != *"github.com"*"deployment-pipeline"* ]]; then
    echo -e "${YELLOW}WARNING: origin URL doesn't point to GitHub deployment-pipeline${NC}"
    echo "  Current: $ORIGIN_URL"
    echo "  Expected: https://github.com/mannjg/deployment-pipeline.git (or SSH equivalent)"
    echo ""
    echo "Remember: Push to GitHub FIRST, then sync subtrees to GitLab."
    echo "See docs/GIT_REMOTE_STRATEGY.md for details."
    echo ""
fi

# Check for clean working tree
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo -e "${YELLOW}WARNING: Working tree has uncommitted changes${NC}"
    echo "Subtree operations work best with a clean tree."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Sync example-app
echo -e "${YELLOW}Syncing example-app...${NC}"
if GIT_SSL_NO_VERIFY=true git subtree push --prefix=example-app gitlab-app "$BRANCH" 2>&1; then
    echo -e "${GREEN}  ✓ example-app synced${NC}"
else
    echo -e "${RED}  ✗ example-app sync failed${NC}"
    exit 1
fi

# Sync k8s-deployments
echo -e "${YELLOW}Syncing k8s-deployments...${NC}"
if GIT_SSL_NO_VERIFY=true git subtree push --prefix=k8s-deployments gitlab-deployments "$BRANCH" 2>&1; then
    echo -e "${GREEN}  ✓ k8s-deployments synced${NC}"
else
    echo -e "${RED}  ✗ k8s-deployments sync failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}=== Sync complete ===${NC}"
echo "  example-app      → gitlab.jmann.local/p2c/example-app"
echo "  k8s-deployments  → gitlab.jmann.local/p2c/k8s-deployments"
