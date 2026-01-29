#!/bin/bash
# Demo: Platform Default with App Override (UC-C5)
#
# This demo showcases how an app can override platform-wide defaults
# through the CUE layering system.
#
# Use Case UC-C5:
# "Platform sets Prometheus scraping on, but postgres needs it off"
#
# What This Demonstrates:
# - Platform layer sets prometheus.io/scrape: "true" for all apps (UC-C4)
# - App layer (postgres.cue) overrides to prometheus.io/scrape: "false"
# - example-app keeps the platform default (scraping enabled)
# - postgres gets the app override (scraping disabled)
#
# Prerequisites:
# - UC-C4 has been run (platform has prometheus.io/scrape: "true")
# - Postgres ArgoCD applications exist (postgres-dev/stage/prod)
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
PLATFORM_DEFAULT_VALUE="true"
APP_OVERRIDE_VALUE="false"
OVERRIDE_APP="postgres"
UNAFFECTED_APP="example-app"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# CUE MODIFICATION FUNCTIONS
# ============================================================================

CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

add_app_annotation_override() {
    demo_action "Adding app-level annotation override to postgres.cue..."

    if ! python3 "${CUE_EDIT}" app-annotation add \
        services/apps/postgres.cue postgres \
        "$DEMO_ANNOTATION_KEY" "$APP_OVERRIDE_VALUE"; then
        demo_fail "Failed to add app annotation override"
        return 1
    fi
    demo_verify "Added $DEMO_ANNOTATION_KEY: $APP_OVERRIDE_VALUE to postgres"

    return 0
}

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C5: Platform Default with App Override"

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

demo_action "Checking ArgoCD applications for both apps..."
for env in "${ENVIRONMENTS[@]}"; do
    for app in "$OVERRIDE_APP" "$UNAFFECTED_APP"; do
        if kubectl get application "${app}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
            demo_verify "ArgoCD app ${app}-${env} exists"
        else
            demo_fail "ArgoCD app ${app}-${env} not found"
            exit 1
        fi
    done
done

demo_action "Verifying platform default annotation exists..."
# Check that example-app has prometheus scraping enabled (from UC-C4)
if assert_pod_annotation_equals "dev" "$UNAFFECTED_APP" "$DEMO_ANNOTATION_KEY" "$PLATFORM_DEFAULT_VALUE" 2>/dev/null; then
    demo_verify "Platform default ($DEMO_ANNOTATION_KEY=$PLATFORM_DEFAULT_VALUE) is active"
else
    demo_fail "Platform default not set. Run UC-C4 demo first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Verify Current State (Both Apps Have Platform Default)
# ---------------------------------------------------------------------------

demo_step 2 "Verify Current State (Both Apps Have Platform Default)"

demo_info "Before override, both apps should have platform default annotation"

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env environment..."
    assert_pod_annotation_equals "$env" "$UNAFFECTED_APP" "$DEMO_ANNOTATION_KEY" "$PLATFORM_DEFAULT_VALUE" || exit 1
    # Postgres may or may not have the annotation initially - just note the state
    local postgres_val
    postgres_val=$(kubectl get deployment "$OVERRIDE_APP" -n "$env" \
        -o jsonpath="{.spec.template.metadata.annotations.prometheus\\.io/scrape}" 2>/dev/null || echo "not-set")
    demo_info "  postgres.$DEMO_ANNOTATION_KEY = $postgres_val"
done

# ---------------------------------------------------------------------------
# Step 3: Add App-Level Override to postgres.cue
# ---------------------------------------------------------------------------

demo_step 3 "Add App-Level Override to postgres.cue"

demo_info "Adding appConfig.deployment.podAnnotations to postgres.cue"
demo_info "  This overrides platform default for postgres only"

# Make CUE change
add_app_annotation_override || exit 1

demo_action "Summary of CUE changes:"
git diff --stat services/apps/postgres.cue 2>/dev/null || echo "    (no diff available)"

# ---------------------------------------------------------------------------
# Step 4: Push CUE Change via GitLab API
# ---------------------------------------------------------------------------

demo_step 4 "Push CUE Change to GitLab"

