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

# ---------------------------------------------------------------------------
# Step 3: Add Urgent Change to Dev
# ---------------------------------------------------------------------------

demo_step 3 "Add Urgent Change to Dev"

demo_info "Scenario: Critical security patch needs to be deployed urgently"
demo_info "Adding ConfigMap entry: $DEMO_KEY=$DEMO_VALUE"

# Get current env.cue content from dev branch
demo_action "Fetching $SOURCE_ENV's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "$SOURCE_ENV" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $SOURCE_ENV branch"
    exit 1
fi
demo_verify "Retrieved $SOURCE_ENV's env.cue"

# Check if entry already exists
if echo "$DEV_ENV_CUE" | grep -q "\"$DEMO_KEY\""; then
    demo_warn "Key '$DEMO_KEY' already exists in $SOURCE_ENV's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify the content using cue-edit.py
demo_action "Adding ConfigMap entry: $DEMO_KEY=$DEMO_VALUE"

# Create temp file for cue-edit.py (must be in k8s-deployments for CUE module context)
TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$DEV_ENV_CUE" > "$TEMP_CUE"

python3 "${CUE_EDIT}" env-configmap add "$TEMP_CUE" "$SOURCE_ENV" "$DEMO_APP_CUE" \
    "$DEMO_KEY" "$DEMO_VALUE"

MODIFIED_DEV_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

demo_verify "Modified env.cue with urgent fix"

# Generate feature branch name
DEV_FEATURE_BRANCH="uc-d5-dev-$(date +%s)"

demo_action "Creating branch '$DEV_FEATURE_BRANCH' from $SOURCE_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$DEV_FEATURE_BRANCH" --from "$SOURCE_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $DEV_FEATURE_BRANCH from $SOURCE_ENV"

demo_action "Pushing change to GitLab..."
echo "$MODIFIED_DEV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$DEV_FEATURE_BRANCH" \
    --message "feat: add $DEMO_KEY=$DEMO_VALUE [UC-D5 security patch]" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Change pushed to feature branch"

# ---------------------------------------------------------------------------
# Step 4: Create and Merge Dev MR
# ---------------------------------------------------------------------------

demo_step 4 "Create and Merge Dev MR"

demo_info "Merging security patch to $SOURCE_ENV via standard MR workflow"

# Create MR from feature branch to dev
demo_action "Creating MR: $DEV_FEATURE_BRANCH → $SOURCE_ENV..."
dev_mr_iid=$(create_mr "$DEV_FEATURE_BRANCH" "$SOURCE_ENV" "feat: Add $DEMO_KEY security patch [UC-D5]")

# Wait for MR pipeline (Jenkins generates manifests)
demo_action "Waiting for Jenkins CI to validate and generate manifests..."
wait_for_mr_pipeline "$dev_mr_iid" || exit 1

# Capture ArgoCD baseline before merge
dev_argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${SOURCE_ENV}")

# Merge MR
demo_info "Merging to $SOURCE_ENV..."
accept_mr "$dev_mr_iid" || exit 1

# Wait for ArgoCD to sync dev
demo_action "Waiting for ArgoCD to sync $SOURCE_ENV..."
wait_for_argocd_sync "${DEMO_APP}-${SOURCE_ENV}" "$dev_argocd_baseline" || exit 1

# Verify dev has the change
demo_action "Verifying $SOURCE_ENV has the change..."
assert_configmap_entry "$SOURCE_ENV" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$DEMO_VALUE" || exit 1

demo_verify "Security patch deployed to $SOURCE_ENV"

# ---------------------------------------------------------------------------
# Step 5: Simulate Stage Unavailable
# ---------------------------------------------------------------------------

demo_step 5 "Simulate Stage Unavailable"

demo_info "SCENARIO: Stage environment is broken/unavailable"
demo_info "Normal promotion (dev → stage → prod) would be blocked"
demo_info "We need to skip stage and promote directly to prod"
demo_warn "This is an emergency bypass - not normal operation!"

