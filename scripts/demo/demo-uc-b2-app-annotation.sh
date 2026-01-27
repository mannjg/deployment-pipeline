#!/bin/bash
# Demo: Add App-Level Annotation (UC-B2)
#
# This demo proves that app-level pod annotations propagate to ALL
# environments through the GitOps pipeline.
#
# Use Case UC-B2:
# "As a platform team, we want Prometheus to scrape example-app in all environments"
#
# What This Demonstrates:
# - Changes to services/apps/example-app.cue flow through promotion chain
# - The appConfig.deployment.podAnnotations in CUE correctly generates pod annotations
# - All environments (dev/stage/prod) receive the same app-level configuration
#
# Flow:
#   1. Add prometheus.io/scrape annotation to services/apps/example-app.cue
#   2. Create MR: feature -> dev
#   3. Promote through dev -> stage -> prod
#   4. Verify all envs have the prometheus annotation
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

DEMO_ANNOTATION_KEY="prometheus.io/scrape"
DEMO_ANNOTATION_VALUE="true"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
APP_CUE_PATH="services/apps/example-app.cue"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-B2: Add App-Level Annotation"

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

demo_action "Checking deployments exist in all environments..."
for env in "${ENVIRONMENTS[@]}"; do
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

demo_info "Confirming '$DEMO_ANNOTATION_KEY' does not exist in any environment..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_pod_annotation_absent "$env" "$DEMO_APP" "$DEMO_ANNOTATION_KEY" || {
        demo_warn "Annotation '$DEMO_ANNOTATION_KEY' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_ANNOTATION_KEY' absent from all environments"

# ---------------------------------------------------------------------------
# Step 3: Modify App CUE (add annotation)
# ---------------------------------------------------------------------------

demo_step 3 "Add Annotation to App CUE"

demo_info "Adding '$DEMO_ANNOTATION_KEY: $DEMO_ANNOTATION_VALUE' to $APP_CUE_PATH"
demo_info "This will propagate to ALL environments (dev, stage, prod)"

# Check if annotation already exists
if grep -q "\"$DEMO_ANNOTATION_KEY\"" "$APP_CUE_PATH"; then
    demo_warn "Annotation '$DEMO_ANNOTATION_KEY' already exists in $APP_CUE_PATH"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Add podAnnotations to appConfig block
# Find the appConfig block and add deployment.podAnnotations
demo_action "Adding annotation to appConfig.deployment.podAnnotations..."

# The appConfig block currently has a comment about service config
# We need to add the deployment.podAnnotations block
# Use awk to insert after the appConfig: { line
awk -v key="$DEMO_ANNOTATION_KEY" -v val="$DEMO_ANNOTATION_VALUE" '
/appConfig: \{/ {
    print
    print "\t\tdeployment: {"
    print "\t\t\tpodAnnotations: {"
    print "\t\t\t\t\"" key "\": \"" val "\""
    print "\t\t\t}"
    print "\t\t}"
    next
}
{print}
' "$APP_CUE_PATH" > "${APP_CUE_PATH}.tmp" && mv "${APP_CUE_PATH}.tmp" "$APP_CUE_PATH"

demo_verify "Added annotation to $APP_CUE_PATH"

# Verify the change was actually made
if ! grep -q "\"$DEMO_ANNOTATION_KEY\"" "$APP_CUE_PATH"; then
    demo_fail "Failed to add annotation - appConfig block may be malformed"
    git checkout "$APP_CUE_PATH" 2>/dev/null || true
    exit 1
fi

# Verify CUE is valid (use -c=false since main branch env.cue is incomplete by design)
demo_action "Validating CUE configuration..."
if cue vet -c=false ./...; then
    demo_verify "CUE validation passed"
else
    demo_fail "CUE validation failed"
    git checkout "$APP_CUE_PATH" 2>/dev/null || true
    exit 1
fi

demo_action "Changed section in $APP_CUE_PATH:"
grep -A5 "$DEMO_ANNOTATION_KEY" "$APP_CUE_PATH" | head -10 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 4: Push Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-b2-app-annotation-$(date +%s)"

# Use GitLab CLI to create branch and push file
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    git checkout "$APP_CUE_PATH" 2>/dev/null || true
    exit 1
}

demo_action "Pushing CUE change to GitLab..."
cat "$APP_CUE_PATH" | "$GITLAB_CLI" file update p2c/k8s-deployments "$APP_CUE_PATH" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add $DEMO_ANNOTATION_KEY annotation to example-app (UC-B2)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    git checkout "$APP_CUE_PATH" 2>/dev/null || true
    exit 1
}
demo_verify "Feature branch pushed"

# Restore local changes (don't leave local repo dirty)
git checkout "$APP_CUE_PATH" 2>/dev/null || true

# Create MR from feature branch to dev
demo_action "Creating MR: $FEATURE_BRANCH -> dev..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "dev" "UC-B2: Add $DEMO_ANNOTATION_KEY annotation")

# ---------------------------------------------------------------------------
# Step 5: Promote Through All Environments
# ---------------------------------------------------------------------------

demo_step 5 "Promote Through All Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Wait for pipeline on existing MR
        demo_action "Waiting for Jenkins CI to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains app CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "$APP_CUE_PATH" "$DEMO_ANNOTATION_KEY" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_ANNOTATION_KEY" || exit 1
        demo_verify "MR contains app change and regenerated manifests"

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
    demo_action "Verifying annotation in deployment..."
    assert_pod_annotation_equals "$env" "$DEMO_APP" "$DEMO_ANNOTATION_KEY" "$DEMO_ANNOTATION_VALUE" || exit 1

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 6: Final Verification
# ---------------------------------------------------------------------------

demo_step 6 "Final Verification"

demo_info "Verifying annotation propagated to ALL environments..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_pod_annotation_equals "$env" "$DEMO_APP" "$DEMO_ANNOTATION_KEY" "$DEMO_ANNOTATION_VALUE" || exit 1
done

demo_verify "VERIFIED: '$DEMO_ANNOTATION_KEY' present in all environments!"
demo_info "  - dev:   $DEMO_ANNOTATION_KEY = $DEMO_ANNOTATION_VALUE"
demo_info "  - stage: $DEMO_ANNOTATION_KEY = $DEMO_ANNOTATION_VALUE"
demo_info "  - prod:  $DEMO_ANNOTATION_KEY = $DEMO_ANNOTATION_VALUE"

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-B2: Add App-Level Annotation

  What happened:
  1. Added '$DEMO_ANNOTATION_KEY: $DEMO_ANNOTATION_VALUE' to services/apps/example-app.cue
  2. Promoted through all environments using GitOps pattern:
     - Feature branch -> dev: Manual MR (pipeline generates manifests)
     - dev -> stage: Jenkins auto-created promotion MR
     - stage -> prod: Jenkins auto-created promotion MR
  3. Verified all environments have the new annotation

  Key Observations:
  - App-level pod annotations propagate to ALL environments
  - All changes go through MR with pipeline validation (GitOps)
  - Single change automatically flows through the entire promotion chain
  - Prometheus can now scrape this app in all environments

  CUE Hierarchy Validated:
    App (services/apps/example-app.cue) -> appConfig.deployment.podAnnotations
        |
    All Environments (dev, stage, prod) -> same annotation on pods

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
