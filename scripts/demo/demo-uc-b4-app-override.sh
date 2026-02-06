#!/bin/bash
# Demo: App ConfigMap with Environment Override (UC-B4)
#
# This demo showcases the CUE override hierarchy where:
# - App-level defaults propagate to ALL environments
# - Environment-level settings can override app defaults
#
# Use Case UC-B4:
# "App sets cache-ttl=300, but prod needs cache-ttl=600 for performance"
#
# What This Demonstrates:
# - App-level ConfigMap entries propagate to all environments
# - Environment-level ConfigMap can override specific values
# - Lower layer (env) takes precedence over higher layer (app)
# - Full MR-based GitOps workflow for both phases
#
# Flow:
# Phase 1: Add App-Level Default (propagates to all envs)
#   1. Add cache-ttl=300 to services/apps/example-app.cue
#   2. Create MR: feature → dev
#   3. Promote through dev → stage → prod
#   4. Verify all envs have cache-ttl=300
#
# Phase 2: Add Prod Override
#   5. Add cache-ttl=600 to prod's env.cue
#   6. Create MR: feature → prod
#   7. Verify dev/stage have 300, prod has 600
#
# CUE Override Hierarchy:
#   Platform (services/base/, services/core/)
#     ↓
#   App (services/apps/*.cue)  ← Phase 1 adds here
#     ↓
#   Env (env.cue per branch)   ← Phase 2 overrides here (WINS)
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

DEMO_KEY="demo-cache-ttl"
APP_DEFAULT_VALUE="300"
PROD_OVERRIDE_VALUE="600"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
DEMO_CONFIGMAP="${DEMO_APP}-config"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-B4: App ConfigMap with Environment Override"

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

demo_action "Checking ConfigMaps exist in all environments..."
for env in "${ENVIRONMENTS[@]}"; do
    if kubectl get configmap "$DEMO_CONFIGMAP" -n "$(get_namespace "$env")" &>/dev/null; then
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

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_configmap_entry_absent "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
        demo_warn "Key '$DEMO_KEY' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_KEY' absent from all environments"

# ============================================================================
# PHASE 1: Add App-Level Default (propagates to all environments)
# ============================================================================

demo_step 3 "PHASE 1: Add App-Level Default"

demo_info "Adding '$DEMO_KEY: $APP_DEFAULT_VALUE' to services/apps/example-app.cue"
demo_info "This will propagate to ALL environments (dev, stage, prod)"

# Edit LOCAL file directly (same pattern as UC-C1)
APP_CUE_PATH="services/apps/example-app.cue"

# Check if entry already exists
if grep -q "\"$DEMO_KEY\"" "$APP_CUE_PATH"; then
    demo_warn "Key '$DEMO_KEY' already exists in $APP_CUE_PATH"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Add configMap entry to appConfig block
# The appConfig block is currently empty (just comments), so we add after "appConfig: {"
demo_action "Adding ConfigMap entry to app CUE..."