# Note: We don't actually break stage. The demo shows that we CAN
# skip it when needed. In reality, stage might be:
# - Out of disk space
# - Stuck deployment
# - Network issues
# - Undergoing maintenance

demo_info ""
demo_info "Stage status: [SIMULATED BROKEN]"
demo_info "Decision: Skip stage, promote dev → prod directly"

# ---------------------------------------------------------------------------
# Step 6: Direct Dev→Prod Promotion (Skipping Stage)
# ---------------------------------------------------------------------------

demo_step 6 "Direct Dev→Prod Promotion (Skipping Stage)"

demo_info "CRITICAL: Creating promotion branch from DEV directly to PROD"
demo_info "This bypasses the normal dev → stage → prod chain"

# Get current env.cue from prod branch (we need to preserve prod's settings)
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
PROD_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Add the same change to prod's env.cue
demo_action "Adding ConfigMap entry to prod: $DEMO_KEY=$DEMO_VALUE"

TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$PROD_ENV_CUE" > "$TEMP_CUE"

python3 "${CUE_EDIT}" env-configmap add "$TEMP_CUE" "$TARGET_ENV" "$DEMO_APP_CUE" \
    "$DEMO_KEY" "$DEMO_VALUE"

MODIFIED_PROD_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

demo_verify "Modified prod env.cue with security patch"

# Generate feature branch name for prod promotion
PROD_FEATURE_BRANCH="uc-d5-skip-$(date +%s)"

demo_action "Creating branch '$PROD_FEATURE_BRANCH' from $TARGET_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$PROD_FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $PROD_FEATURE_BRANCH from $TARGET_ENV"

demo_action "Pushing skip-promotion to GitLab..."
echo "$MODIFIED_PROD_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$PROD_FEATURE_BRANCH" \
    --message "feat: SKIP-PROMOTE $DEMO_KEY=$DEMO_VALUE from dev [UC-D5 emergency]" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Skip-promotion pushed to feature branch"

# ---------------------------------------------------------------------------
# Step 7: Create and Merge Prod MR
# ---------------------------------------------------------------------------

demo_step 7 "Create and Merge Prod MR"

demo_info "Creating MR directly to $TARGET_ENV (skipping $SKIPPED_ENV)"

# Create MR from feature branch to prod (DIRECT)
demo_action "Creating MR: $PROD_FEATURE_BRANCH → $TARGET_ENV..."
prod_mr_iid=$(create_mr "$PROD_FEATURE_BRANCH" "$TARGET_ENV" "SKIP-PROMOTE: $DEMO_KEY security patch [UC-D5]")

# Wait for MR pipeline (Jenkins generates manifests)
demo_action "Waiting for Jenkins CI to validate and generate manifests..."
wait_for_mr_pipeline "$prod_mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains expected changes..."
assert_mr_contains_diff "$prod_mr_iid" "env.cue" "$DEMO_KEY" || exit 1
assert_mr_contains_diff "$prod_mr_iid" "manifests/.*\\.yaml" "$DEMO_KEY" || exit 1
demo_verify "MR contains CUE change and regenerated manifests"

# Capture ArgoCD baseline before merge
prod_argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

# Merge MR
demo_info "Merging emergency skip-promotion to $TARGET_ENV..."
accept_mr "$prod_mr_iid" || exit 1

# Wait for ArgoCD to sync prod
demo_action "Waiting for ArgoCD to sync $TARGET_ENV..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$prod_argocd_baseline" || exit 1

demo_verify "$TARGET_ENV environment synced with security patch"

# ---------------------------------------------------------------------------
# Step 8: Verify Skip Isolation
# ---------------------------------------------------------------------------

demo_step 8 "Verify Skip Isolation"

demo_info "Verifying '$DEMO_KEY' exists in $SOURCE_ENV and $TARGET_ENV but NOT in $SKIPPED_ENV..."

# Verify dev HAS the entry
demo_action "Checking $SOURCE_ENV (should HAVE the fix)..."
assert_configmap_entry "$SOURCE_ENV" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$DEMO_VALUE" || exit 1

