#!/usr/bin/env bash
# Demo: App Env Var with Environment Override (UC-B6)
#
# This demo showcases the CUE override hierarchy for environment variables:
# - App-level env vars (appEnvVars) propagate to ALL environments
# - Environment-level env vars (additionalEnv) override by name
# - Later values win when the same env var name appears multiple times
#
# Use Case UC-B6:
# "App sets LOG_LEVEL=INFO as default, but dev needs LOG_LEVEL=DEBUG"
#
# What This Demonstrates:
# - App-level env vars propagate to all environments
# - Environment-level additionalEnv is CONCATENATED (not merged by name)
# - Both LOG_LEVEL values appear in manifest; K8s uses last one
# - Full MR-based GitOps workflow for both phases
#
# Flow:
# Phase 1: Add App-Level Default (propagates to all envs)
#   1. Add LOG_LEVEL=INFO to appEnvVars in templates/apps/example-app.cue
#   2. Create MR: feature → dev
#   3. Promote through dev → stage → prod
#   4. Verify all envs have LOG_LEVEL=INFO
#
# Phase 2: Add Dev Override
#   5. Add LOG_LEVEL=DEBUG to dev's additionalEnv in env.cue
#   6. Create MR: feature → dev
#   7. Verify dev has DEBUG (last wins), stage/prod have INFO
#
# Design Note:
#   Env vars are merged by name using #MergeEnvVars helper.
#   additionalEnv values override appEnvVars values with the same name.
#   This enables environment-specific overrides as expected.
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

ENV_VAR_NAME="LOG_LEVEL"
APP_DEFAULT_VALUE="INFO"
DEV_OVERRIDE_VALUE="DEBUG"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-B6: App Env Var with Environment Override"

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

demo_info "Checking current $ENV_VAR_NAME env var across environments..."
demo_info "(Should not exist yet - we'll add it at app level)"

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    current=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$ENV_VAR_NAME\")].value}" 2>/dev/null || echo "")
    if [[ -z "$current" ]]; then
        demo_verify "$env: $ENV_VAR_NAME not set (expected)"
    else
        demo_warn "$env: $ENV_VAR_NAME = $current (already exists)"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    fi
done

demo_verify "Baseline confirmed: $ENV_VAR_NAME not present in any environment"

# ============================================================================
# PHASE 1: Add App-Level Default (propagates to all environments)
# ============================================================================

demo_step 3 "PHASE 1: Add App-Level Default"

demo_info "Adding $ENV_VAR_NAME=$APP_DEFAULT_VALUE to appEnvVars in templates/apps/example-app.cue"
demo_info "This will propagate to ALL environments (dev, stage, prod)"

# Edit LOCAL file directly
APP_CUE_PATH="templates/apps/example-app.cue"

# Check if LOG_LEVEL already exists
if grep -q "\"$ENV_VAR_NAME\"" "$APP_CUE_PATH"; then
    demo_warn "$ENV_VAR_NAME already exists in $APP_CUE_PATH"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Add LOG_LEVEL to appEnvVars list
# Find the last entry in appEnvVars and add after it
demo_action "Adding $ENV_VAR_NAME to appEnvVars..."

# Use awk to add a new entry to the appEnvVars list (before the closing ])
awk -v name="$ENV_VAR_NAME" -v val="$APP_DEFAULT_VALUE" '
/appEnvVars: \[/ { in_envvars=1 }
in_envvars && /\]/ {
    # Insert before the closing bracket
    print "\t\t{"
    print "\t\t\tname:  \"" name "\""
    print "\t\t\tvalue: \"" val "\""
    print "\t\t},"
    in_envvars=0
}
{print}
' "$APP_CUE_PATH" > "${APP_CUE_PATH}.tmp" && mv "${APP_CUE_PATH}.tmp" "$APP_CUE_PATH"

demo_verify "Added $ENV_VAR_NAME to $APP_CUE_PATH"

