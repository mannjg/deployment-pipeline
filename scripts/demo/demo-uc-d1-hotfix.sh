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
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

demo_action "Checking ConfigMaps exist in all environments..."
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    ns=$(get_namespace "$env")
    if kubectl get configmap "$DEMO_CONFIGMAP" -n "$ns" &>/dev/null; then
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

for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env..."
    assert_configmap_entry_absent "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
        demo_warn "Key '$DEMO_KEY' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_KEY' absent from all environments"

# ---------------------------------------------------------------------------
# Step 3: Create Hotfix Branch from Prod
# ---------------------------------------------------------------------------

demo_step 3 "Create Hotfix Branch from Prod"

demo_info "CRITICAL: Creating branch from PROD (not dev!) for emergency hotfix"
demo_info "This bypasses the normal dev→stage→prod promotion chain"

# Get current env.cue content from prod branch
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
PROD_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Check if entry already exists
if echo "$PROD_ENV_CUE" | grep -q "\"$DEMO_KEY\""; then
    demo_warn "Key '$DEMO_KEY' already exists in $TARGET_ENV's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify the content using cue-edit.py
demo_action "Adding emergency ConfigMap fix: $DEMO_KEY=$DEMO_VALUE"
demo_info "Scenario: API timeouts in prod, need to increase timeout immediately"

# Create temp file for cue-edit.py (must be in k8s-deployments for CUE module context)
TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$PROD_ENV_CUE" > "$TEMP_CUE"

python3 "${CUE_EDIT}" env-configmap add "$TEMP_CUE" "$TARGET_ENV" "$DEMO_APP_CUE" \
    "$DEMO_KEY" "$DEMO_VALUE"

MODIFIED_ENV_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

demo_verify "Modified env.cue with emergency fix"

# Generate feature branch name
FEATURE_BRANCH="uc-d1-hotfix-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $FEATURE_BRANCH from $TARGET_ENV (not dev!)"

demo_action "Pushing hotfix to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "hotfix: increase $DEMO_KEY to $DEMO_VALUE [emergency]" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Hotfix pushed to feature branch"

# ---------------------------------------------------------------------------
# Step 4: Create Direct MR to Prod
# ---------------------------------------------------------------------------

demo_step 4 "Create Direct MR to Prod"

demo_info "Creating MR directly to $TARGET_ENV (bypassing dev/stage)"

# Create MR from feature branch to prod
demo_action "Creating MR: $FEATURE_BRANCH → $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "HOTFIX: Increase $DEMO_KEY to $DEMO_VALUE [UC-D1]")

# ---------------------------------------------------------------------------
# Step 5: Wait for Pipeline and Merge
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Pipeline and Merge"

# Wait for MR pipeline (Jenkins generates manifests)
demo_action "Waiting for Jenkins CI to validate and generate manifests..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains expected changes..."
assert_mr_contains_diff "$mr_iid" "env.cue" "$DEMO_KEY" || exit 1
assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_KEY" || exit 1
demo_verify "MR contains CUE change and regenerated manifests"

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

# Merge MR
demo_info "Merging emergency hotfix to production..."
accept_mr "$mr_iid" || exit 1

# ---------------------------------------------------------------------------
# Step 6: Wait for ArgoCD Sync
# ---------------------------------------------------------------------------

demo_step 6 "Wait for ArgoCD Sync"

# Wait for ArgoCD to sync prod
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_verify "$TARGET_ENV environment synced with hotfix"

# ---------------------------------------------------------------------------
# Step 7: Verify Hotfix and Environment Isolation
# ---------------------------------------------------------------------------

demo_step 7 "Verify Hotfix and Environment Isolation"

demo_info "Verifying '$DEMO_KEY' exists ONLY in $TARGET_ENV..."

# Verify prod HAS the entry
demo_action "Checking $TARGET_ENV (should HAVE the fix)..."
assert_configmap_entry "$(get_namespace "$TARGET_ENV")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$DEMO_VALUE" || exit 1

# Verify dev/stage do NOT have the entry
for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env (should NOT have the fix)..."
    assert_configmap_entry_absent "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
        demo_fail "ISOLATION VIOLATED: $env has '$DEMO_KEY' but should not!"
        exit 1
    }
done