# Use awk for reliable multi-line insertion after "appConfig: {"
# IMPORTANT: Use CUE default syntax (string | *"300") so env.cue can override
# If we use concrete "300", CUE unification will fail when env.cue sets "600"
awk -v key="$DEMO_KEY" -v val="$APP_DEFAULT_VALUE" '
/appConfig: \{/ {
    print
    print "\t\tconfigMap: {"
    print "\t\t\tdata: {"
    print "\t\t\t\t\"" key "\": string | *\"" val "\""
    print "\t\t\t}"
    print "\t\t}"
    next
}
{print}
' "$APP_CUE_PATH" > "${APP_CUE_PATH}.tmp" && mv "${APP_CUE_PATH}.tmp" "$APP_CUE_PATH"

demo_verify "Added ConfigMap entry to $APP_CUE_PATH"

# Verify the change was actually made
if ! grep -q "\"$DEMO_KEY\"" "$APP_CUE_PATH"; then
    demo_fail "Failed to add ConfigMap entry - appConfig block may be missing"
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
grep -A10 "appConfig" "$APP_CUE_PATH" | head -15 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 4: Push App-Level Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push App-Level Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-b4-app-configmap-$(date +%s)"

# Use GitLab CLI to create branch and push file (same pattern as UC-C1)
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
    --message "feat: add $DEMO_KEY to app ConfigMap defaults (UC-B4)" \
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
mr_iid=$(create_mr "$FEATURE_BRANCH" "dev" "UC-B4: Add $DEMO_KEY to app ConfigMap")

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
        assert_mr_contains_diff "$mr_iid" "$APP_CUE_PATH" "$DEMO_KEY" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_KEY" || exit 1
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
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_KEY" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state
    demo_action "Verifying ConfigMap in K8s..."
    assert_configmap_entry "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$APP_DEFAULT_VALUE" || exit 1

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
    assert_configmap_entry "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$APP_DEFAULT_VALUE" || exit 1
done

demo_verify "CHECKPOINT: All environments have '$DEMO_KEY: $APP_DEFAULT_VALUE'"
demo_info "This proves app-level changes propagate correctly."
echo ""

# ============================================================================
# PHASE 2: Add Prod Override (stays in prod only)
# ============================================================================

demo_step 7 "PHASE 2: Add Prod Override"

demo_info "Now adding override to prod: '$DEMO_KEY: $PROD_OVERRIDE_VALUE'"
demo_info "This will ONLY affect prod (env layer wins over app layer)"

# Get current env.cue content from prod branch
demo_action "Fetching prod's env.cue from GitLab..."
PROD_ENV_CUE=$(get_file_from_branch "prod" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from prod branch"
    exit 1
fi
demo_verify "Retrieved prod's env.cue"

# Check if entry already exists
if echo "$PROD_ENV_CUE" | grep -q "\"$DEMO_KEY\""; then
    demo_warn "Key '$DEMO_KEY' already exists in prod's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify the content using awk (no local CUE validation - Jenkins CI will validate)
# Add configMap entry to the prod exampleApp appConfig block
demo_action "Adding ConfigMap override to env.cue..."

# Find the prod: exampleApp: block and add configMap entry to its appConfig
# The structure is: prod: exampleApp: { appConfig: { configMap: { data: { ... } } } }
# We need to add our key-value pair to the data block
MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | awk -v key="$DEMO_KEY" -v val="$PROD_OVERRIDE_VALUE" '
BEGIN { in_prod=0; in_app=0; in_appconfig=0; in_configmap=0; in_data=0 }
/^prod:/ { in_prod=1 }
in_prod && /exampleApp:/ { in_app=1 }
in_app && /appConfig:/ { in_appconfig=1 }
in_appconfig && /configMap:/ { in_configmap=1 }
in_configmap && /data: \{/ {
    print
    print "\t\t\t\t\"" key "\": \"" val "\""
    next
}
# Reset when we exit the prod block (next top-level key)
/^[a-z]+:/ && !/^prod:/ { in_prod=0; in_app=0; in_appconfig=0; in_configmap=0; in_data=0 }
{print}
')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi

# Verify the change was actually made
if [[ "$MODIFIED_ENV_CUE" == "$PROD_ENV_CUE" ]]; then
    demo_fail "No change made - configMap data block pattern not found in prod env.cue"
    exit 1
fi

# Verify the key appears in modified content
if ! echo "$MODIFIED_ENV_CUE" | grep -q "\"$DEMO_KEY\""; then
    demo_fail "Failed to add override - key not found in modified content"
    exit 1
fi

demo_verify "Modified env.cue with override"

demo_action "Change preview:"
diff <(echo "$PROD_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true

# Create branch and MR for the override
OVERRIDE_BRANCH="uc-b4-prod-override-$(date +%s)"

demo_action "Creating branch '$OVERRIDE_BRANCH' from prod in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$OVERRIDE_BRANCH" --from prod >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $OVERRIDE_BRANCH from prod"

demo_action "Pushing override to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$OVERRIDE_BRANCH" \
    --message "feat: override $DEMO_KEY to $PROD_OVERRIDE_VALUE in prod (UC-B4)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Override branch pushed"

# Create MR from override branch to prod
demo_action "Creating MR for prod override..."
override_mr_iid=$(create_mr "$OVERRIDE_BRANCH" "prod" "UC-B4: Override $DEMO_KEY in prod")

# Wait for MR pipeline
demo_action "Waiting for pipeline to validate override..."
wait_for_mr_pipeline "$override_mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains override..."
assert_mr_contains_diff "$override_mr_iid" "env.cue" "$PROD_OVERRIDE_VALUE" || exit 1

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
assert_configmap_entry "$(get_namespace "dev")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$APP_DEFAULT_VALUE" || exit 1

# Stage should still have app default
demo_action "Checking stage..."
assert_configmap_entry "$(get_namespace "stage")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$APP_DEFAULT_VALUE" || exit 1

# Prod should have the override
demo_action "Checking prod..."
assert_configmap_entry "$(get_namespace "prod")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$PROD_OVERRIDE_VALUE" || exit 1

demo_verify "VERIFIED: Override hierarchy works correctly!"
demo_info "  - dev:   $DEMO_KEY = $APP_DEFAULT_VALUE (app default)"
demo_info "  - stage: $DEMO_KEY = $APP_DEFAULT_VALUE (app default)"
demo_info "  - prod:  $DEMO_KEY = $PROD_OVERRIDE_VALUE (environment override)"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-B4: App ConfigMap with Environment Override

  What happened:

  PHASE 1: App-Level Default
  1. Added '$DEMO_KEY: $APP_DEFAULT_VALUE' to services/apps/example-app.cue
  2. Promoted through all environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  3. CHECKPOINT: Verified all environments had '$DEMO_KEY: $APP_DEFAULT_VALUE'

  PHASE 2: Prod Override
  4. Added '$DEMO_KEY: $PROD_OVERRIDE_VALUE' to prod's env.cue via MR
  5. Verified final state:
     - dev/stage: app default ($APP_DEFAULT_VALUE)
     - prod: environment override ($PROD_OVERRIDE_VALUE)

  Key Observations:
  - App-level ConfigMap entries propagate to all environments
  - Environment-level overrides take precedence (CUE unification)
  - Override only affects target environment (isolation)
  - All changes go through MR with pipeline validation (GitOps)

  CUE Override Hierarchy Validated:
    App (services/apps/example-app.cue) → sets default ($APP_DEFAULT_VALUE)
        |
    Environment (env.cue on prod) → overrides for prod only ($PROD_OVERRIDE_VALUE)

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