# Verify the change was actually made
if ! grep -q "\"$ENV_VAR_NAME\"" "$APP_CUE_PATH"; then
    demo_fail "Failed to add $ENV_VAR_NAME - appEnvVars block may be malformed"
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
grep -A3 "$ENV_VAR_NAME" "$APP_CUE_PATH" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 4: Push App-Level Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push App-Level Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-b6-app-env-var-$(date +%s)"

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
    --message "feat: add $ENV_VAR_NAME to app env vars (UC-B6)" \
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
mr_iid=$(create_mr "$FEATURE_BRANCH" "dev" "UC-B6: Add $ENV_VAR_NAME to app env vars")

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
        assert_mr_contains_diff "$mr_iid" "$APP_CUE_PATH" "$ENV_VAR_NAME" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$ENV_VAR_NAME" || exit 1
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
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$ENV_VAR_NAME" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state - env var should be INFO in all environments
    demo_action "Verifying $ENV_VAR_NAME in K8s..."
    assert_deployment_env_var "$(get_namespace "$env")" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 6: Checkpoint - All Environments Have App Default
# ---------------------------------------------------------------------------

demo_step 6 "Checkpoint - All Environments Have App Default"

demo_info "Verifying app default propagated to ALL environments..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_deployment_env_var "$(get_namespace "$env")" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1
done

demo_verify "CHECKPOINT: All environments have $ENV_VAR_NAME=$APP_DEFAULT_VALUE"
demo_info "This proves app-level env vars propagate correctly."
echo ""

# ============================================================================
# PHASE 2: Add Dev Override (stays in dev only)
# ============================================================================

demo_step 7 "PHASE 2: Add Dev Override"

demo_info "Now adding override to dev: $ENV_VAR_NAME=$DEV_OVERRIDE_VALUE"
demo_info "This will ONLY affect dev (additionalEnv comes after appEnvVars)"
demo_info ""
demo_info "NOTE: Both values will appear in manifest (concatenation, not merge)."
demo_info "      Kubernetes uses 'last wins' - additionalEnv value takes effect."

# Get current env.cue content from dev branch
demo_action "Fetching dev's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "dev" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from dev branch"
    exit 1
fi
demo_verify "Retrieved dev's env.cue"

# Check if override already exists in additionalEnv (exact name match)
# Use word boundary to avoid matching QUARKUS_LOG_LEVEL when looking for LOG_LEVEL
if echo "$DEV_ENV_CUE" | grep -E "name:\s+\"${ENV_VAR_NAME}\"" >/dev/null; then
    demo_warn "$ENV_VAR_NAME already exists in dev's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify the content - add LOG_LEVEL to additionalEnv in dev exampleApp
# The existing structure has additionalEnv with QUARKUS_LOG_LEVEL and ENVIRONMENT
# We add LOG_LEVEL=DEBUG before the closing ]
demo_action "Adding $ENV_VAR_NAME override to env.cue additionalEnv..."

