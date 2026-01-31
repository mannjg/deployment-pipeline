#!/bin/bash
# Demo: Cherry-Pick Promotion (UC-D2)
#
# This demo showcases selective app promotion - promoting only specific apps
# from source to target environment while holding others back.
#
# Use Case UC-D2:
# "Dev has new versions of both example-app and postgres. I want to promote
#  only example-app to stage, hold postgres back."
#
# What This Demonstrates:
# - Promotion can be selective (per-app, not all-or-nothing)
# - --only-apps filter in promote-app-config.sh works correctly
# - Held-back apps remain unchanged in target environment
# - GitOps workflow preserved (MR, CI validation, ArgoCD sync)
#
# Flow:
# 1. Verify prerequisites (both apps exist in both envs)
# 2. Setup divergent state (dev ahead of stage for both apps)
# 3. Capture baseline (stage's current images)
# 4. Create selective promotion (only example-app)
# 5. Verify MR contains only example-app changes
# 6. Merge and wait for ArgoCD sync
# 7. Verify selective result (example-app promoted, postgres unchanged)
# 8. Cleanup (revert to baseline)
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

APP_TO_PROMOTE="exampleApp"           # CUE identifier for example-app
APP_TO_PROMOTE_K8S="example-app"      # K8s deployment name
APP_TO_HOLD="postgres"                # CUE identifier (same as K8s name)
SOURCE_ENV="dev"
TARGET_ENV="stage"