# Generate feature branch name
FEATURE_BRANCH="uc-c5-app-override-$(date +%s)"

GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing services/apps/postgres.cue to GitLab..."
cat services/apps/postgres.cue | "$GITLAB_CLI" file update p2c/k8s-deployments services/apps/postgres.cue \
    --ref "$FEATURE_BRANCH" \
    --message "feat: disable Prometheus scraping for postgres (UC-C5)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update services/apps/postgres.cue in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Restore local changes
git checkout services/apps/postgres.cue 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 5: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 5 "MR-Gated Promotion Through Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR (for both apps)
    example_argocd_baseline=$(get_argocd_revision "${UNAFFECTED_APP}-${env}")
    postgres_argocd_baseline=$(get_argocd_revision "${OVERRIDE_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C5: Add app override for postgres to $env")

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "services/apps/postgres.cue" "podAnnotations" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/postgres/postgres.yaml" "prometheus.io/scrape.*false" || exit 1

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

        # Verify MR contains manifest changes
        demo_action "Verifying MR contains manifest changes..."
        assert_mr_contains_diff "$mr_iid" "manifests/postgres/postgres.yaml" "prometheus.io/scrape.*false" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync (both apps)
    wait_for_argocd_sync "${UNAFFECTED_APP}-${env}" "$example_argocd_baseline" || exit 1
    wait_for_argocd_sync "${OVERRIDE_APP}-${env}" "$postgres_argocd_baseline" || exit 1

    # Verify K8s state - THE KEY ASSERTION
    demo_action "Verifying annotations diverge as expected..."
    # example-app should STILL have platform default (scraping enabled)
    assert_pod_annotation_equals "$env" "$UNAFFECTED_APP" "$DEMO_ANNOTATION_KEY" "$PLATFORM_DEFAULT_VALUE" || exit 1
    # postgres should have app override (scraping disabled)
    assert_pod_annotation_equals "$env" "$OVERRIDE_APP" "$DEMO_ANNOTATION_KEY" "$APP_OVERRIDE_VALUE" || exit 1

    demo_verify "Promotion to $env complete - apps have divergent annotations"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 6: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 6 "Cross-Environment Verification"

demo_info "Verifying annotation divergence across ALL environments..."

demo_action "example-app should have platform default (scraping ENABLED)..."
assert_env_propagation "deployment" "$UNAFFECTED_APP" \
    "{.spec.template.metadata.annotations.prometheus\\.io/scrape}" \
    "$PLATFORM_DEFAULT_VALUE" \
    "${ENVIRONMENTS[@]}" || exit 1

demo_action "postgres should have app override (scraping DISABLED)..."
assert_env_propagation "deployment" "$OVERRIDE_APP" \
    "{.spec.template.metadata.annotations.prometheus\\.io/scrape}" \
    "$APP_OVERRIDE_VALUE" \
    "${ENVIRONMENTS[@]}" || exit 1

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-C5: Platform Default with App Override

  What happened:
  1. Verified platform has prometheus.io/scrape: "true" (from UC-C4)
  2. Added app-level override in postgres.cue:
     appConfig.deployment.podAnnotations: {"prometheus.io/scrape": "false"}
  3. Pushed CUE change only (no manual manifest generation)
  4. Promoted through environments using GitOps pattern
  5. For each environment:
     - Pipeline generated/validated manifests
     - Merged MR after pipeline passed
     - ArgoCD synced both apps
     - Verified annotations DIVERGE correctly

  Key Observations:
  - Platform layer sets prometheus.io/scrape: "true" for ALL apps
  - App layer (postgres.cue) overrides to "false" for postgres only
  - Override chain works: Platform -> App -> Env
  - example-app: prometheus.io/scrape = "true" (platform default)
  - postgres:    prometheus.io/scrape = "false" (app override)

  Override Hierarchy Demonstrated:
    Platform (services/core/app.cue) → prometheus.io/scrape: "true"
         ↓
    App (services/apps/postgres.cue) → prometheus.io/scrape: "false" [OVERRIDES]
         ↓
    Env (env.cue per branch) → could override further if needed

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "To delete: git branch -D $FEATURE_BRANCH"

demo_complete
