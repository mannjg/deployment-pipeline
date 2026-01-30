#!/bin/bash
# Demo: Environment Rollback (UC-D3)
#
# This demo showcases GitOps-based environment rollback - reverting an
# environment to its previous known-good state.
#
# Use Case UC-D3:
# "Stage deployment is unhealthy. Roll back to the previous known-good state"
#
# What This Demonstrates:
# - Git revert creates auditable rollback (preserves history)
# - Rollback goes through GitOps workflow (MR -> CI -> ArgoCD)
# - [no-promote] marker prevents cascading promotions
# - Other environments are NOT affected
#
# Flow:
# 1. Make a change to stage (simulating a "bad deploy")
# 2. Verify the change is deployed
# 3. Execute rollback using rollback-environment.sh
# 4. Verify stage returns to previous state
# 5. Verify dev/prod are unaffected
# 6. Verify no promotion MR was auto-created
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

DEMO_APP="example-app"
TARGET_ENV="stage"
OTHER_ENVS=("dev" "prod")

# The "bad" change we'll make and then roll back
# Using a ConfigMap entry as it's visible and doesn't affect app behavior
BAD_CONFIGMAP_KEY="rollback-test-key"
BAD_CONFIGMAP_VALUE="bad-value-$(date +%s)"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"
ROLLBACK_CLI="${PROJECT_ROOT}/scripts/04-operations/rollback-environment.sh"

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-D3: Environment Rollback"

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

demo_action "Checking rollback tool exists..."
if [[ ! -x "$ROLLBACK_CLI" ]]; then
    demo_fail "Rollback tool not found: $ROLLBACK_CLI"
    exit 1
fi
demo_verify "Rollback tool available"

demo_action "Checking ArgoCD applications..."
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Capture Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Capture Baseline State"

demo_info "Capturing current state before making 'bad' change..."

# Capture stage's current commit
BASELINE_COMMIT=$("$GITLAB_CLI" commit list p2c/k8s-deployments --ref "$TARGET_ENV" --limit 1 2>/dev/null | head -1 | awk '{print $1}')
demo_info "Stage baseline commit: $BASELINE_COMMIT"

# Capture ConfigMap state (should NOT have our test key)
demo_action "Verifying test key does NOT exist in $TARGET_ENV ConfigMap..."
if kubectl get configmap "${DEMO_APP}-config" -n "$TARGET_ENV" -o jsonpath="{.data.${BAD_CONFIGMAP_KEY}}" 2>/dev/null | grep -q .; then
    demo_warn "Test key already exists - demo state not clean"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi
demo_verify "Baseline confirmed: test key not present"

# ---------------------------------------------------------------------------
# Step 3: Make a "Bad" Change to Stage
# ---------------------------------------------------------------------------

demo_step 3 "Make a 'Bad' Change to Stage"

demo_info "Simulating a bad deployment by adding a ConfigMap entry..."
demo_info "  Key: $BAD_CONFIGMAP_KEY"
demo_info "  Value: $BAD_CONFIGMAP_VALUE"

# Get current env.cue from stage branch
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
STAGE_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$STAGE_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Add ConfigMap entry using cue-edit.py
# Note: Temp file must be in k8s-deployments so cue-edit.py finds CUE module context
demo_action "Adding ConfigMap entry..."
TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$STAGE_ENV_CUE" > "$TEMP_CUE"

python3 "${CUE_EDIT}" env-configmap add "$TEMP_CUE" "$TARGET_ENV" "exampleApp" \
    "$BAD_CONFIGMAP_KEY" "$BAD_CONFIGMAP_VALUE"

MODIFIED_ENV_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

demo_verify "Modified env.cue with bad ConfigMap entry"

# Create feature branch and push
FEATURE_BRANCH="uc-d3-bad-change-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null
demo_verify "Created feature branch"

demo_action "Pushing bad change to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add $BAD_CONFIGMAP_KEY to stage (will be rolled back)" \
    --stdin >/dev/null
demo_verify "Bad change pushed"

# Create and merge MR
demo_action "Creating MR: $FEATURE_BRANCH -> $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "UC-D3: Add bad config (will rollback)")

demo_action "Waiting for Jenkins CI..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Capture baseline for ArgoCD
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

demo_action "Merging MR..."
accept_mr "$mr_iid" || exit 1

# ---------------------------------------------------------------------------
# Step 4: Verify Bad Change is Deployed
# ---------------------------------------------------------------------------

demo_step 4 "Verify Bad Change is Deployed"

demo_action "Waiting for ArgoCD to sync the bad change..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_action "Verifying bad ConfigMap entry is now present..."
BAD_COMMIT=$("$GITLAB_CLI" commit list p2c/k8s-deployments --ref "$TARGET_ENV" --limit 1 2>/dev/null | head -1 | awk '{print $1}')
demo_info "Bad commit: $BAD_COMMIT"

# Verify the ConfigMap has our bad value
actual_value=$(kubectl get configmap "${DEMO_APP}-config" -n "$TARGET_ENV" \
    -o jsonpath="{.data.${BAD_CONFIGMAP_KEY}}" 2>/dev/null || echo "")

if [[ "$actual_value" == "$BAD_CONFIGMAP_VALUE" ]]; then
    demo_verify "Bad change deployed: $BAD_CONFIGMAP_KEY = $BAD_CONFIGMAP_VALUE"
else
    demo_fail "Bad change not found in ConfigMap (got: '$actual_value')"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Execute Rollback
