#!/bin/bash
# Demo: Add Default Label to All Deployments (UC-C1)
#
# This demo showcases how platform-wide changes propagate to all apps
# in all environments through the CUE layering system.
#
# Use Case UC-C1:
# "As a platform team, we need all deployments to have a cost-center label
# for chargeback reporting"
#
# What This Demonstrates:
# - Changes to services/core/ propagate to ALL apps in ALL environments
# - The MR shows both CUE change AND generated manifest changes
# - Pipeline generates manifests (not the human)
# - Promotion uses Jenkins-created branches that preserve env-specific config
#
# Promotion Pattern:
# - Feature → dev: Manual MR (we create it)
# - dev → stage: Wait for Jenkins auto-created promotion MR
# - stage → prod: Wait for Jenkins auto-created promotion MR
#
# IMPORTANT: We do NOT create direct env→env MRs (e.g., dev → stage).
# That would merge env.cue incorrectly, causing stage to deploy with dev config.
# Jenkins uses promote-app-config.sh to preserve env-specific config.
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

DEMO_LABEL_KEY="cost-center"
DEMO_LABEL_VALUE="platform-shared"
DEMO_APP="example-app"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C1: Add Default Label to All Deployments"

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

# ---------------------------------------------------------------------------
# Step 2: Make CUE Change (Platform Layer)
# ---------------------------------------------------------------------------

demo_step 2 "Add Default Label to Platform Layer"

demo_info "Adding '$DEMO_LABEL_KEY: $DEMO_LABEL_VALUE' to services/core/app.cue"

# Check if label already exists
if grep -q "$DEMO_LABEL_KEY" services/core/app.cue; then
    demo_warn "Label '$DEMO_LABEL_KEY' already exists in app.cue"
    demo_info "Updating value to '$DEMO_LABEL_VALUE'"
fi

# Add/update the label in defaultLabels
# Using sed to add after the existing labels
# Note: Use CUE default syntax (*"value" | string) to allow environment overrides
if ! grep -q "$DEMO_LABEL_KEY" services/core/app.cue; then
    # Add new label after "deployment: appName" with default syntax for overridability
    sed -i "/deployment: appName/a\\		\"$DEMO_LABEL_KEY\": *\"$DEMO_LABEL_VALUE\" | string" services/core/app.cue
    demo_verify "Added label to services/core/app.cue"
else
    # Update existing label (preserve default syntax if present)
    sed -i "s/\"$DEMO_LABEL_KEY\": \*\?\"[^\"]*\"\( | string\)\?/\"$DEMO_LABEL_KEY\": *\"$DEMO_LABEL_VALUE\" | string/" services/core/app.cue
    demo_verify "Updated label in services/core/app.cue"
fi

# Verify the label was actually added/updated (check for either concrete or default syntax)
if ! grep -qE "\"$DEMO_LABEL_KEY\": \*?\"$DEMO_LABEL_VALUE\"" services/core/app.cue; then
    demo_fail "Failed to add/update $DEMO_LABEL_KEY in app.cue"
    exit 1
fi

# Verify CUE is valid (use -c=false since main branch env.cue is incomplete by design)
demo_action "Validating CUE configuration..."
if cue vet -c=false ./...; then
    demo_verify "CUE validation passed"
else
    demo_fail "CUE validation failed"
    exit 1
fi

demo_action "Changed section in services/core/app.cue:"
grep -A5 "defaultLabels" services/core/app.cue | head -10 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 3: Push CUE Change via GitLab API
# ---------------------------------------------------------------------------

demo_step 3 "Push CUE Change to GitLab"

# Generate feature branch name
FEATURE_BRANCH="uc-c1-add-${DEMO_LABEL_KEY}-$(date +%s)"