demo_verify "HOTFIX CONFIRMED: Only $TARGET_ENV has '$DEMO_KEY'"
demo_verify "ISOLATION CONFIRMED: dev and stage are unchanged"

# ---------------------------------------------------------------------------
# Step 8: Summary
# ---------------------------------------------------------------------------

demo_step 8 "Summary"

cat << EOF

  This demo validated UC-D1: Emergency Hotfix to Production

  Scenario:
  "Prod is experiencing API timeouts. Need to increase timeout immediately
   without waiting for dev→stage→prod promotion."

  What happened:
  1. Created feature branch FROM PROD (not dev!)
  2. Applied emergency fix: $DEMO_KEY=$DEMO_VALUE
  3. Created MR directly to $TARGET_ENV (bypassing dev/stage)
  4. Jenkins CI validated and regenerated manifests
  5. Merged MR to $TARGET_ENV
  6. ArgoCD synced the hotfix
  7. Verified:
     - $TARGET_ENV ConfigMap HAS '$DEMO_KEY=$DEMO_VALUE'
     - dev ConfigMap does NOT have '$DEMO_KEY'
     - stage ConfigMap does NOT have '$DEMO_KEY'

  Key Observations:
  - Emergency fixes can bypass the promotion chain
  - Direct-to-prod MRs work correctly
  - GitOps workflow is preserved (audit trail via MR)
  - Other environments are NOT affected
  - env.cue structure is maintained

  Operational Pattern:
    Production incident detected
        |
        v
    Create branch from PROD (not dev!)
        |
        v
    Apply emergency fix
        |
        v
    Create MR: feature → prod (direct)
        |
        v
    CI validates, merge MR
        |
        v
    ArgoCD syncs fix to prod
        |
        v
    Incident resolved (dev/stage unchanged)
        |
        v
    [Later] Backport fix to dev/stage if needed

EOF

# ---------------------------------------------------------------------------
# Step 9: Cleanup
# ---------------------------------------------------------------------------

demo_step 9 "Cleanup"

demo_info "Reverting the hotfix to restore clean state..."

# Get current env.cue from prod (with the hotfix)
HOTFIX_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

# Remove the hotfix key using cue-edit.py
TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$HOTFIX_ENV_CUE" > "$TEMP_CUE"

python3 "${CUE_EDIT}" env-configmap remove "$TEMP_CUE" "$TARGET_ENV" "$DEMO_APP_CUE" "$DEMO_KEY"

REVERTED_ENV_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

# Create cleanup branch
CLEANUP_BRANCH="uc-d1-cleanup-$(date +%s)"

demo_action "Creating cleanup branch '$CLEANUP_BRANCH' from $TARGET_ENV..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$CLEANUP_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create cleanup branch"
    exit 1
}

demo_action "Pushing cleanup to GitLab..."
echo "$REVERTED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$CLEANUP_BRANCH" \
    --message "chore: remove $DEMO_KEY hotfix (UC-D1 cleanup)" \
    --stdin >/dev/null || {
    demo_fail "Failed to push cleanup"
    exit 1
}

# Create and merge cleanup MR
demo_action "Creating cleanup MR..."
cleanup_mr_iid=$(create_mr "$CLEANUP_BRANCH" "$TARGET_ENV" "Cleanup: Remove $DEMO_KEY hotfix [UC-D1]")

demo_action "Waiting for cleanup CI..."
wait_for_mr_pipeline "$cleanup_mr_iid" || exit 1

# Capture ArgoCD baseline before cleanup merge
cleanup_argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

demo_action "Merging cleanup MR..."
accept_mr "$cleanup_mr_iid" || exit 1

demo_action "Waiting for ArgoCD to sync cleanup..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$cleanup_argocd_baseline" || exit 1

# Verify cleanup worked
demo_action "Verifying hotfix key removed from prod..."
assert_configmap_entry_absent "$(get_namespace "$TARGET_ENV")" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
    demo_fail "Cleanup failed: '$DEMO_KEY' still exists in $TARGET_ENV"
    exit 1
}
demo_verify "Cleanup complete: '$DEMO_KEY' removed from $TARGET_ENV"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branches left in GitLab for reference:"
demo_info "  - $FEATURE_BRANCH (hotfix)"
demo_info "  - $CLEANUP_BRANCH (cleanup)"

demo_complete