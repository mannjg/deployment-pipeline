#!/usr/bin/env bash
# Demo: App Probe with Environment Override (UC-B5)
#
# This demo showcases the CUE override hierarchy where:
# - App-level probe settings propagate to ALL environments
# - Environment-level settings can override probe timeouts
#
# Use Case UC-B5:
# "App defines readiness probe with 10s timeout, but prod needs 30s due to cold-start"
#
# What This Demonstrates:
# - App-level probe configuration propagates to all environments
# - Environment-level can override specific probe fields
# - Lower layer (env) takes precedence over higher layer (app)
# - Full MR-based GitOps workflow for both phases
#
# Flow:
# Phase 1: Add App-Level Default (propagates to all envs)
#   1. Add readinessProbe.timeoutSeconds=10 to services/apps/example-app.cue
#   2. Create MR: feature → dev
#   3. Promote through dev → stage → prod
#   4. Verify all envs have timeoutSeconds=10
#
# Phase 2: Add Prod Override
#   5. Add readinessProbe.timeoutSeconds=30 to prod's env.cue
#   6. Create MR: feature → prod
#   7. Verify dev/stage have 10, prod has 30
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

APP_DEFAULT_TIMEOUT="10"
PROD_OVERRIDE_TIMEOUT="30"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

# GitLab CLI path (used in both Phase 1 and Phase 2)
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_init "UC-B5: App Probe with Environment Override"

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
    if kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" &>/dev/null; then
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

demo_info "Checking current readinessProbe timeoutSeconds across environments..."
demo_info "(App-level default is ${APP_DEFAULT_TIMEOUT}s, prod will override to ${PROD_OVERRIDE_TIMEOUT}s)"

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    current=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.timeoutSeconds}' 2>/dev/null || echo "unset")
    demo_info "$env: timeoutSeconds = $current"
done

demo_verify "Baseline state captured"

# ============================================================================
# PHASE 1: Verify App-Level Default (already in baseline)
# ============================================================================

demo_step 3 "PHASE 1: Verify App-Level Default"

# Initialize FEATURE_BRANCH - may not be created if baseline already has app default
FEATURE_BRANCH=""

# Edit LOCAL file directly (same pattern as UC-B4)
APP_CUE_PATH="services/apps/example-app.cue"

# Check if readinessProbe already exists in app config
if grep -q "readinessProbe" "$APP_CUE_PATH"; then
    demo_info "App-level readinessProbe already defined in $APP_CUE_PATH"
    demo_info "This is the expected baseline state per UC-B5:"
    demo_info "  - App defines default probe timeout ($APP_DEFAULT_TIMEOUT s)"
    demo_info "  - Environment (prod) will override to $PROD_OVERRIDE_TIMEOUT s"

    # Verify the value matches expected baseline
    if grep -q "timeoutSeconds.*$APP_DEFAULT_TIMEOUT" "$APP_CUE_PATH"; then
        demo_verify "App-level default timeoutSeconds=$APP_DEFAULT_TIMEOUT confirmed"
        SKIP_PHASE1=true
    else
        demo_warn "App-level timeoutSeconds exists but doesn't match expected value"
        demo_info "Expected: $APP_DEFAULT_TIMEOUT, run reset-demo-state.sh to clean up"
        exit 1
    fi
else
    SKIP_PHASE1=false
fi

if [[ "${SKIP_PHASE1:-false}" == "true" ]]; then
    demo_info "Skipping Phase 1 MR workflow - baseline already has app-level default"
    demo_info "Proceeding directly to Phase 2 (prod override)..."

    # Show the current app config
    demo_action "Current app-level readinessProbe configuration:"
    grep -A5 "readinessProbe" "$APP_CUE_PATH" | sed 's/^/    /'
