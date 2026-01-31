#!/bin/bash
# Demo: Skip Environment - Dev to Prod Direct (UC-D5)
#
# This demo showcases direct dev→prod promotion workflow - deploying
# an urgent change directly to prod without going through stage.
#
# Use Case UC-D5:
# "Critical security patch needs to go to prod. Stage is currently broken
#  for unrelated reasons."
#
# What This Demonstrates:
# - Direct dev→prod promotion bypasses the intermediate stage environment
# - Change is applied to dev and prod; stage remains unchanged
# - GitOps workflow is preserved (MR -> CI -> ArgoCD)
# - env.cue structure is maintained (no destructive overwrites)
#
# Flow:
# 1. Capture baseline state of all environments
# 2. Add urgent change to dev (ConfigMap entry)
# 3. Create promotion MR: dev → prod (skip stage)
# 4. Merge MR after CI passes
# 5. Verify prod has the change
# 6. Verify stage does NOT have the change
# 7. Cleanup (revert the change from both envs)
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

DEMO_KEY="priority-fix"
DEMO_VALUE="critical"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
DEMO_CONFIGMAP="${DEMO_APP}-config"
SOURCE_ENV="dev"
TARGET_ENV="prod"
SKIPPED_ENV="stage"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-D5: Skip Environment (Dev → Prod Direct)"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# Step 1: Verify Prerequisites
# ---------------------------------------------------------------------------

demo_step 1 "Verify Prerequisites"

demo_action "Checking kubectl connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    demo_fail "Cannot connect to Kubernetes cluster"
    exit 1
fi
demo_verify "Connected to Kubernetes cluster"

demo_action "Checking ArgoCD applications..."
for env in "$SOURCE_ENV" "$SKIPPED_ENV" "$TARGET_ENV"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

demo_action "Checking ConfigMaps exist in all environments..."
for env in "$SOURCE_ENV" "$SKIPPED_ENV" "$TARGET_ENV"; do
    if kubectl get configmap "$DEMO_CONFIGMAP" -n "$env" &>/dev/null; then
        demo_verify "ConfigMap $DEMO_CONFIGMAP exists in $env"
    else
        demo_fail "ConfigMap $DEMO_CONFIGMAP not found in $env"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Verify Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Verify Baseline State"

demo_info "Confirming '$DEMO_KEY' does not exist in any environment..."

for env in "$SOURCE_ENV" "$SKIPPED_ENV" "$TARGET_ENV"; do
    demo_action "Checking $env..."
    assert_configmap_entry_absent "$env" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
        demo_warn "Key '$DEMO_KEY' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_KEY' absent from all environments"

# Steps 3-10 will be added in subsequent tasks...
