#!/usr/bin/env bash
# Demo: Add Standard Pod Annotation to All Deployments (UC-C4)
#
# This demo showcases how platform-wide pod annotations propagate to all apps
# in all environments through the CUE layering system.
#
# Use Case UC-C4:
# "As a platform team, we want to set a default Prometheus scrape interval for all pods"
#
# What This Demonstrates:
# - Changes to templates/core/ and templates/resources/ propagate to ALL apps in ALL environments
# - The MR shows both CUE change AND generated manifest changes
# - Pipeline generates manifests (not the human)
# - Apps/environments can override annotations if needed
#
# Note: The platform baseline already includes prometheus.io/scrape, /port, /path
# in defaultPodAnnotations. This demo adds scrape-interval to demonstrate
# how platform teams can add new annotations that propagate to all apps.
#
# CUE Changes Made:
# 1. templates/core/app.cue - Add prometheus.io/scrape-interval to defaultPodAnnotations
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

# Note: prometheus.io/scrape, /port, /path are already in platform baseline
# This demo adds scrape-interval to demonstrate the mechanism
DEMO_ANNOTATION_KEY="prometheus.io/scrape-interval"
DEMO_ANNOTATION_VALUE="30s"
DEMO_APP="example-app"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# CUE MODIFICATION FUNCTIONS
# ============================================================================

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

add_prometheus_annotations() {
    demo_action "Adding Prometheus scrape-interval annotation using cue-edit.py..."

    # Add prometheus.io/scrape-interval annotation
    if ! python3 "${CUE_EDIT}" platform-annotation add "$DEMO_ANNOTATION_KEY" "$DEMO_ANNOTATION_VALUE"; then
        demo_fail "Failed to add $DEMO_ANNOTATION_KEY annotation"
        return 1
    fi
    demo_verify "Added $DEMO_ANNOTATION_KEY annotation"

    return 0
}

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C4: Add Standard Pod Annotation to All Deployments"

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
# Step 2: Verify Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Verify Baseline State"

demo_info "Confirming '$DEMO_ANNOTATION_KEY' does not exist in any environment..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_pod_annotation_absent "$(get_namespace "$env")" "$DEMO_APP" "$DEMO_ANNOTATION_KEY" || {
        demo_warn "Annotation '$DEMO_ANNOTATION_KEY' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_ANNOTATION_KEY' absent from all environments"

# ---------------------------------------------------------------------------
# Step 3: Make CUE Changes (Platform Layer)
# ---------------------------------------------------------------------------

demo_step 3 "Add Default Pod Annotations to Platform Layer"

demo_info "Adding annotation to defaultPodAnnotations in templates/core/app.cue"
demo_info "  (deployment.cue infrastructure already supports defaultPodAnnotations)"

# Make CUE changes using cue-edit.py (includes CUE validation)
add_prometheus_annotations || exit 1

demo_action "Summary of CUE changes:"
echo "  templates/core/app.cue:"
git diff --stat templates/core/app.cue 2>/dev/null || echo "    (no diff available)"
echo "  templates/resources/deployment.cue:"
git diff --stat templates/resources/deployment.cue 2>/dev/null || echo "    (no diff available)"

# ---------------------------------------------------------------------------
# Step 4: Push CUE Changes via GitLab API
# ---------------------------------------------------------------------------

demo_step 4 "Push CUE Changes to GitLab"

# Generate feature branch name
FEATURE_BRANCH="uc-c4-prometheus-annotations-$(date +%s)"

# Use GitLab API to create branch and update files
# This avoids subtree push which creates divergent commit history
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing templates/core/app.cue to GitLab..."
cat templates/core/app.cue | "$GITLAB_CLI" file update p2c/k8s-deployments templates/core/app.cue \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add default Prometheus annotations to all deployments (UC-C4)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update templates/core/app.cue in GitLab"
    exit 1
}

# Check if deployment.cue was modified
if ! git diff --quiet templates/resources/deployment.cue 2>/dev/null; then
    demo_action "Pushing templates/resources/deployment.cue to GitLab..."
    cat templates/resources/deployment.cue | "$GITLAB_CLI" file update p2c/k8s-deployments templates/resources/deployment.cue \
        --ref "$FEATURE_BRANCH" \
        --message "feat: add default Prometheus annotations support (UC-C4)" \
        --stdin >/dev/null || {
        demo_fail "Failed to update templates/resources/deployment.cue in GitLab"
        exit 1
    }
fi
demo_verify "Feature branch pushed"

# Restore local changes (don't leave local repo dirty)
git checkout templates/core/app.cue templates/resources/deployment.cue 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 5: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 5 "MR-Gated Promotion Through Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C4: Add Prometheus annotations to $env")

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        # Note: deployment.cue infrastructure is already in place, only app.cue changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "templates/core/app.cue" "$DEMO_ANNOTATION_KEY" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_ANNOTATION_KEY" || exit 1

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
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_ANNOTATION_KEY" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state
    demo_action "Verifying annotation in K8s deployment..."
    assert_pod_annotation_equals "$(get_namespace "$env")" "$DEMO_APP" "$DEMO_ANNOTATION_KEY" "$DEMO_ANNOTATION_VALUE" || exit 1

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 6: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 6 "Cross-Environment Verification"

demo_info "Verifying Prometheus scrape-interval propagated to ALL environments..."

assert_env_propagation "deployment" "$DEMO_APP" \
    "{.spec.template.metadata.annotations.prometheus\\.io/scrape-interval}" \
    "$DEMO_ANNOTATION_VALUE" \
    "$(get_namespace dev)" "$(get_namespace stage)" "$(get_namespace prod)" || exit 1

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-C4: Add Standard Pod Annotation to All Deployments

  What happened:
  1. Verified baseline (scrape-interval annotation absent from all envs)
  2. Added $DEMO_ANNOTATION_KEY to defaultPodAnnotations in templates/core/app.cue
  3. Pushed CUE changes only (no manual manifest generation)
  4. Promoted through environments using GitOps pattern:
     - Feature branch -> dev: Manual MR (pipeline generates manifests)
     - dev -> stage: Jenkins auto-created promotion MR
     - stage -> prod: Jenkins auto-created promotion MR
  5. For each environment:
     - Pipeline generated/validated manifests
     - Merged MR after pipeline passed
     - ArgoCD synced the change
     - Verified annotation appears in K8s pods

  Key Observations:
  - Human only changed CUE (the intent)
  - Pipeline generated YAML (the implementation)
  - Platform annotation propagated to ALL apps in ALL environments
  - Apps/environments can override this value if needed

  Platform Baseline (already in templates/core/app.cue):
  - prometheus.io/scrape: "true"
  - prometheus.io/port: "8080"
  - prometheus.io/path: "/metrics"

  Annotation Added by This Demo:
  - $DEMO_ANNOTATION_KEY: "$DEMO_ANNOTATION_VALUE"

EOF

# ---------------------------------------------------------------------------
# Step 8: Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "To delete: git branch -D $FEATURE_BRANCH"

demo_complete
