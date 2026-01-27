#!/bin/bash
# Demo: Change Default Deployment Strategy (UC-C3)
#
# This demo showcases how platform-wide deployment policies propagate
# to all apps in all environments through the CUE layering system.
#
# Use Case UC-C3:
# "As a platform team, we want zero-downtime deployments as the default"
#
# What This Demonstrates:
# - Changes to services/base/defaults.cue propagate to ALL apps in ALL environments
# - Deployment strategy is enforced at the deployment spec level
# - Pipeline generates manifests with updated strategy included
# - Promotion preserves the strategy across environments
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
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C3: Change Default Deployment Strategy"

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
for env in "${ENVIRONMENTS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

demo_action "Checking current deployment strategy..."
current_max_unavailable=$(kubectl get deployment "$DEMO_APP" -n dev \
    -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null || echo "unknown")
demo_info "Current maxUnavailable in dev: $current_max_unavailable"

# ---------------------------------------------------------------------------
# Step 2: Make CUE Change (Base Layer)
# ---------------------------------------------------------------------------

demo_step 2 "Change Deployment Strategy in Base Layer"

demo_info "Changing maxUnavailable: 1 -> 0 in services/base/defaults.cue"

# Check current state
current_value=$(grep -A4 "#DefaultDeploymentStrategy:" services/base/defaults.cue | grep "maxUnavailable" | head -1 || echo "")
demo_info "Current setting: $current_value"

# Change maxUnavailable from 1 to 0 in #DefaultDeploymentStrategy
# This is a precise replacement within the #DefaultDeploymentStrategy block only
sed -i '/#DefaultDeploymentStrategy:/,/#DefaultProductionDeploymentStrategy:/ {
    s/maxUnavailable: 1/maxUnavailable: 0/
}' services/base/defaults.cue

# Verify the change was made
new_value=$(grep -A4 "#DefaultDeploymentStrategy:" services/base/defaults.cue | grep "maxUnavailable" | head -1 || echo "")
if [[ "$new_value" == *"maxUnavailable: 0"* ]]; then
    demo_verify "Changed maxUnavailable to 0 in #DefaultDeploymentStrategy"
else
    demo_fail "Failed to change maxUnavailable in defaults.cue"
    demo_info "Current value: $new_value"
    exit 1
fi

# Verify CUE is valid
demo_action "Validating CUE configuration..."
if cue vet -c=false ./...; then
    demo_verify "CUE validation passed"
else
    demo_fail "CUE validation failed"
    exit 1
fi

demo_action "Changed section in services/base/defaults.cue:"
grep -A6 "#DefaultDeploymentStrategy:" services/base/defaults.cue | head -7 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 3: Push CUE Change via GitLab API
# ---------------------------------------------------------------------------

demo_step 3 "Push CUE Change to GitLab"

# Generate feature branch name
FEATURE_BRANCH="uc-c3-deployment-strategy-$(date +%s)"

GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing CUE change to GitLab..."
cat services/base/defaults.cue | "$GITLAB_CLI" file update p2c/k8s-deployments services/base/defaults.cue \
    --ref "$FEATURE_BRANCH" \
    --message "feat: enable zero-downtime deployments (UC-C3)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Restore local changes
git checkout services/base/defaults.cue 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 4 "MR-Gated Promotion Through Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C3: Enable zero-downtime deployments")

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "services/base/defaults.cue" "maxUnavailable" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "maxUnavailable" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    else
        # STAGE/PROD: Wait for Jenkins-created promotion MR
        wait_for_promotion_mr "$env" "$next_promotion_baseline" || exit 1
        mr_iid="$PROMOTION_MR_IID"

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to validate promotion..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains manifest changes..."
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "maxUnavailable" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state - check deployment strategy
    demo_action "Verifying deployment strategy in K8s deployment..."
    max_unavailable=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null || echo "")

    if [[ "$max_unavailable" == "0" ]]; then
        demo_verify "strategy.rollingUpdate.maxUnavailable = 0 in $env"
    else
        demo_fail "maxUnavailable not set to 0 in $env (got: '$max_unavailable')"
        exit 1
    fi

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 5: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 5 "Cross-Environment Verification"

demo_info "Verifying zero-downtime strategy in ALL environments..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."

    # Check deployment spec
    max_unavailable=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null || echo "")
    max_surge=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}' 2>/dev/null || echo "")
    strategy_type=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.strategy.type}' 2>/dev/null || echo "")

    if [[ "$max_unavailable" == "0" ]]; then
        demo_verify "$env: maxUnavailable = 0 (zero-downtime)"
    else
        demo_fail "$env: maxUnavailable not 0 (got: '$max_unavailable')"
        exit 1
    fi

    demo_info "$env: strategy=$strategy_type, maxSurge=$max_surge, maxUnavailable=$max_unavailable"

    # Verify pod is running
    pod_status=$(kubectl get pods -n "$env" -l app="$DEMO_APP" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$pod_status" == "Running" ]]; then
        demo_verify "$env: Pod is Running with new strategy"
    else
        demo_fail "$env: Pod not running (status: $pod_status)"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------

demo_step 6 "Summary"

cat << EOF

  This demo validated UC-C3: Change Default Deployment Strategy

  What happened:
  1. Changed maxUnavailable from 1 to 0 in services/base/defaults.cue
  2. Pushed CUE change only (no manual manifest generation)
  3. Promoted through environments using GitOps pattern:
     - Feature branch -> dev: Manual MR (pipeline generates manifests)
     - dev -> stage: Jenkins auto-created promotion MR
     - stage -> prod: Jenkins auto-created promotion MR
  4. For each environment:
     - Pipeline generated manifests with updated strategy
     - Merged MR after pipeline passed
     - ArgoCD synced the change
     - Verified strategy.rollingUpdate.maxUnavailable = 0

  Key Observations:
  - Deployment strategy propagates to ALL apps in ALL environments
  - Platform team can enforce zero-downtime policies centrally
  - No per-app or per-environment changes needed
  - Rolling updates now ensure at least one pod is always available

  Strategy Applied:
  - spec.strategy.type: RollingUpdate
  - spec.strategy.rollingUpdate.maxSurge: 1
  - spec.strategy.rollingUpdate.maxUnavailable: 0

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 7 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Restoring local changes if any..."
git checkout . 2>/dev/null || true

demo_info "GitLab feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "To delete: ./scripts/04-operations/gitlab-cli.sh branch delete p2c/k8s-deployments $FEATURE_BRANCH"

demo_complete
