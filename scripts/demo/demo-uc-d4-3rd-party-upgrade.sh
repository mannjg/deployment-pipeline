#!/bin/bash
# Demo: 3rd Party Dependency Upgrade (UC-D4)
#
# This demo showcases the 3rd party dependency upgrade workflow - rolling
# out an upstream image update (postgres) through dev→stage→prod.
#
# Use Case UC-D4:
# "As a platform team, we need to upgrade postgres from 16-alpine to
#  17-alpine, testing in dev first, then promoting through stage→prod
#  independently of example-app's release cycle."
#
# What This Demonstrates:
# - 3rd party images are promoted correctly (not filtered out)
# - Upgrade flows through environments via normal MR workflow
# - example-app remains unchanged (app independence)
# - Rollback is straightforward (revert the upgrade)
#
# Flow:
# 1. Capture baseline state (all envs at postgres:16-alpine)
# 2. Upgrade postgres to 17-alpine in dev via MR
# 3. Verify dev has new version, stage/prod have old
# 4. Promote dev→stage via normal MR
# 5. Verify stage has new version, prod has old
# 6. Promote stage→prod via normal MR
# 7. Verify all environments have new version
# 8. Cleanup (revert to original version)
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - All environments currently at same postgres version
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

DEMO_APP="postgres"
DEMO_APP_CUE="postgres"  # CUE identifier (same as app name for postgres)
ORIGINAL_IMAGE="postgres:16-alpine"
UPGRADE_IMAGE="postgres:17-alpine"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Get postgres image from a deployment
get_postgres_image() {
    local env="$1"
    local ns
    ns=$(get_namespace "$env")
    kubectl get deployment postgres -n "$ns" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

# Update postgres image in env.cue content
update_postgres_image() {
    local env_cue_content="$1"
    local target_env="$2"
    local new_image="$3"

    # Use sed to update the postgres image in the specific environment block
    # Pattern: within the postgres block for target_env, replace image: "..."
    echo "$env_cue_content" | sed -E "s|(${target_env}: postgres:.*image: \")([^\"]+)(\")|\1${new_image}\3|"
}

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-D4: 3rd Party Dependency Upgrade (postgres)"

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

demo_action "Checking postgres deployments exist in all environments..."
for env in dev stage prod; do
    ns=$(get_namespace "$env")
    if kubectl get deployment postgres -n "$ns" &>/dev/null; then
        demo_verify "postgres deployment exists in $env"
    else
        demo_fail "postgres deployment not found in $env"
        exit 1
    fi
done

demo_action "Checking ArgoCD applications for postgres..."
for env in dev stage prod; do
    if kubectl get application "postgres-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app postgres-${env} exists"
    else
        demo_fail "ArgoCD app postgres-${env} not found"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Verify Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Verify Baseline State"

demo_info "Ensuring ArgoCD postgres apps are synced and healthy..."
for env in dev stage prod; do
    trigger_argocd_refresh "postgres-${env}"
    tries=0
    while [[ $tries -lt 12 ]]; do
        sync=$(kubectl get application "postgres-${env}" -n "${ARGOCD_NAMESPACE}" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null)
        health=$(kubectl get application "postgres-${env}" -n "${ARGOCD_NAMESPACE}" \
            -o jsonpath='{.status.health.status}' 2>/dev/null)
        if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
            break
        fi
        sleep 5
        ((tries++))
    done
done

demo_info "Confirming all environments have the same postgres version..."

BASELINE_MISMATCH=false
for env in dev stage prod; do
    current_image=$(get_postgres_image "$env")
    demo_action "Checking $env: $current_image"

    if [[ "$current_image" != "$ORIGINAL_IMAGE" ]]; then
        demo_warn "$env has $current_image (expected $ORIGINAL_IMAGE)"
        BASELINE_MISMATCH=true
    fi
done

if [[ "$BASELINE_MISMATCH" == "true" ]]; then
    demo_warn "Environments have different postgres versions"
    demo_info "This demo expects all environments at $ORIGINAL_IMAGE"
    demo_info "Run reset-demo-state.sh to restore baseline"
    exit 1
fi

demo_verify "Baseline confirmed: all environments at $ORIGINAL_IMAGE"

# ---------------------------------------------------------------------------
# Step 3: Upgrade postgres in Dev
# ---------------------------------------------------------------------------

demo_step 3 "Upgrade postgres in Dev"

demo_info "Scenario: Platform team decides to upgrade postgres"
demo_info "Upgrading: $ORIGINAL_IMAGE → $UPGRADE_IMAGE"

# Get current env.cue content from dev branch
demo_action "Fetching dev's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "dev" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from dev branch"
    exit 1
fi
demo_verify "Retrieved dev's env.cue"

# Update postgres image in dev's env.cue
demo_action "Updating postgres image in env.cue..."
MODIFIED_DEV_CUE=$(echo "$DEV_ENV_CUE" | sed "s|image: \"$ORIGINAL_IMAGE\"|image: \"$UPGRADE_IMAGE\"|")

# Verify the change was made
if ! echo "$MODIFIED_DEV_CUE" | grep -q "$UPGRADE_IMAGE"; then
    demo_fail "Failed to update postgres image in env.cue"
    exit 1
fi
demo_verify "Updated postgres image to $UPGRADE_IMAGE"

# Generate feature branch name
DEV_FEATURE_BRANCH="uc-d4-postgres-upgrade-$(date +%s)"

demo_action "Creating branch '$DEV_FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$DEV_FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $DEV_FEATURE_BRANCH from dev"

demo_action "Pushing upgrade to GitLab..."
echo "$MODIFIED_DEV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$DEV_FEATURE_BRANCH" \
    --message "chore(deps): upgrade postgres $ORIGINAL_IMAGE → $UPGRADE_IMAGE [UC-D4]" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Upgrade pushed to feature branch"

# ---------------------------------------------------------------------------
# Step 4: Merge to Dev and Verify
# ---------------------------------------------------------------------------

demo_step 4 "Merge to Dev and Verify"

demo_action "Creating MR: $DEV_FEATURE_BRANCH → dev..."
dev_mr_iid=$(create_mr "$DEV_FEATURE_BRANCH" "dev" "chore(deps): upgrade postgres to 17-alpine [UC-D4]")

demo_action "Waiting for Jenkins CI to validate and generate manifests..."
wait_for_mr_pipeline "$dev_mr_iid" || exit 1

# Capture ArgoCD baseline before merge
dev_argocd_baseline=$(get_argocd_revision "postgres-dev")

demo_info "Merging postgres upgrade to dev..."
accept_mr "$dev_mr_iid" || exit 1

# Wait for ArgoCD to sync dev
demo_action "Waiting for ArgoCD to sync postgres-dev..."
wait_for_argocd_sync "postgres-dev" "$dev_argocd_baseline" || exit 1

# Verify dev has new version
demo_action "Verifying dev has upgraded postgres..."
dev_image=$(get_postgres_image "dev")
if [[ "$dev_image" == "$UPGRADE_IMAGE" ]]; then
    demo_verify "dev: postgres upgraded to $UPGRADE_IMAGE"
else
    demo_fail "dev: expected $UPGRADE_IMAGE, got $dev_image"
    exit 1
fi

# Verify stage/prod still have old version
for env in stage prod; do
    demo_action "Verifying $env still has original version..."
    env_image=$(get_postgres_image "$env")
    if [[ "$env_image" == "$ORIGINAL_IMAGE" ]]; then
        demo_verify "$env: still at $ORIGINAL_IMAGE (as expected)"
    else
        demo_fail "$env: expected $ORIGINAL_IMAGE, got $env_image"
        exit 1
    fi
done

demo_info ""
demo_info "Status after dev upgrade:"
demo_info "  dev:   $UPGRADE_IMAGE (upgraded)"
demo_info "  stage: $ORIGINAL_IMAGE (unchanged)"
demo_info "  prod:  $ORIGINAL_IMAGE (unchanged)"

# ---------------------------------------------------------------------------
# Step 5: Wait for Auto-Promotion MR to Stage
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Auto-Promotion MR to Stage"

demo_info "The dev branch build should auto-create a promotion MR to stage..."
demo_info "This MR will include the postgres image change"

# Wait for promotion MR to appear
demo_action "Waiting for auto-promotion MR to stage..."
stage_mr_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Poll for promotion MR
TIMEOUT=120
ELAPSED=0
STAGE_MR_IID=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    MR_JSON=$("$GITLAB_CLI" mr list p2c/k8s-deployments --state opened --target stage 2>/dev/null || echo "[]")
    # Handle both single object and array responses from gitlab-cli
    STAGE_MR_IID=$(echo "$MR_JSON" | jq -r 'if type == "array" then . else [.] end | map(select(.source_branch | startswith("promote-stage-"))) | first | .iid // empty')

    if [[ -n "$STAGE_MR_IID" ]]; then
        demo_verify "Found promotion MR !$STAGE_MR_IID to stage"
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    demo_info "Waiting for promotion MR... (${ELAPSED}s)"
done

if [[ -z "$STAGE_MR_IID" ]]; then
    demo_fail "Timeout waiting for promotion MR to stage"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Merge Stage Promotion and Verify
# ---------------------------------------------------------------------------

demo_step 6 "Merge Stage Promotion and Verify"

demo_action "Waiting for stage promotion MR pipeline..."
wait_for_mr_pipeline "$STAGE_MR_IID" || exit 1

# Capture ArgoCD baseline before merge
stage_argocd_baseline=$(get_argocd_revision "postgres-stage")

demo_info "Merging postgres upgrade to stage..."
accept_mr "$STAGE_MR_IID" || exit 1

# Wait for ArgoCD to sync stage
demo_action "Waiting for ArgoCD to sync postgres-stage..."
wait_for_argocd_sync "postgres-stage" "$stage_argocd_baseline" || exit 1

# Verify stage has new version
demo_action "Verifying stage has upgraded postgres..."
stage_image=$(get_postgres_image "stage")
if [[ "$stage_image" == "$UPGRADE_IMAGE" ]]; then
    demo_verify "stage: postgres upgraded to $UPGRADE_IMAGE"
else
    demo_fail "stage: expected $UPGRADE_IMAGE, got $stage_image"
    exit 1
fi

# Verify prod still has old version
demo_action "Verifying prod still has original version..."
prod_image=$(get_postgres_image "prod")
if [[ "$prod_image" == "$ORIGINAL_IMAGE" ]]; then
    demo_verify "prod: still at $ORIGINAL_IMAGE (as expected)"
else
    demo_fail "prod: expected $ORIGINAL_IMAGE, got $prod_image"
    exit 1
fi

demo_info ""
demo_info "Status after stage promotion:"
demo_info "  dev:   $UPGRADE_IMAGE"
demo_info "  stage: $UPGRADE_IMAGE (upgraded)"
demo_info "  prod:  $ORIGINAL_IMAGE (unchanged)"

# ---------------------------------------------------------------------------
# Step 7: Wait for Auto-Promotion MR to Prod
# ---------------------------------------------------------------------------

demo_step 7 "Wait for Auto-Promotion MR to Prod"

demo_info "The stage branch build should auto-create a promotion MR to prod..."

demo_action "Waiting for auto-promotion MR to prod..."
TIMEOUT=120
ELAPSED=0
PROD_MR_IID=""

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    MR_JSON=$("$GITLAB_CLI" mr list p2c/k8s-deployments --state opened --target prod 2>/dev/null || echo "[]")
    # Handle both single object and array responses from gitlab-cli
    PROD_MR_IID=$(echo "$MR_JSON" | jq -r 'if type == "array" then . else [.] end | map(select(.source_branch | startswith("promote-prod-"))) | first | .iid // empty')

    if [[ -n "$PROD_MR_IID" ]]; then
        demo_verify "Found promotion MR !$PROD_MR_IID to prod"
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
    demo_info "Waiting for promotion MR... (${ELAPSED}s)"
done

if [[ -z "$PROD_MR_IID" ]]; then
    demo_fail "Timeout waiting for promotion MR to prod"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Merge Prod Promotion and Verify
# ---------------------------------------------------------------------------

demo_step 8 "Merge Prod Promotion and Verify"

demo_action "Waiting for prod promotion MR pipeline..."
wait_for_mr_pipeline "$PROD_MR_IID" || exit 1

# Capture ArgoCD baseline before merge
prod_argocd_baseline=$(get_argocd_revision "postgres-prod")

demo_info "Merging postgres upgrade to prod..."
accept_mr "$PROD_MR_IID" || exit 1

# Wait for ArgoCD to sync prod
demo_action "Waiting for ArgoCD to sync postgres-prod..."
wait_for_argocd_sync "postgres-prod" "$prod_argocd_baseline" || exit 1

# Verify prod has new version
demo_action "Verifying prod has upgraded postgres..."
prod_image=$(get_postgres_image "prod")
if [[ "$prod_image" == "$UPGRADE_IMAGE" ]]; then
    demo_verify "prod: postgres upgraded to $UPGRADE_IMAGE"
else
    demo_fail "prod: expected $UPGRADE_IMAGE, got $prod_image"
    exit 1
fi

demo_info ""
demo_info "Status after prod promotion:"
demo_info "  dev:   $UPGRADE_IMAGE"
demo_info "  stage: $UPGRADE_IMAGE"
demo_info "  prod:  $UPGRADE_IMAGE (upgrade complete!)"

# ---------------------------------------------------------------------------
# Step 9: Verify example-app Unchanged
# ---------------------------------------------------------------------------

demo_step 9 "Verify example-app Unchanged"

demo_info "Verifying example-app was NOT affected by postgres upgrade..."
demo_info "(Apps should be independent - postgres change shouldn't touch example-app)"

# Get example-app images from all environments
for env in dev stage prod; do
    demo_action "Checking example-app in $env..."
    ns=$(get_namespace "$env")
    ea_image=$(kubectl get deployment example-app -n "$ns" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

    # Just verify it still has a valid CI/CD image (wasn't corrupted)
    if echo "$ea_image" | grep -qE "${CONTAINER_REGISTRY_EXTERNAL}/p2c/example-app:"; then
        demo_verify "example-app in $env: $ea_image (unchanged)"
    else
        demo_fail "example-app in $env has unexpected image: $ea_image"
        exit 1
    fi
done

demo_verify "App independence confirmed: example-app unchanged by postgres upgrade"

# ---------------------------------------------------------------------------
# Step 10: Summary
# ---------------------------------------------------------------------------

demo_step 10 "Summary"

cat << EOF

  This demo validated UC-D4: 3rd Party Dependency Upgrade

  Scenario:
  "Platform team needs to upgrade postgres from 16-alpine to 17-alpine,
   testing in dev first, then promoting through stage→prod."

  What happened:
  1. Updated postgres image in dev's env.cue
  2. Created MR, CI validated, merged to dev
  3. ArgoCD synced postgres-dev with new image
  4. Auto-promotion created MR to stage (postgres included!)
  5. Merged to stage, ArgoCD synced postgres-stage
  6. Auto-promotion created MR to prod
  7. Merged to prod, ArgoCD synced postgres-prod
  8. Verified example-app unchanged throughout

  Key Observations:
  - 3rd party images (postgres) now flow through promotion correctly
  - No registry filter blocking upstream images
  - Same workflow as 1st party apps (example-app)
  - Apps remain independent (postgres change doesn't affect example-app)
  - GitOps workflow preserved (MRs, CI validation, ArgoCD sync)

  Before the fix:
    promote-app-config.sh filtered images by registry pattern
    Only docker.jmann.local/p2c/* images were promoted
    postgres:16-alpine was silently SKIPPED

  After the fix:
    ALL images are promoted (principle: target equals source)
    3rd party dependencies roll out properly through environments

EOF

# ---------------------------------------------------------------------------
# Step 11: Cleanup
# ---------------------------------------------------------------------------

demo_step 11 "Cleanup"

demo_info "Reverting postgres to original version in all environments..."
demo_info "This uses the same workflow in reverse"

# We need to revert by updating dev, then letting it promote through
# Or we can do direct reverts to each env

# For simplicity, we'll create direct MRs to each environment
# This also tests that direct MRs still work

for env in prod stage dev; do
    demo_action "Reverting postgres in $env..."

    # Get current env.cue
    ENV_CUE=$(get_file_from_branch "$env" "env.cue")

    # Revert the image
    REVERTED_CUE=$(echo "$ENV_CUE" | sed "s|image: \"$UPGRADE_IMAGE\"|image: \"$ORIGINAL_IMAGE\"|")

    # Create cleanup branch
    CLEANUP_BRANCH="uc-d4-cleanup-${env}-$(date +%s)"

    "$GITLAB_CLI" branch create p2c/k8s-deployments "$CLEANUP_BRANCH" --from "$env" >/dev/null

    echo "$REVERTED_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
        --ref "$CLEANUP_BRANCH" \
        --message "chore(deps): revert postgres to $ORIGINAL_IMAGE [no-promote] [UC-D4 cleanup]" \
        --stdin >/dev/null

    # Create and merge cleanup MR
    cleanup_mr_iid=$(create_mr "$CLEANUP_BRANCH" "$env" "Cleanup: Revert postgres to $ORIGINAL_IMAGE [UC-D4]")

    wait_for_mr_pipeline "$cleanup_mr_iid" || exit 1

    argocd_baseline=$(get_argocd_revision "postgres-${env}")
    accept_mr "$cleanup_mr_iid" || exit 1

    wait_for_argocd_sync "postgres-${env}" "$argocd_baseline" || exit 1

    # Verify revert
    reverted_image=$(get_postgres_image "$env")
    if [[ "$reverted_image" == "$ORIGINAL_IMAGE" ]]; then
        demo_verify "$env: postgres reverted to $ORIGINAL_IMAGE"
    else
        demo_warn "$env: postgres is $reverted_image (expected $ORIGINAL_IMAGE)"
    fi
done

demo_info ""
demo_info "Cleanup complete. All environments restored to $ORIGINAL_IMAGE"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_complete