# Image versions for divergent state setup
POSTGRES_BASELINE="postgres:16-alpine"
POSTGRES_UPGRADED="postgres:17-alpine"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Get image from a deployment
get_deployment_image() {
    local env="$1"
    local deployment="$2"
    kubectl get deployment "$deployment" -n "$env" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-D2: Cherry-Pick Promotion (Selective App Promotion)"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# Track created branches for cleanup
CREATED_BRANCHES=()

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

demo_action "Checking deployments exist in both environments..."
for app in "$APP_TO_PROMOTE_K8S" "$APP_TO_HOLD"; do
    for env in "$SOURCE_ENV" "$TARGET_ENV"; do
        if kubectl get deployment "$app" -n "$env" &>/dev/null; then
            demo_verify "$app deployment exists in $env"
        else
            demo_fail "$app deployment not found in $env"
            exit 1
        fi
    done
done

demo_action "Checking ArgoCD applications..."
for app in "$APP_TO_PROMOTE_K8S" "$APP_TO_HOLD"; do
    for env in "$SOURCE_ENV" "$TARGET_ENV"; do
        if kubectl get application "${app}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
            demo_verify "ArgoCD app ${app}-${env} exists"
        else
            demo_fail "ArgoCD app ${app}-${env} not found"
            exit 1
        fi
    done
done

# ---------------------------------------------------------------------------
# Step 2: Setup Divergent State
# ---------------------------------------------------------------------------

demo_step 2 "Setup Divergent State"

demo_info "For UC-D2, we need dev to have DIFFERENT versions of both apps than stage"
demo_info "This simulates: 'dev is ahead with multiple pending changes'"

# Check current state
DEV_APP_IMAGE=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_PROMOTE_K8S")
STAGE_APP_IMAGE=$(get_deployment_image "$TARGET_ENV" "$APP_TO_PROMOTE_K8S")
DEV_POSTGRES_IMAGE=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_HOLD")
STAGE_POSTGRES_IMAGE=$(get_deployment_image "$TARGET_ENV" "$APP_TO_HOLD")

demo_info "Current state:"
demo_info "  Dev:   $APP_TO_PROMOTE_K8S=$DEV_APP_IMAGE"
demo_info "         $APP_TO_HOLD=$DEV_POSTGRES_IMAGE"
demo_info "  Stage: $APP_TO_PROMOTE_K8S=$STAGE_APP_IMAGE"
demo_info "         $APP_TO_HOLD=$STAGE_POSTGRES_IMAGE"

# Check if example-app is already divergent (dev != stage)
if [[ "$DEV_APP_IMAGE" == "$STAGE_APP_IMAGE" ]]; then
    demo_fail "example-app is same in dev and stage - nothing to promote"
    demo_info "Run validate-pipeline.sh first to create a new version in dev"
    exit 1
fi
demo_verify "example-app is divergent (dev ahead of stage)"

# Check if postgres needs to be made divergent
if [[ "$DEV_POSTGRES_IMAGE" == "$STAGE_POSTGRES_IMAGE" ]]; then
    demo_info "postgres is same in dev and stage - creating divergence..."
    demo_info "Upgrading postgres in dev: $POSTGRES_BASELINE -> $POSTGRES_UPGRADED"

    # Get dev's env.cue
    DEV_ENV_CUE=$(get_file_from_branch "$SOURCE_ENV" "env.cue")

    # Update postgres image
    MODIFIED_DEV_CUE=$(echo "$DEV_ENV_CUE" | sed "s|image: \"$POSTGRES_BASELINE\"|image: \"$POSTGRES_UPGRADED\"|")

    # Verify the change was made
    if ! echo "$MODIFIED_DEV_CUE" | grep -q "$POSTGRES_UPGRADED"; then
        demo_fail "Failed to update postgres image in env.cue"
        demo_info "Current postgres image may not be $POSTGRES_BASELINE"
        exit 1
    fi

    # Create feature branch for postgres upgrade
    POSTGRES_BRANCH="uc-d2-postgres-diverge-$(date +%s)"
    CREATED_BRANCHES+=("$POSTGRES_BRANCH")

    demo_action "Creating branch '$POSTGRES_BRANCH' from dev..."
    "$GITLAB_CLI" branch create p2c/k8s-deployments "$POSTGRES_BRANCH" --from "$SOURCE_ENV" >/dev/null

    demo_action "Pushing postgres upgrade to GitLab..."
    echo "$MODIFIED_DEV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
        --ref "$POSTGRES_BRANCH" \
        --message "chore(deps): upgrade postgres for UC-D2 demo [no-promote]" \
        --stdin >/dev/null

    # Create and merge MR to dev
    demo_action "Creating MR to dev..."
    postgres_mr_iid=$(create_mr "$POSTGRES_BRANCH" "$SOURCE_ENV" "chore: upgrade postgres for UC-D2 divergence [no-promote]")

    demo_action "Waiting for CI to validate..."
    wait_for_mr_pipeline "$postgres_mr_iid" || exit 1

    # Capture ArgoCD baseline before merge
    postgres_argocd_baseline=$(get_argocd_revision "postgres-${SOURCE_ENV}")

    demo_action "Merging postgres upgrade to dev..."
    accept_mr "$postgres_mr_iid" || exit 1

    # Wait for ArgoCD sync
    demo_action "Waiting for ArgoCD to sync postgres-dev..."
    wait_for_argocd_sync "postgres-${SOURCE_ENV}" "$postgres_argocd_baseline" || exit 1

    # Update our cached image
    DEV_POSTGRES_IMAGE=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_HOLD")
    demo_verify "postgres upgraded in dev: $DEV_POSTGRES_IMAGE"
fi

demo_verify "Divergent state confirmed:"
demo_info "  Dev has newer example-app AND newer postgres"
demo_info "  Stage has older example-app AND older postgres"

# ---------------------------------------------------------------------------
# Step 3: Capture Baseline
# ---------------------------------------------------------------------------

demo_step 3 "Capture Baseline"

# Refresh images after potential postgres upgrade
DEV_APP_IMAGE=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_PROMOTE_K8S")
STAGE_APP_IMAGE_BASELINE=$(get_deployment_image "$TARGET_ENV" "$APP_TO_PROMOTE_K8S")
DEV_POSTGRES_IMAGE=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_HOLD")
STAGE_POSTGRES_IMAGE_BASELINE=$(get_deployment_image "$TARGET_ENV" "$APP_TO_HOLD")

demo_info "Baseline state before cherry-pick promotion:"
demo_info ""
demo_info "  +-------------+-------------------------------------+-------------------------------------+"
demo_info "  | App         | Dev (source)                        | Stage (target)                      |"
demo_info "  +-------------+-------------------------------------+-------------------------------------+"
demo_info "  | example-app | $(printf '%-35s' "$DEV_APP_IMAGE") | $(printf '%-35s' "$STAGE_APP_IMAGE_BASELINE") |"
demo_info "  | postgres    | $(printf '%-35s' "$DEV_POSTGRES_IMAGE") | $(printf '%-35s' "$STAGE_POSTGRES_IMAGE_BASELINE") |"
demo_info "  +-------------+-------------------------------------+-------------------------------------+"
demo_info ""
demo_info "Cherry-pick plan:"
demo_info "  -> Promote example-app: $STAGE_APP_IMAGE_BASELINE -> $DEV_APP_IMAGE"
demo_info "  -> Hold postgres: keep at $STAGE_POSTGRES_IMAGE_BASELINE"

# ---------------------------------------------------------------------------
# Step 4: Create Selective Promotion
# ---------------------------------------------------------------------------

demo_step 4 "Create Selective Promotion"

demo_info "Creating promotion branch from $TARGET_ENV and running selective promote..."

# Create feature branch from stage
FEATURE_BRANCH="uc-d2-cherry-pick-$(date +%s)"
CREATED_BRANCHES+=("$FEATURE_BRANCH")

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null
demo_verify "Created branch from $TARGET_ENV"

# Clone the branch locally to run promote-app-config.sh
WORK_DIR=$(mktemp -d)

demo_action "Cloning branch for local promotion..."
# Clone from GitLab k8s-deployments repo
GITLAB_K8S_URL="https://gitlab.jmann.local/p2c/k8s-deployments.git"
export GIT_SSL_NO_VERIFY=true
git clone --quiet --branch "$FEATURE_BRANCH" "$GITLAB_K8S_URL" "$WORK_DIR" || {
    demo_fail "Failed to clone branch $FEATURE_BRANCH from GitLab"
    rm -rf "$WORK_DIR"
    exit 1
}

# Fetch dev branch for comparison
cd "$WORK_DIR"
git fetch origin "$SOURCE_ENV" --quiet

# Run selective promotion
demo_action "Running: promote-app-config.sh $SOURCE_ENV $TARGET_ENV --only-apps $APP_TO_PROMOTE"
./scripts/promote-app-config.sh "$SOURCE_ENV" "$TARGET_ENV" --only-apps "$APP_TO_PROMOTE" || {
    demo_fail "promote-app-config.sh failed"
    exit 1
}
demo_verify "Selective promotion completed"

# Generate manifests
demo_action "Generating manifests..."
./scripts/generate-manifests.sh "$TARGET_ENV" >/dev/null || {
    demo_fail "Manifest generation failed"
    exit 1
}
demo_verify "Manifests generated"

# Commit changes locally
git add -A
git commit -m "feat: cherry-pick promote $APP_TO_PROMOTE from $SOURCE_ENV to $TARGET_ENV [UC-D2] [no-promote]

Selective promotion using --only-apps filter.
Promoted: $APP_TO_PROMOTE
Held back: $APP_TO_HOLD

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>" >/dev/null

# Push to GitLab
demo_action "Pushing changes to GitLab..."
git push origin "$FEATURE_BRANCH" --quiet
demo_verify "Changes pushed to GitLab"

# Return to main directory and clean up work directory
cd "$K8S_DEPLOYMENTS_DIR"
rm -rf "$WORK_DIR"

# ---------------------------------------------------------------------------
# Step 5: Verify MR and Merge
# ---------------------------------------------------------------------------

demo_step 5 "Verify MR and Merge"

# Create MR
demo_action "Creating MR: $FEATURE_BRANCH -> $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "feat: cherry-pick promote example-app only [UC-D2]")

# Wait for CI
demo_action "Waiting for Jenkins CI to validate and generate manifests..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Verify MR diff shows only example-app changes (not postgres)
demo_action "Verifying MR contains only example-app changes..."
MR_DIFF=$("$GITLAB_CLI" mr diff p2c/k8s-deployments "$mr_iid" 2>/dev/null || echo "")

if echo "$MR_DIFF" | grep -q "postgres.*image:.*$POSTGRES_UPGRADED"; then
    demo_fail "MR incorrectly contains postgres image change!"
    demo_info "Cherry-pick filter did not work correctly"
    exit 1
fi
demo_verify "MR does NOT contain postgres image changes (correct!)"

if ! echo "$MR_DIFF" | grep -q "exampleApp"; then
    demo_fail "MR does not contain example-app changes"
    exit 1
fi
demo_verify "MR contains example-app changes"

# Capture ArgoCD baseline before merge
stage_app_argocd_baseline=$(get_argocd_revision "${APP_TO_PROMOTE_K8S}-${TARGET_ENV}")

# Merge MR
demo_info "Merging cherry-pick promotion to $TARGET_ENV..."
accept_mr "$mr_iid" || exit 1

# ---------------------------------------------------------------------------
# Step 6: Wait for ArgoCD Sync
# ---------------------------------------------------------------------------

demo_step 6 "Wait for ArgoCD Sync"

# Wait for ArgoCD to sync example-app in stage
demo_action "Waiting for ArgoCD to sync ${APP_TO_PROMOTE_K8S}-${TARGET_ENV}..."
wait_for_argocd_sync "${APP_TO_PROMOTE_K8S}-${TARGET_ENV}" "$stage_app_argocd_baseline" || exit 1

demo_verify "$TARGET_ENV environment synced"

# ---------------------------------------------------------------------------
# Step 7: Verify Selective Result
# ---------------------------------------------------------------------------

demo_step 7 "Verify Selective Result"

demo_info "Verifying cherry-pick promotion worked correctly..."

# Get current images
STAGE_APP_IMAGE_AFTER=$(get_deployment_image "$TARGET_ENV" "$APP_TO_PROMOTE_K8S")
STAGE_POSTGRES_IMAGE_AFTER=$(get_deployment_image "$TARGET_ENV" "$APP_TO_HOLD")
DEV_APP_IMAGE_AFTER=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_PROMOTE_K8S")
DEV_POSTGRES_IMAGE_AFTER=$(get_deployment_image "$SOURCE_ENV" "$APP_TO_HOLD")

# Verify example-app was promoted
demo_action "Checking example-app was promoted..."
if [[ "$STAGE_APP_IMAGE_AFTER" == "$DEV_APP_IMAGE" ]]; then
    demo_verify "example-app PROMOTED: stage now matches dev"
else
    demo_fail "example-app NOT promoted correctly"
    demo_info "Expected: $DEV_APP_IMAGE"
    demo_info "Got:      $STAGE_APP_IMAGE_AFTER"
    exit 1
fi

# Verify postgres was held back (unchanged)
demo_action "Checking postgres was held back..."
if [[ "$STAGE_POSTGRES_IMAGE_AFTER" == "$STAGE_POSTGRES_IMAGE_BASELINE" ]]; then
    demo_verify "postgres HELD BACK: stage unchanged"
else
    demo_fail "postgres was incorrectly modified!"
    demo_info "Expected (baseline): $STAGE_POSTGRES_IMAGE_BASELINE"
    demo_info "Got:                 $STAGE_POSTGRES_IMAGE_AFTER"
    exit 1
fi

# Verify dev unchanged
demo_action "Checking dev is unchanged..."
if [[ "$DEV_APP_IMAGE_AFTER" == "$DEV_APP_IMAGE" ]] && [[ "$DEV_POSTGRES_IMAGE_AFTER" == "$DEV_POSTGRES_IMAGE" ]]; then
    demo_verify "dev UNCHANGED (source is read-only during promotion)"
else
    demo_fail "dev was incorrectly modified!"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Summary
# ---------------------------------------------------------------------------

demo_step 8 "Summary"

cat << EOF

  This demo validated UC-D2: Cherry-Pick Promotion

  Scenario:
  "Dev has new versions of both example-app and postgres. Promote only
   example-app to stage, hold postgres back."

  Results:

  +-------------+---------------------------+---------------------------+
  |             |         BEFORE            |          AFTER            |
  | App         +-------------+-------------+-------------+-------------+
  |             |     Dev     |    Stage    |     Dev     |    Stage    |
  +-------------+-------------+-------------+-------------+-------------+
  | example-app | (newer)     | (older)     | (unchanged) | (PROMOTED)  |
  | postgres    | (newer)     | (older)     | (unchanged) | (HELD BACK) |
  +-------------+-------------+-------------+-------------+-------------+

  Key Observations:
  - promote-app-config.sh --only-apps filter works correctly
  - Only selected apps are promoted; others are skipped
  - Stage's postgres image is IDENTICAL before and after
  - Dev (source) is never modified during promotion
  - GitOps workflow preserved (MR, CI validation, ArgoCD sync)

  Command used:
    ./scripts/promote-app-config.sh dev stage --only-apps exampleApp

EOF

# ---------------------------------------------------------------------------
# Step 9: Cleanup
# ---------------------------------------------------------------------------

demo_step 9 "Cleanup"

demo_info "Reverting stage to baseline state..."

# Revert example-app image to baseline
# We need to update the image back to the baseline
CLEANUP_BRANCH="uc-d2-cleanup-$(date +%s)"
CREATED_BRANCHES+=("$CLEANUP_BRANCH")

demo_action "Creating cleanup branch..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$CLEANUP_BRANCH" --from "$TARGET_ENV" >/dev/null

# Use update-app-image.sh pattern via GitLab API
# For simplicity, we'll create an MR that reverts the image

# Clone, revert, push
CLEANUP_DIR=$(mktemp -d)
CLEANUP_CLONE_OK=false
git clone --quiet --branch "$CLEANUP_BRANCH" "$GITLAB_K8S_URL" "$CLEANUP_DIR" && CLEANUP_CLONE_OK=true

if [[ "$CLEANUP_CLONE_OK" == "true" ]]; then
    cd "$CLEANUP_DIR"

    # Update image back to baseline
    ./scripts/update-app-image.sh "$TARGET_ENV" "$APP_TO_PROMOTE" "$STAGE_APP_IMAGE_BASELINE" || {
        demo_warn "Failed to revert image - manual cleanup may be needed"
    }

    # Regenerate manifests
    ./scripts/generate-manifests.sh "$TARGET_ENV" >/dev/null

    git add -A
    git commit -m "chore: revert example-app to baseline [UC-D2 cleanup] [no-promote]" >/dev/null
    git push origin "$CLEANUP_BRANCH" --quiet

    cd "$K8S_DEPLOYMENTS_DIR"
    rm -rf "$CLEANUP_DIR"
else
    demo_warn "Failed to clone cleanup branch - manual cleanup may be needed"
    rm -rf "$CLEANUP_DIR"
fi

# Create and merge cleanup MR
demo_action "Creating cleanup MR..."
cleanup_mr_iid=$(create_mr "$CLEANUP_BRANCH" "$TARGET_ENV" "chore: revert example-app [UC-D2 cleanup]")

demo_action "Waiting for cleanup CI..."
wait_for_mr_pipeline "$cleanup_mr_iid" || exit 1

cleanup_argocd_baseline=$(get_argocd_revision "${APP_TO_PROMOTE_K8S}-${TARGET_ENV}")

demo_action "Merging cleanup MR..."
accept_mr "$cleanup_mr_iid" || exit 1

demo_action "Waiting for ArgoCD sync..."
wait_for_argocd_sync "${APP_TO_PROMOTE_K8S}-${TARGET_ENV}" "$cleanup_argocd_baseline" || exit 1

# Verify cleanup
STAGE_APP_FINAL=$(get_deployment_image "$TARGET_ENV" "$APP_TO_PROMOTE_K8S")
if [[ "$STAGE_APP_FINAL" == "$STAGE_APP_IMAGE_BASELINE" ]]; then
    demo_verify "Cleanup complete: stage reverted to baseline"
else
    demo_warn "Cleanup may be incomplete - verify manually"
fi

# Also revert postgres in dev if we upgraded it
if [[ "$DEV_POSTGRES_IMAGE" == "$POSTGRES_UPGRADED" ]]; then
    demo_info "Reverting postgres in dev to baseline..."

    DEV_REVERT_BRANCH="uc-d2-dev-cleanup-$(date +%s)"
    CREATED_BRANCHES+=("$DEV_REVERT_BRANCH")

    DEV_ENV_CUE=$(get_file_from_branch "$SOURCE_ENV" "env.cue")
    REVERTED_DEV_CUE=$(echo "$DEV_ENV_CUE" | sed "s|image: \"$POSTGRES_UPGRADED\"|image: \"$POSTGRES_BASELINE\"|")

    "$GITLAB_CLI" branch create p2c/k8s-deployments "$DEV_REVERT_BRANCH" --from "$SOURCE_ENV" >/dev/null

    echo "$REVERTED_DEV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
        --ref "$DEV_REVERT_BRANCH" \
        --message "chore: revert postgres to baseline [UC-D2 cleanup] [no-promote]" \
        --stdin >/dev/null

    dev_cleanup_mr_iid=$(create_mr "$DEV_REVERT_BRANCH" "$SOURCE_ENV" "chore: revert postgres [UC-D2 cleanup]")
    wait_for_mr_pipeline "$dev_cleanup_mr_iid" || true

    dev_argocd_baseline=$(get_argocd_revision "postgres-${SOURCE_ENV}")
    accept_mr "$dev_cleanup_mr_iid" || true
    wait_for_argocd_sync "postgres-${SOURCE_ENV}" "$dev_argocd_baseline" || true

    demo_verify "Dev postgres reverted to baseline"
fi

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_complete
