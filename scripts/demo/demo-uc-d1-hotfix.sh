#!/bin/bash
# Demo: Emergency Hotfix to Production (UC-D1)
#
# This demo showcases direct-to-production hotfix workflow - deploying
# an emergency fix directly to prod without going through dev/stage.
#
# Use Case UC-D1:
# "Prod is broken. I need to deploy a fix immediately without waiting for dev→stage→prod"
#
# What This Demonstrates:
# - Direct MR to prod bypasses the normal promotion chain
# - Fix is applied only to prod; dev/stage remain unchanged
# - GitOps workflow is preserved (MR -> CI -> ArgoCD)
# - env.cue structure is maintained (no destructive overwrites)
#
# Flow:
# 1. Capture baseline state of all environments
# 2. Create feature branch from prod (not dev!)
# 3. Apply emergency fix (ConfigMap entry)
# 4. Create MR: feature → prod (direct)
# 5. Merge MR after CI passes
# 6. Verify prod has the fix
# 7. Verify dev/stage are unchanged
# 8. Cleanup (revert the hotfix)
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_KEY="hotfix-timeout"
DEMO_VALUE="60"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
DEMO_CONFIGMAP="${DEMO_APP}-config"
TARGET_ENV="prod"
OTHER_ENVS=("dev" "stage")

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-D1: Emergency Hotfix to Production"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"