else
    demo_info "Adding readinessProbe.timeoutSeconds=$APP_DEFAULT_TIMEOUT to services/apps/example-app.cue"
    demo_info "This will propagate to ALL environments (dev, stage, prod)"

    # Add readinessProbe to appConfig block
    # The appConfig block is currently empty, so we add after "appConfig: {"
    demo_action "Adding readinessProbe to app CUE..."

    # Use awk for reliable multi-line insertion after "appConfig: {"
    # Use concrete value (not CUE default syntax) - concrete values override base defaults
    # env.cue can still override this with its own concrete value
    awk -v timeout="$APP_DEFAULT_TIMEOUT" '
    /appConfig: \{/ {
        print
        print "\t\tdeployment: {"
        print "\t\t\treadinessProbe: {"
        print "\t\t\t\ttimeoutSeconds: " timeout
        print "\t\t\t}"
        print "\t\t}"
        next
    }
    {print}
    ' "$APP_CUE_PATH" > "${APP_CUE_PATH}.tmp" && mv "${APP_CUE_PATH}.tmp" "$APP_CUE_PATH"

    demo_verify "Added readinessProbe to $APP_CUE_PATH"

    # Verify the change was actually made
    if ! grep -q "readinessProbe" "$APP_CUE_PATH"; then
        demo_fail "Failed to add readinessProbe - appConfig block may be missing"
        git checkout "$APP_CUE_PATH" 2>/dev/null || true
        exit 1
    fi

    # Verify CUE is valid
    demo_action "Validating CUE configuration..."
    if cue vet -c=false ./...; then
        demo_verify "CUE validation passed"
    else
        demo_fail "CUE validation failed"
        git checkout "$APP_CUE_PATH" 2>/dev/null || true
        exit 1
    fi

    demo_action "Changed section in $APP_CUE_PATH:"
    grep -A10 "appConfig" "$APP_CUE_PATH" | head -15 | sed 's/^/    /'

    # ---------------------------------------------------------------------------
    # Step 4: Push App-Level Change via GitLab MR
    # ---------------------------------------------------------------------------

    demo_step 4 "Push App-Level Change via GitLab MR"

    # Generate feature branch name
    FEATURE_BRANCH="uc-b5-probe-timeout-$(date +%s)"

    demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
    "$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
        demo_fail "Failed to create branch in GitLab"
        git checkout "$APP_CUE_PATH" 2>/dev/null || true
        exit 1
    }

    demo_action "Pushing CUE change to GitLab..."
    cat "$APP_CUE_PATH" | "$GITLAB_CLI" file update p2c/k8s-deployments "$APP_CUE_PATH" \
        --ref "$FEATURE_BRANCH" \
        --message "feat: add readinessProbe timeout to app config (UC-B5)" \
        --stdin >/dev/null || {
        demo_fail "Failed to update file in GitLab"
        git checkout "$APP_CUE_PATH" 2>/dev/null || true
        exit 1
    }
    demo_verify "Feature branch pushed"

    # Restore local changes (don't leave local repo dirty)
    git checkout "$APP_CUE_PATH" 2>/dev/null || true

    # Create MR from feature branch to dev
    demo_action "Creating MR: $FEATURE_BRANCH → dev..."
    mr_iid=$(create_mr "$FEATURE_BRANCH" "dev" "UC-B5: Add readinessProbe timeout to app config")

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
            assert_mr_contains_diff "$mr_iid" "$APP_CUE_PATH" "readinessProbe" || exit 1
            assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "timeoutSeconds" || exit 1
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
            assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "timeoutSeconds" || exit 1

            # Capture baseline time BEFORE merge
            next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            # Merge MR
            accept_mr "$mr_iid" || exit 1
        fi

        # Wait for ArgoCD sync
        wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

        # Verify K8s state
        demo_action "Verifying readinessProbe timeout in K8s..."
        assert_readiness_probe_timeout "$(get_namespace "$env")" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1

        demo_verify "Promotion to $env complete"
        echo ""
    done
fi  # End of SKIP_PHASE1 else block

# ---------------------------------------------------------------------------
# Step 6: Checkpoint - All Environments Have App Default
# ---------------------------------------------------------------------------

demo_step 6 "Checkpoint - All Environments Have App Default"

demo_info "Verifying app default exists in ALL environments..."
demo_info "(Baseline already deployed, or just promoted via Phase 1)"

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_readiness_probe_timeout "$(get_namespace "$env")" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1
done

demo_verify "CHECKPOINT: All environments have readinessProbe.timeoutSeconds=$APP_DEFAULT_TIMEOUT"
demo_info "This confirms the app-level probe default is active everywhere."
echo ""

# ============================================================================
# PHASE 2: Add Prod Override (stays in prod only)
# ============================================================================

demo_step 7 "PHASE 2: Add Prod Override"

demo_info "Now adding override to prod: readinessProbe.timeoutSeconds=$PROD_OVERRIDE_TIMEOUT"
demo_info "This will ONLY affect prod (env layer wins over app layer)"