# Verify prod HAS the entry
demo_action "Checking $TARGET_ENV (should HAVE the fix)..."
assert_configmap_entry "$TARGET_ENV" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$DEMO_VALUE" || exit 1

# Verify stage does NOT have the entry
demo_action "Checking $SKIPPED_ENV (should NOT have the fix)..."
assert_configmap_entry_absent "$SKIPPED_ENV" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
    demo_fail "SKIP VIOLATED: $SKIPPED_ENV has '$DEMO_KEY' but should not!"
    exit 1
}

demo_verify "SKIP CONFIRMED: $SOURCE_ENV and $TARGET_ENV have '$DEMO_KEY'"
demo_verify "ISOLATION CONFIRMED: $SKIPPED_ENV is unchanged (still doesn't have '$DEMO_KEY')"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-D5: Skip Environment (Dev → Prod Direct)

  Scenario:
  "Critical security patch needs to go to prod. Stage is broken/unavailable
   and we cannot wait for it to be fixed."

  What happened:
  1. Added security patch to $SOURCE_ENV: $DEMO_KEY=$DEMO_VALUE
  2. Merged to $SOURCE_ENV via standard MR workflow
  3. Simulated $SKIPPED_ENV being unavailable
  4. Created skip-promotion branch from $TARGET_ENV
  5. Applied same change to $TARGET_ENV's env.cue
  6. Created MR directly to $TARGET_ENV (bypassing $SKIPPED_ENV)
  7. Jenkins CI validated and regenerated manifests
  8. Merged MR to $TARGET_ENV
  9. Verified:
     - $SOURCE_ENV ConfigMap HAS '$DEMO_KEY=$DEMO_VALUE'
     - $TARGET_ENV ConfigMap HAS '$DEMO_KEY=$DEMO_VALUE'
     - $SKIPPED_ENV ConfigMap does NOT have '$DEMO_KEY'

  Key Observations:
  - Emergency skip-promotion can bypass broken environments
  - Direct-to-prod MRs work correctly (preserve env.cue settings)
  - GitOps workflow is preserved (audit trail via MR)
  - Skipped environment is NOT affected
  - Normal flow can resume once $SKIPPED_ENV is fixed

  Realignment Path (after $SKIPPED_ENV is fixed):
    Option A: Next normal promotion catches $SKIPPED_ENV up automatically
    Option B: Manual promotion from $SOURCE_ENV → $SKIPPED_ENV if urgent

  Operational Pattern:
    Urgent change tested in dev
        |
        v
    Stage broken/unavailable
        |
        v
    Create branch from PROD
        |
        v
    Apply change to prod's env.cue
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
    Change in prod (stage still unchanged)
        |
        v
    [Later] Stage comes back → normal flow resumes

EOF

# ---------------------------------------------------------------------------
# Step 10: Cleanup
# ---------------------------------------------------------------------------

demo_step 10 "Cleanup"

demo_info "Removing the test key to restore clean state..."

# Cleanup dev
demo_action "Cleaning up $SOURCE_ENV..."
DEV_CLEANUP_CUE=$(get_file_from_branch "$SOURCE_ENV" "env.cue")
TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$DEV_CLEANUP_CUE" > "$TEMP_CUE"
python3 "${CUE_EDIT}" env-configmap remove "$TEMP_CUE" "$SOURCE_ENV" "$DEMO_APP_CUE" "$DEMO_KEY"
DEV_CLEANED_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

DEV_CLEANUP_BRANCH="uc-d5-cleanup-dev-$(date +%s)"
"$GITLAB_CLI" branch create p2c/k8s-deployments "$DEV_CLEANUP_BRANCH" --from "$SOURCE_ENV" >/dev/null
echo "$DEV_CLEANED_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$DEV_CLEANUP_BRANCH" \
    --message "chore: remove $DEMO_KEY [no-promote] [UC-D5 cleanup]" \
    --stdin >/dev/null

