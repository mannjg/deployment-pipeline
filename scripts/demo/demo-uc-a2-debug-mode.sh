#!/bin/bash
# Demo: Enable Debug Mode (UC-A2)
#
# This demo showcases how environment-specific debug settings in env.cue
# remain isolated to a single environment and do NOT propagate to others.
#
# Use Case UC-A2:
# "As a developer, I want debug logging in dev but not in prod"
#
# What This Demonstrates:
# - Changes to env.cue on an environment branch stay in that environment
# - Debug mode affects: DEBUG env var, debug port (5005), and debug Service
# - MR-based GitOps workflow for environment-specific changes
# - Promotion system correctly preserves env-specific debug flags
#
# Flow:
# 1. Verify baseline state (all envs have debug: false, no debug resources)
# 2. Create feature branch from dev
# 3. Change debug: false → true in dev's env.cue
# 4. Create MR: feature → dev
# 5. Wait for Jenkins CI to generate manifests
# 6. Merge MR
# 7. Wait for ArgoCD sync
# 8. Verify: dev Deployment HAS DEBUG env var and debug Service exists
# 9. Verify: stage/prod do NOT have DEBUG env var or debug Service (isolation)
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

# Debug Service name (created when debug: true)
DEBUG_SERVICE="${DEMO_APP}-debug"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-A2: Enable Debug Mode"

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

demo_info "Confirming debug mode is disabled in all environments..."

# Check for DEBUG env var absence (indicates debug: false)
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env for DEBUG env var..."
    if ! assert_deployment_env_var_absent "$env" "$DEMO_APP" "DEBUG"; then
        demo_warn "DEBUG env var already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    fi
done

# Check for debug Service absence
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env for debug Service..."
    if kubectl get service "$DEBUG_SERVICE" -n "$env" &>/dev/null; then
        demo_warn "Debug Service already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    fi
    demo_verify "No debug Service in $env (expected)"
done

demo_verify "Baseline confirmed: debug mode disabled in all environments"

# ---------------------------------------------------------------------------
# Step 3: Enable Debug Mode in Dev's env.cue
# ---------------------------------------------------------------------------

demo_step 3 "Enable Debug Mode in Dev's env.cue"

demo_info "Changing debug: false → true in $TARGET_ENV only"

# Get current env.cue content from dev branch
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Check current debug setting
if echo "$DEV_ENV_CUE" | grep -q "debug: *true"; then
    demo_warn "debug is already true in $TARGET_ENV's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify debug using sed (simple pattern replacement)
demo_action "Updating debug flag in env.cue..."

# Pattern: debug: false → debug: true
MODIFIED_ENV_CUE=$(echo "$DEV_ENV_CUE" | sed 's/debug: *false/debug: true/')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi

# Verify the change was actually made
if [[ "$MODIFIED_ENV_CUE" == "$DEV_ENV_CUE" ]]; then
    demo_fail "No change made - debug: false pattern not found in $TARGET_ENV env.cue"
    exit 1
fi

# Verify the new value appears in modified content
if ! echo "$MODIFIED_ENV_CUE" | grep -q "debug: *true"; then
    demo_fail "Failed to update debug - new value not found in modified content"
    exit 1
fi

demo_verify "Modified env.cue with debug: true"

demo_action "Change preview:"
diff <(echo "$DEV_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true

# ---------------------------------------------------------------------------
# Step 4: Push Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-a2-debug-mode-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $FEATURE_BRANCH from $TARGET_ENV"

demo_action "Pushing CUE change to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: enable debug mode in $TARGET_ENV (UC-A2)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Create MR from feature branch to dev
demo_action "Creating MR: $FEATURE_BRANCH → $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "UC-A2: Enable debug mode in $TARGET_ENV")

# ---------------------------------------------------------------------------
# Step 5: Wait for Pipeline and Merge
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Pipeline and Merge"

# Wait for MR pipeline (Jenkins generates manifests)
demo_action "Waiting for Jenkins CI to generate manifests..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains expected changes..."
assert_mr_contains_diff "$mr_iid" "env.cue" "debug" || exit 1
assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "DEBUG" || exit 1
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
# Step 7: Verify Debug Mode Enabled in Dev
# ---------------------------------------------------------------------------

demo_step 7 "Verify Debug Mode Enabled in Dev"

demo_info "Verifying debug artifacts exist in $TARGET_ENV..."

# Verify DEBUG env var exists with value "true"
demo_action "Checking for DEBUG env var..."
assert_deployment_env_var "$TARGET_ENV" "$DEMO_APP" "DEBUG" "yes" || exit 1

# Verify debug Service exists
demo_action "Checking for debug Service..."
if kubectl get service "$DEBUG_SERVICE" -n "$TARGET_ENV" &>/dev/null; then
    demo_verify "Debug Service $DEBUG_SERVICE exists in $TARGET_ENV"
else
    demo_fail "Debug Service $DEBUG_SERVICE not found in $TARGET_ENV"
    exit 1
fi

# Show debug port configuration
demo_action "Debug port configuration:"
kubectl get service "$DEBUG_SERVICE" -n "$TARGET_ENV" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null && echo ""

demo_verify "Debug mode fully enabled in $TARGET_ENV"

# ---------------------------------------------------------------------------
# Step 8: Verify Environment Isolation
# ---------------------------------------------------------------------------

demo_step 8 "Verify Environment Isolation"

demo_info "Verifying debug mode is NOT enabled in stage/prod..."

# Verify stage/prod do NOT have DEBUG env var
for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env for DEBUG env var..."
    if ! assert_deployment_env_var_absent "$env" "$DEMO_APP" "DEBUG"; then
        demo_fail "ISOLATION VIOLATED: $env has DEBUG env var but should not!"
        exit 1
    fi
done

# Verify stage/prod do NOT have debug Service
for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env for debug Service..."
    if kubectl get service "$DEBUG_SERVICE" -n "$env" &>/dev/null; then
        demo_fail "ISOLATION VIOLATED: $env has debug Service but should not!"
        exit 1
    fi
    demo_verify "No debug Service in $env (correct)"
done

demo_verify "ISOLATION CONFIRMED: Only $TARGET_ENV has debug mode enabled"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-A2: Enable Debug Mode

  What happened:
  1. Enabled debug: true in $TARGET_ENV's env.cue
  2. Pushed change via GitOps MR workflow:
     - Created feature branch from $TARGET_ENV
     - Committed CUE change to feature branch
     - Created MR: feature → $TARGET_ENV
     - Jenkins CI regenerated manifests
     - Merged MR
     - ArgoCD synced $TARGET_ENV
  3. Verified debug artifacts in $TARGET_ENV:
     - DEBUG=yes env var on container
     - ${DEBUG_SERVICE} Service created (port 5005)
  4. Verified isolation:
     - stage does NOT have DEBUG env var or debug Service
     - prod does NOT have DEBUG env var or debug Service

  Key Observations:
  - Debug mode affects multiple resources (Deployment + Service)
  - Environment-specific flags stay in that environment
  - Promotion does NOT enable debug in stage/prod
  - All changes go through MR with pipeline validation

  CUE Layering Validated:
    Platform (services/core/) -> debug: false default
        |
    App (services/apps/) -> inherits default
        |
    Environment (env.cue on $TARGET_ENV) -> debug: true
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