# Get current env.cue content from prod branch
demo_action "Fetching prod's env.cue from GitLab..."
PROD_ENV_CUE=$(get_file_from_branch "prod" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from prod branch"
    exit 1
fi
demo_verify "Retrieved prod's env.cue"

# Check if override already exists
if echo "$PROD_ENV_CUE" | grep -q "timeoutSeconds: $PROD_OVERRIDE_TIMEOUT"; then
    demo_warn "timeoutSeconds=$PROD_OVERRIDE_TIMEOUT already exists in prod's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify the content - add timeoutSeconds to readinessProbe in prod exampleApp
# The existing structure has readinessProbe with httpGet, initialDelaySeconds, periodSeconds
# We need to add timeoutSeconds to the existing readinessProbe block
demo_action "Adding timeoutSeconds override to env.cue..."

MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | awk -v timeout="$PROD_OVERRIDE_TIMEOUT" '
BEGIN { in_prod_exampleapp=0; in_deployment=0; in_readiness=0; added=0 }
# Match "prod: exampleApp:" at start of line (the specific block we want)
/^prod: exampleApp:/ { in_prod_exampleapp=1 }
# Reset when we see any other top-level definition (dev:, stage:, prod: postgres:, etc.)
/^[a-z]+:/ && !/^prod: exampleApp:/ { in_prod_exampleapp=0; in_deployment=0; in_readiness=0 }
in_prod_exampleapp && /deployment: \{/ { in_deployment=1 }
in_deployment && /readinessProbe: \{/ { in_readiness=1 }
in_readiness && /periodSeconds:/ && !added {
    print
    print "\t\t\t\ttimeoutSeconds: " timeout
    in_readiness=0
    added=1  # Only add once
    next
}
{print}
')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi

# Verify the change was actually made
if [[ "$MODIFIED_ENV_CUE" == "$PROD_ENV_CUE" ]]; then
    demo_fail "No change made - readinessProbe block not found in prod env.cue"
    exit 1
fi

demo_verify "Modified env.cue with override"

demo_action "Change preview:"
diff <(echo "$PROD_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true

# Create branch and MR for the override
OVERRIDE_BRANCH="uc-b5-prod-override-$(date +%s)"

demo_action "Creating branch '$OVERRIDE_BRANCH' from prod in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$OVERRIDE_BRANCH" --from prod >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $OVERRIDE_BRANCH from prod"

demo_action "Pushing override to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$OVERRIDE_BRANCH" \
    --message "feat: override readinessProbe timeout to ${PROD_OVERRIDE_TIMEOUT}s in prod (UC-B5)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Override branch pushed"

# Create MR from override branch to prod
demo_action "Creating MR for prod override..."
override_mr_iid=$(create_mr "$OVERRIDE_BRANCH" "prod" "UC-B5: Override readinessProbe timeout in prod")

# Wait for MR pipeline
demo_action "Waiting for pipeline to validate override..."
wait_for_mr_pipeline "$override_mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains override..."
assert_mr_contains_diff "$override_mr_iid" "env.cue" "timeoutSeconds: $PROD_OVERRIDE_TIMEOUT" || exit 1

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-prod")

# Merge MR
accept_mr "$override_mr_iid" || exit 1

# Wait for ArgoCD sync
wait_for_argocd_sync "${DEMO_APP}-prod" "$argocd_baseline" || exit 1

demo_verify "Prod override applied successfully"

# ---------------------------------------------------------------------------
# Step 8: Final Verification - Override Only Affects Prod
# ---------------------------------------------------------------------------

demo_step 8 "Final Verification - Override Only Affects Prod"

demo_info "Verifying final state across all environments..."

# Dev should still have app default
demo_action "Checking dev..."
assert_readiness_probe_timeout "$(get_namespace "dev")" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1

# Stage should still have app default
demo_action "Checking stage..."
assert_readiness_probe_timeout "$(get_namespace "stage")" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1

# Prod should have the override
demo_action "Checking prod..."
assert_readiness_probe_timeout "$(get_namespace "prod")" "$DEMO_APP" "$PROD_OVERRIDE_TIMEOUT" || exit 1

demo_verify "VERIFIED: Override hierarchy works correctly!"
demo_info "  - dev:   readinessProbe.timeoutSeconds = $APP_DEFAULT_TIMEOUT (app default)"
demo_info "  - stage: readinessProbe.timeoutSeconds = $APP_DEFAULT_TIMEOUT (app default)"
demo_info "  - prod:  readinessProbe.timeoutSeconds = $PROD_OVERRIDE_TIMEOUT (environment override)"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-B5: App Probe with Environment Override

  What happened:

  PHASE 1: App-Level Default
  1. Added readinessProbe.timeoutSeconds=$APP_DEFAULT_TIMEOUT to services/apps/example-app.cue
  2. Promoted through all environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  3. CHECKPOINT: Verified all environments had timeoutSeconds=$APP_DEFAULT_TIMEOUT

  PHASE 2: Prod Override
  4. Added readinessProbe.timeoutSeconds=$PROD_OVERRIDE_TIMEOUT to prod's env.cue via MR
  5. Verified final state:
     - dev/stage: app default (${APP_DEFAULT_TIMEOUT}s)
     - prod: environment override (${PROD_OVERRIDE_TIMEOUT}s)

  Key Observations:
  - App-level probe settings propagate to all environments
  - Environment-level overrides take precedence (CUE unification)
  - Override only affects target environment (isolation)
  - All changes go through MR with pipeline validation (GitOps)

  CUE Override Hierarchy Validated:
    App (services/apps/example-app.cue) → sets default (${APP_DEFAULT_TIMEOUT}s)
        |
    Environment (env.cue on prod) → overrides for prod only (${PROD_OVERRIDE_TIMEOUT}s)

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 10 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

[[ -n "$FEATURE_BRANCH" ]] && demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"
demo_info "Override branch '$OVERRIDE_BRANCH' left in GitLab for reference"

demo_complete
