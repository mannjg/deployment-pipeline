#!/bin/bash
# Demo: Adjust Replica Count (UC-A1)
#
# This demo showcases how environment-specific replica changes in env.cue
# remain isolated to a single environment and do NOT propagate to others.
#
# Use Case UC-A1:
# "As a platform operator, I want to scale dev to 2 replicas for load testing
# without affecting stage/prod"
#
# What This Demonstrates:
# - Changes to env.cue on an environment branch stay in that environment
# - MR-based GitOps workflow for environment-specific changes
# - Promotion system correctly preserves env-specific replica counts
# - Different environments can have different scaling configurations
#
# Flow:
# 1. Verify baseline state (all envs have replicas: 1)
# 2. Create feature branch from dev
# 3. Change replicas: 1 → 2 in dev's env.cue
# 4. Create MR: feature → dev
# 5. Wait for Jenkins CI to generate manifests
# 6. Merge MR
# 7. Wait for ArgoCD sync
# 8. Verify: dev Deployment HAS replicas: 2
# 9. Verify: stage/prod Deployments still have replicas: 1 (isolation)
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
DEMO_APP_CUE="exampleApp"  # CUE identifier
TARGET_ENV="dev"
OTHER_ENVS=("stage" "prod")

# Replica values for demo
BASELINE_REPLICAS="1"
NEW_REPLICAS="2"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-A1: Adjust Replica Count"

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

demo_action "Checking deployments exist in all environments..."
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    if kubectl get deployment "$DEMO_APP" -n "$env" &>/dev/null; then
        demo_verify "Deployment $DEMO_APP exists in $env"
    else
        demo_fail "Deployment $DEMO_APP not found in $env"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Verify Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Verify Baseline State"

demo_info "Capturing baseline replica counts..."

# Verify dev has baseline replicas (what we'll change)
demo_action "Checking $TARGET_ENV baseline..."
if ! assert_replicas "$TARGET_ENV" "$DEMO_APP" "$BASELINE_REPLICAS"; then
    demo_warn "$TARGET_ENV does not have replicas: $BASELINE_REPLICAS"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Capture stage/prod replica counts (to verify they stay unchanged)
declare -A OTHER_ENV_REPLICAS
for env in "${OTHER_ENVS[@]}"; do
    demo_action "Capturing $env replica count..."
    OTHER_ENV_REPLICAS[$env]=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    demo_verify "$env has replicas: ${OTHER_ENV_REPLICAS[$env]}"
done

demo_verify "Baseline confirmed: $TARGET_ENV has replicas: $BASELINE_REPLICAS"

# ---------------------------------------------------------------------------
# Step 3: Modify Replica Count in Dev's env.cue
# ---------------------------------------------------------------------------

demo_step 3 "Modify Replica Count in Dev's env.cue"

demo_info "Changing replicas: $BASELINE_REPLICAS → $NEW_REPLICAS in $TARGET_ENV only"

# Get current env.cue content from dev branch
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Modify replicas using sed (simple pattern replacement)
demo_action "Updating replicas in env.cue..."

# Find and replace replicas value in the exampleApp deployment block
# Pattern: replicas: 1 → replicas: 2
MODIFIED_ENV_CUE=$(echo "$DEV_ENV_CUE" | sed "s/replicas: *${BASELINE_REPLICAS}/replicas: ${NEW_REPLICAS}/")

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi

# Verify the change was actually made
if [[ "$MODIFIED_ENV_CUE" == "$DEV_ENV_CUE" ]]; then
    demo_fail "No change made - replicas pattern not found in $TARGET_ENV env.cue"
    exit 1
fi

# Verify the new value appears in modified content
if ! echo "$MODIFIED_ENV_CUE" | grep -q "replicas: *${NEW_REPLICAS}"; then
    demo_fail "Failed to update replicas - new value not found in modified content"
    exit 1
fi

demo_verify "Modified env.cue with replicas: $NEW_REPLICAS"