# Use GitLab API to create branch and update file
# This avoids subtree push which creates divergent commit history
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing CUE change to GitLab..."
cat services/core/app.cue | "$GITLAB_CLI" file update p2c/k8s-deployments services/core/app.cue \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add $DEMO_LABEL_KEY label to all deployments (UC-C1)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Restore local changes (don't leave local repo dirty)
git checkout services/core/app.cue 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 4 "MR-Gated Promotion Through Environments"

# This uses proper GitOps promotion pattern:
# - feature → dev: Manual MR creation (initial deployment)
# - dev → stage: Wait for Jenkins-created promotion MR
# - stage → prod: Wait for Jenkins-created promotion MR
#
# IMPORTANT: We do NOT create direct env→env MRs (e.g., dev → stage).
# That would merge env.cue incorrectly, causing stage to deploy to dev namespace.
# Instead, Jenkins creates promotion branches that use promote-app-config.sh
# to preserve env-specific config (namespace, replicas, resources, debug).

# Track baseline time for promotion MR detection (avoids race conditions)
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch (this is correct)
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C1: Add $DEMO_LABEL_KEY label to $env")

        # Wait for MR pipeline (generates manifests)
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "services/core/app.cue" "$DEMO_LABEL_KEY" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_LABEL_KEY" || exit 1

        # Capture baseline time BEFORE merge (for next env's promotion MR detection)
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    else
        # STAGE/PROD: Wait for Jenkins-created promotion MR
        # After merging to the previous env, Jenkins automatically:
        # 1. Creates a promote-{env}-{timestamp} branch
        # 2. Runs promote-app-config.sh to preserve env-specific config
        # 3. Regenerates manifests for the target environment
        # 4. Opens an MR
        wait_for_promotion_mr "$env" "$next_promotion_baseline" || exit 1
        mr_iid="$PROMOTION_MR_IID"

        # Wait for MR pipeline (validates the promotion)
        demo_action "Waiting for pipeline to validate promotion..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains manifest changes with correct namespace..."
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_LABEL_KEY" || exit 1

        # Capture baseline time BEFORE merge (for next env's promotion MR detection)
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state
    demo_action "Verifying label in K8s deployment..."
    if [[ "$env" == "prod" ]]; then
        # Prod may have environment override - just verify label exists
        prod_label=$(kubectl get deployment "$DEMO_APP" -n prod -o jsonpath="{.spec.template.metadata.labels.$DEMO_LABEL_KEY}" 2>/dev/null || echo "")
        if [[ -n "$prod_label" ]]; then
            if [[ "$prod_label" == "$DEMO_LABEL_VALUE" ]]; then
                demo_verify "Field {.spec.template.metadata.labels.$DEMO_LABEL_KEY} = '$prod_label'"
            else
                demo_info "prod has environment override: $DEMO_LABEL_KEY='$prod_label' (platform default: '$DEMO_LABEL_VALUE')"
            fi
        else
            demo_fail "Label $DEMO_LABEL_KEY not found in prod deployment"
            exit 1
        fi
    else
        assert_pod_label_equals "$env" "$DEMO_APP" "$DEMO_LABEL_KEY" "$DEMO_LABEL_VALUE" || exit 1
    fi

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 5: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 5 "Cross-Environment Verification"

demo_info "Verifying label present in ALL environments..."

# dev and stage should have the platform default
for env in dev stage; do
    demo_action "Checking $env..."
    assert_pod_label_equals "$env" "$DEMO_APP" "$DEMO_LABEL_KEY" "$DEMO_LABEL_VALUE" || exit 1
done

# prod should have its override value (if it exists)
demo_action "Checking prod (may have environment override)..."
prod_value=$(kubectl get deployment "$DEMO_APP" -n prod -o jsonpath="{.spec.template.metadata.labels.$DEMO_LABEL_KEY}" 2>/dev/null || echo "")
if [[ -n "$prod_value" ]]; then
    if [[ "$prod_value" == "$DEMO_LABEL_VALUE" ]]; then
        demo_verify "prod has platform default: $DEMO_LABEL_KEY=$prod_value"
    else
        demo_info "prod has environment override: $DEMO_LABEL_KEY=$prod_value (platform default would be '$DEMO_LABEL_VALUE')"
    fi
else
    demo_fail "prod is missing $DEMO_LABEL_KEY label"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------

demo_step 6 "Summary"

cat << EOF

  This demo validated UC-C1: Add Default Label to All Deployments

  What happened:
  1. Added '$DEMO_LABEL_KEY: $DEMO_LABEL_VALUE' as a CUE default to services/core/app.cue
  2. Pushed CUE change only (no manual manifest generation)
  3. Promoted through environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  4. For each environment:
     - Pipeline generated/validated manifests with correct namespace
     - Merged MR after pipeline passed
     - ArgoCD synced the change
     - Verified label appears in K8s deployment

  Key Observations:
  - Human only changed CUE (the intent)
  - Pipeline generated YAML (the implementation)
  - Promotion MRs preserve env-specific config (namespace, replicas, resources)
  - Platform default propagates unless env has explicit override
  - Prod's existing '$DEMO_LABEL_KEY: production-critical' override takes precedence

  Why This Works:
  - CUE default syntax (*"value" | string) allows environment overrides
  - Jenkins promotion uses promote-app-config.sh for semantic merge
  - App-level changes (labels) propagate
  - Env-specific overrides (like prod's cost-center) are preserved

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