# ---------------------------------------------------------------------------

demo_step 5 "Execute Rollback"

# Wait a moment to ensure Jenkins has processed the bad deploy and created any MRs
sleep 15

# Capture promotion MR count AFTER bad deploy is fully processed
PRE_ROLLBACK_MR_COUNT=$("$GITLAB_CLI" mr promotion-pending p2c/k8s-deployments prod 2>/dev/null | wc -l || echo "0")
demo_info "Promotion MRs to prod before rollback: $PRE_ROLLBACK_MR_COUNT (from bad deploy, expected)"

demo_info "Simulating: 'Stage has bad config! Roll it back!'"
demo_info "Using rollback-environment.sh tool..."

# Capture ArgoCD baseline before rollback
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

demo_action "Executing rollback..."
"$ROLLBACK_CLI" "$TARGET_ENV" --reason "UC-D3 Demo: Rolling back bad config change" || {
    demo_fail "Rollback command failed"
    exit 1
}
demo_verify "Rollback command completed"

# ---------------------------------------------------------------------------
# Step 6: Verify Rollback Succeeded
# ---------------------------------------------------------------------------

demo_step 6 "Verify Rollback Succeeded"

demo_action "Waiting for ArgoCD to sync the rollback..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_action "Verifying bad ConfigMap entry is now GONE..."
actual_value=$(kubectl get configmap "${DEMO_APP}-config" -n "$TARGET_ENV" \
    -o jsonpath="{.data.${BAD_CONFIGMAP_KEY}}" 2>/dev/null || echo "")

if [[ -z "$actual_value" ]]; then
    demo_verify "Rollback successful: $BAD_CONFIGMAP_KEY no longer present"
else
    demo_fail "Rollback failed: $BAD_CONFIGMAP_KEY still has value '$actual_value'"
    exit 1
fi

# Verify commit history shows revert
CURRENT_COMMIT_TITLE=$("$GITLAB_CLI" commit list p2c/k8s-deployments --ref "$TARGET_ENV" --limit 1 2>/dev/null | head -1 | cut -d' ' -f2-)
demo_info "Latest commit: $CURRENT_COMMIT_TITLE"
if [[ "$CURRENT_COMMIT_TITLE" == *"Revert"* ]]; then
    demo_verify "Git history shows revert commit (auditable)"
else
    demo_warn "Expected 'Revert' in commit message"
fi

# ---------------------------------------------------------------------------
# Step 7: Verify No Cascading Promotion
# ---------------------------------------------------------------------------

demo_step 7 "Verify No Cascading Promotion"

demo_info "Checking that no NEW auto-promotion MR was created by the rollback..."
demo_info "(The revert commit detection should have prevented this)"

# Wait a moment for any MR to be created
sleep 10

# Check for promotion MRs - count should be same as before rollback
POST_ROLLBACK_MR_COUNT=$("$GITLAB_CLI" mr promotion-pending p2c/k8s-deployments prod 2>/dev/null | wc -l || echo "0")
demo_info "Promotion MRs to prod after rollback: $POST_ROLLBACK_MR_COUNT"

if [[ "$POST_ROLLBACK_MR_COUNT" -le "$PRE_ROLLBACK_MR_COUNT" ]]; then
    demo_verify "No new promotion MR was created by rollback (correct!)"
    if [[ "$PRE_ROLLBACK_MR_COUNT" -gt 0 ]]; then
        demo_info "(Note: $PRE_ROLLBACK_MR_COUNT existing MR(s) from bad deploy remain open - close them after investigation)"
    fi
else
    demo_fail "Rollback created a promotion MR (should not happen)"
    demo_info "Pre-rollback count: $PRE_ROLLBACK_MR_COUNT, post-rollback: $POST_ROLLBACK_MR_COUNT"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Verify Other Environments Unaffected
# ---------------------------------------------------------------------------

demo_step 8 "Verify Other Environments Unaffected"

demo_info "Verifying dev and prod were NOT affected by stage rollback..."

for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env..."
    # Just verify the environment is healthy (didn't break anything)
    app_health=$(kubectl get application "${DEMO_APP}-${env}" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

    if [[ "$app_health" == "Healthy" ]]; then
        demo_verify "$env is healthy and unaffected"
    else
        demo_warn "$env health: $app_health"
    fi
done

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-D3: Environment Rollback

  What happened:
  1. Made a "bad" change to stage (added ConfigMap entry)
  2. Verified the bad change was deployed via GitOps
  3. Executed rollback using rollback-environment.sh
  4. Verified:
     - Stage returned to previous state (ConfigMap entry gone)
     - Git history shows revert commit (auditable)
     - No promotion MR was auto-created ([no-promote] worked)
     - dev/prod were unaffected

  Key Observations:
  - Rollback is a git operation (revert), not kubectl
  - Full audit trail preserved in git history
  - [no-promote] marker prevents cascading rollbacks
  - ArgoCD auto-syncs the reverted manifests
  - Other environments remain stable

  Operational Pattern:
    Bad deploy to stage
        |
        v
    rollback-environment.sh stage --reason "..."
        |
        v
    Git revert commit (with [no-promote])
        |
        v
    Jenkins regenerates manifests
        |
        v
    ArgoCD syncs previous state
        |
        v
    Stage restored, no cascade to prod

EOF

# ---------------------------------------------------------------------------
# Step 10: Cleanup
# ---------------------------------------------------------------------------

demo_step 10 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