dev_cleanup_mr_iid=$(create_mr "$DEV_CLEANUP_BRANCH" "$SOURCE_ENV" "Cleanup: Remove $DEMO_KEY [no-promote] [UC-D5]")
wait_for_mr_pipeline "$dev_cleanup_mr_iid" || exit 1
dev_cleanup_argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${SOURCE_ENV}")
accept_mr "$dev_cleanup_mr_iid" || exit 1
wait_for_argocd_sync "${DEMO_APP}-${SOURCE_ENV}" "$dev_cleanup_argocd_baseline" || exit 1
demo_verify "$SOURCE_ENV cleaned up"

# Cleanup prod
demo_action "Cleaning up $TARGET_ENV..."
PROD_CLEANUP_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")
TEMP_CUE="${K8S_DEPLOYMENTS_DIR}/.temp-env-cue.cue"
echo "$PROD_CLEANUP_CUE" > "$TEMP_CUE"
python3 "${CUE_EDIT}" env-configmap remove "$TEMP_CUE" "$TARGET_ENV" "$DEMO_APP_CUE" "$DEMO_KEY"
PROD_CLEANED_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

PROD_CLEANUP_BRANCH="uc-d5-cleanup-prod-$(date +%s)"
"$GITLAB_CLI" branch create p2c/k8s-deployments "$PROD_CLEANUP_BRANCH" --from "$TARGET_ENV" >/dev/null
echo "$PROD_CLEANED_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$PROD_CLEANUP_BRANCH" \
    --message "chore: remove $DEMO_KEY [no-promote] [UC-D5 cleanup]" \
    --stdin >/dev/null

prod_cleanup_mr_iid=$(create_mr "$PROD_CLEANUP_BRANCH" "$TARGET_ENV" "Cleanup: Remove $DEMO_KEY [no-promote] [UC-D5]")
wait_for_mr_pipeline "$prod_cleanup_mr_iid" || exit 1
prod_cleanup_argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")
accept_mr "$prod_cleanup_mr_iid" || exit 1
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$prod_cleanup_argocd_baseline" || exit 1
demo_verify "$TARGET_ENV cleaned up"

# Close any orphaned promotion MRs to stage (created when we merged to dev, but never merged since we skipped stage)
# Also delete the source branches to avoid "lingering branch" warnings
demo_action "Closing orphaned promotion MRs to $SKIPPED_ENV..."
STAGE_MRS=$("$GITLAB_CLI" mr list p2c/k8s-deployments --state opened --target "$SKIPPED_ENV" 2>/dev/null || echo "[]")
PROMOTE_MRS_DATA=$(echo "$STAGE_MRS" | jq -r 'if type == "array" then . else [.] end | map(select(.source_branch | startswith("promote-"))) | .[] | "\(.iid) \(.source_branch)"')
while IFS=' ' read -r mr_iid source_branch; do
    [[ -z "$mr_iid" ]] && continue
    demo_info "Closing orphaned promotion MR !$mr_iid and deleting branch $source_branch"
    "$GITLAB_CLI" mr close p2c/k8s-deployments "$mr_iid" >/dev/null 2>&1 || true
    "$GITLAB_CLI" branch delete p2c/k8s-deployments "$source_branch" >/dev/null 2>&1 || true
done <<< "$PROMOTE_MRS_DATA"
demo_verify "Orphaned promotion MRs closed"

# Verify cleanup worked
demo_action "Verifying cleanup..."
assert_configmap_entry_absent "$SOURCE_ENV" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
    demo_fail "Cleanup failed: '$DEMO_KEY' still exists in $SOURCE_ENV"
    exit 1
}
assert_configmap_entry_absent "$TARGET_ENV" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
    demo_fail "Cleanup failed: '$DEMO_KEY' still exists in $TARGET_ENV"
    exit 1
}
demo_verify "Cleanup complete: '$DEMO_KEY' removed from $SOURCE_ENV and $TARGET_ENV"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branches left in GitLab for reference:"
demo_info "  - $DEV_FEATURE_BRANCH (dev change)"
demo_info "  - $PROD_FEATURE_BRANCH (skip promotion)"
demo_info "  - $DEV_CLEANUP_BRANCH (dev cleanup)"
demo_info "  - $PROD_CLEANUP_BRANCH (prod cleanup)"

demo_complete