demo_action "Change preview:"
diff <(echo "$DEV_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true

# ---------------------------------------------------------------------------
# Step 4: Push Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-a1-replicas-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $FEATURE_BRANCH from $TARGET_ENV"

demo_action "Pushing CUE change to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: scale $TARGET_ENV to $NEW_REPLICAS replicas (UC-A1)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Create MR from feature branch to dev
demo_action "Creating MR: $FEATURE_BRANCH → $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "UC-A1: Scale $TARGET_ENV to $NEW_REPLICAS replicas")

# ---------------------------------------------------------------------------
# Step 5: Wait for Pipeline and Merge
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Pipeline and Merge"

# Wait for MR pipeline (Jenkins generates manifests)
demo_action "Waiting for Jenkins CI to generate manifests..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains expected changes..."
assert_mr_contains_diff "$mr_iid" "env.cue" "replicas" || exit 1
assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "replicas: ${NEW_REPLICAS}" || exit 1
demo_verify "MR contains CUE change and regenerated manifests"

# Capture baselines before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")
jenkins_baseline=$(get_jenkins_build_number "$TARGET_ENV")

# Merge MR
accept_mr "$mr_iid" || exit 1

# ---------------------------------------------------------------------------
# Step 6: Wait for Dev Branch Build and ArgoCD Sync
# ---------------------------------------------------------------------------

demo_step 6 "Wait for Dev Branch Build and ArgoCD Sync"

# Wait for Jenkins dev branch build to complete (regenerates manifests)
demo_action "Waiting for $TARGET_ENV branch Jenkins build..."
wait_for_jenkins_build "$TARGET_ENV" "$jenkins_baseline" || exit 1

# Wait for ArgoCD to sync dev
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_verify "$TARGET_ENV environment synced"

# ---------------------------------------------------------------------------
# Step 7: Verify Environment Isolation
# ---------------------------------------------------------------------------

demo_step 7 "Verify Environment Isolation"

demo_info "Verifying $TARGET_ENV has replicas: $NEW_REPLICAS but other environments unchanged..."

# Verify dev HAS the new replica count
demo_action "Checking $TARGET_ENV..."
assert_replicas "$TARGET_ENV" "$DEMO_APP" "$NEW_REPLICAS" || exit 1

# Verify stage/prod still have their original replica counts (unchanged)
for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env..."
    expected="${OTHER_ENV_REPLICAS[$env]}"
    if ! assert_replicas "$env" "$DEMO_APP" "$expected"; then
        demo_fail "ISOLATION VIOLATED: $env replicas changed but should not!"
        exit 1
    fi
done

demo_verify "ISOLATION CONFIRMED: Only $TARGET_ENV scaled to $NEW_REPLICAS replicas"

# ---------------------------------------------------------------------------
# Step 8: Verify Running Pods
# ---------------------------------------------------------------------------

demo_step 8 "Verify Running Pods"

demo_info "Waiting for pods to reach desired state..."

# Wait for dev to have 2 ready pods
demo_action "Waiting for $TARGET_ENV to have $NEW_REPLICAS ready pods..."
timeout=60
elapsed=0
while [[ $elapsed -lt $timeout ]]; do
    ready_pods=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "$ready_pods" == "$NEW_REPLICAS" ]]; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [[ "$ready_pods" == "$NEW_REPLICAS" ]]; then
    demo_verify "$TARGET_ENV has $NEW_REPLICAS ready pods"
else
    demo_fail "$TARGET_ENV only has $ready_pods ready pods, expected $NEW_REPLICAS"
    exit 1
fi

# Show pod status
demo_action "Pod status in $TARGET_ENV:"
kubectl get pods -n "$TARGET_ENV" -l "app=$DEMO_APP" --no-headers | head -5

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-A1: Adjust Replica Count

  What happened:
  1. Changed replicas: $BASELINE_REPLICAS → $NEW_REPLICAS in $TARGET_ENV's env.cue
  2. Pushed change via GitOps MR workflow:
     - Created feature branch from $TARGET_ENV
     - Committed CUE change to feature branch
     - Created MR: feature → $TARGET_ENV
     - Jenkins CI regenerated manifests
     - Merged MR
     - ArgoCD synced $TARGET_ENV
  3. Verified isolation:
     - $TARGET_ENV Deployment HAS replicas: $NEW_REPLICAS
     - stage Deployment unchanged (replicas: ${OTHER_ENV_REPLICAS[stage]})
     - prod Deployment unchanged (replicas: ${OTHER_ENV_REPLICAS[prod]})

  Key Observations:
  - Environment-specific scaling stays in that environment
  - Promotion does NOT override replica counts
  - All changes go through MR with pipeline validation
  - No manual kubectl scaling required

  CUE Layering Validated:
    Platform (services/core/) -> defaults
        |
    App (services/apps/) -> app-wide config
        |
    Environment (env.cue on $TARGET_ENV) -> replicas: $NEW_REPLICAS
                                            (STAYS HERE)

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 10 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