MODIFIED_ENV_CUE=$(echo "$DEV_ENV_CUE" | awk -v name="$ENV_VAR_NAME" -v val="$DEV_OVERRIDE_VALUE" '
BEGIN { in_dev=0; in_app=0; in_deployment=0; in_additional=0 }
/^dev:/ { in_dev=1 }
in_dev && /exampleApp:/ { in_app=1 }
in_app && /deployment: \{/ { in_deployment=1 }
in_deployment && /additionalEnv: \[/ { in_additional=1 }
in_additional && /\]/ {
    # Insert before the closing bracket
    print "\t\t\t\t{"
    print "\t\t\t\t\tname:  \"" name "\""
    print "\t\t\t\t\tvalue: \"" val "\""
    print "\t\t\t\t},"
    in_additional=0
}
# Reset when we exit the dev block
/^[a-z]+:/ && !/^dev:/ { in_dev=0; in_app=0; in_deployment=0; in_additional=0 }
{print}
')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi

# Verify the change was actually made
if [[ "$MODIFIED_ENV_CUE" == "$DEV_ENV_CUE" ]]; then
    demo_fail "No change made - additionalEnv block not found in dev env.cue"
    exit 1
fi

demo_verify "Modified env.cue with override"

demo_action "Change preview:"
diff <(echo "$DEV_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true

# Create branch and MR for the override
OVERRIDE_BRANCH="uc-b6-dev-override-$(date +%s)"

demo_action "Creating branch '$OVERRIDE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$OVERRIDE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $OVERRIDE_BRANCH from dev"

demo_action "Pushing override to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$OVERRIDE_BRANCH" \
    --message "feat: override $ENV_VAR_NAME to $DEV_OVERRIDE_VALUE in dev (UC-B6)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Override branch pushed"

# Create MR from override branch to dev
demo_action "Creating MR for dev override..."
override_mr_iid=$(create_mr "$OVERRIDE_BRANCH" "dev" "UC-B6: Override $ENV_VAR_NAME in dev")

# Wait for MR pipeline
demo_action "Waiting for pipeline to validate override..."
wait_for_mr_pipeline "$override_mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains override..."
assert_mr_contains_diff "$override_mr_iid" "env.cue" "$DEV_OVERRIDE_VALUE" || exit 1

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-dev")

# Merge MR
accept_mr "$override_mr_iid" || exit 1

# Wait for ArgoCD sync
wait_for_argocd_sync "${DEMO_APP}-dev" "$argocd_baseline" || exit 1

demo_verify "Dev override applied successfully"

# ---------------------------------------------------------------------------
# Step 8: Final Verification - Override Works Correctly
# ---------------------------------------------------------------------------

demo_step 8 "Final Verification - Override Works Correctly"

demo_info "Verifying final state across all environments..."

# With #MergeEnvVars, env vars are merged by name and later values win
# So dev should have LOG_LEVEL=DEBUG (override), stage/prod have LOG_LEVEL=INFO

demo_action "Checking dev env var (override should work)..."
assert_deployment_env_var "$(get_namespace "dev")" "$DEMO_APP" "$ENV_VAR_NAME" "$DEV_OVERRIDE_VALUE" || exit 1

# Stage should have only app default
demo_action "Checking stage (should have app default)..."
assert_deployment_env_var "$(get_namespace "stage")" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1

# Prod should have only app default
demo_action "Checking prod (should have app default)..."
assert_deployment_env_var "$(get_namespace "prod")" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1

demo_verify "Override works correctly!"
demo_info "  - dev:   $ENV_VAR_NAME = $DEV_OVERRIDE_VALUE (override applied)"
demo_info "  - stage: $ENV_VAR_NAME = $APP_DEFAULT_VALUE (app default)"
demo_info "  - prod:  $ENV_VAR_NAME = $APP_DEFAULT_VALUE (app default)"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  UC-B6: App Env Var with Environment Override - VERIFIED

  What happened:

  PHASE 1: App-Level Default
  1. Added $ENV_VAR_NAME=$APP_DEFAULT_VALUE to appEnvVars in templates/apps/example-app.cue
  2. Promoted through all environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  3. CHECKPOINT: Verified all environments had $ENV_VAR_NAME=$APP_DEFAULT_VALUE

  PHASE 2: Dev Override (Proves Override Works)
  4. Added $ENV_VAR_NAME=$DEV_OVERRIDE_VALUE to dev's additionalEnv via MR
  5. Verified results:
     - dev:   $ENV_VAR_NAME=$DEV_OVERRIDE_VALUE (override applied)
     - stage: $ENV_VAR_NAME=$APP_DEFAULT_VALUE (app default)
     - prod:  $ENV_VAR_NAME=$APP_DEFAULT_VALUE (app default)

  Why It Works:
  The CUE template uses #MergeEnvVars to merge env vars by name.
  Later values override earlier ones, so additionalEnv wins over appEnvVars.

  This is the expected behavior for environment-specific overrides.

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
demo_info "Override branch '$OVERRIDE_BRANCH' left in GitLab for reference"

demo_complete
