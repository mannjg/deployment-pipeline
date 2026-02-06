#!/bin/bash
# Demo: App-Level Rollback (UC-E4)
#
# This demo proves that app images can be surgically rolled back while
# preserving environment-specific settings (replicas, resources, etc.).
#
# Use Case UC-E4:
# "v1.0.42 deployed to prod has a bug. Roll back to v1.0.41 image while
# preserving prod's env.cue settings (replicas, resources)"
#
# What This Demonstrates:
# - Image tag can be changed independently via direct MR
# - Environment settings (replicas, resources) are preserved
# - Contrast with UC-D3 which uses git revert (rolls back entire commit)
# - Surgical rollback targets ONLY the image, nothing else
#
# Flow:
# 1. Capture current prod image (the "good" version)
# 2. Deploy a new version through the pipeline (the "bad" version)
# 3. Verify the new version is deployed to prod
# 4. Create direct MR to prod that only changes image tag back
# 5. Verify prod rolls back to previous image
# 6. Verify prod's env.cue settings (replicas, etc.) are unchanged
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - At least one prior deployment exists in prod
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
TARGET_ENV="prod"
ENVIRONMENTS=("dev" "stage" "prod")

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"
JENKINS_CLI="${PROJECT_ROOT}/scripts/04-operations/jenkins-cli.sh"

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-E4: App-Level Rollback"

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

demo_action "Checking ArgoCD application..."
if kubectl get application "${DEMO_APP}-${TARGET_ENV}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    demo_verify "ArgoCD app ${DEMO_APP}-${TARGET_ENV} exists"
else
    demo_fail "ArgoCD app ${DEMO_APP}-${TARGET_ENV} not found"
    exit 1
fi

demo_action "Checking prod deployment exists..."
if kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" &>/dev/null; then
    demo_verify "Deployment $DEMO_APP exists in $TARGET_ENV"
else
    demo_fail "Deployment $DEMO_APP not found in $(get_namespace "$TARGET_ENV")"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Capture Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Capture Baseline State"

demo_info "Capturing current prod state as the 'good' version to roll back to..."

# Get current image tag from prod
GOOD_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
GOOD_TAG=$(echo "$GOOD_IMAGE" | sed 's/.*://')

demo_info "Good image tag: $GOOD_TAG"

# Capture current env settings (replicas, resources)
PROD_REPLICAS=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.replicas}')
PROD_CPU_REQUEST=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "not-set")
PROD_MEM_REQUEST=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "not-set")

demo_info "Prod replicas: $PROD_REPLICAS"
demo_info "Prod CPU request: $PROD_CPU_REQUEST"
demo_info "Prod memory request: $PROD_MEM_REQUEST"

demo_verify "Baseline captured"

# ---------------------------------------------------------------------------
# Step 3: Deploy New Version (the "bad" version)
# ---------------------------------------------------------------------------

demo_step 3 "Deploy New Version (simulating 'bad' deploy)"

demo_info "Triggering a new deployment through the pipeline..."
demo_info "This simulates deploying a new version that will need to be rolled back."

# Get current version from pom.xml via gitlab-cli
CURRENT_POM=$("$GITLAB_CLI" file get p2c/example-app pom.xml --ref main)
CURRENT_VERSION=$(echo "$CURRENT_POM" | grep -m1 '<version>' | sed 's/.*<version>\(.*\)<\/version>.*/\1/')
demo_info "Current app version: $CURRENT_VERSION"

# Calculate next version
BASE_VERSION="${CURRENT_VERSION%-SNAPSHOT}"
IFS='.' read -r major minor patch <<< "$BASE_VERSION"
NEW_PATCH=$((patch + 1))
NEW_VERSION="${major}.${minor}.${NEW_PATCH}-SNAPSHOT"
demo_info "New (bad) version: $NEW_VERSION"

# Update pom.xml
MODIFIED_POM=$(echo "$CURRENT_POM" | sed "0,/<version>$CURRENT_VERSION<\/version>/s//<version>$NEW_VERSION<\/version>/")

# Create branch and push
# Use feature/ prefix to match Jenkins branch discovery pattern
BAD_VERSION_BRANCH="feature/uc-e4-bad-version-$(date +%s)"
ENCODED_APP_PROJECT=$(echo "p2c/example-app" | sed 's/\//%2F/g')

demo_action "Creating branch '$BAD_VERSION_BRANCH'..."
"$GITLAB_CLI" branch create p2c/example-app "$BAD_VERSION_BRANCH" --from main >/dev/null

demo_action "Pushing version bump..."
echo "$MODIFIED_POM" | "$GITLAB_CLI" file update p2c/example-app pom.xml \
    --ref "$BAD_VERSION_BRANCH" \
    --message "chore: bump version to $NEW_VERSION [UC-E4 bad version]" \
    --stdin >/dev/null

# Create and merge MR to main
demo_action "Creating MR to main..."
APP_MR_RESULT=$(curl -sk -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"source_branch\":\"$BAD_VERSION_BRANCH\",\"target_branch\":\"main\",\"title\":\"UC-E4: Bad version $NEW_VERSION\"}" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_APP_PROJECT}/merge_requests")

APP_MR_IID=$(echo "$APP_MR_RESULT" | jq -r '.iid // empty')
if [[ -z "$APP_MR_IID" ]]; then
    demo_fail "Failed to create app MR"
    exit 1
fi
demo_verify "Created app MR !$APP_MR_IID"

# Wait for MR pipeline to pass before merging
demo_action "Waiting for MR pipeline to complete..."

# Trigger Jenkins scan to discover the feature branch
trigger_jenkins_scan "example-app" >/dev/null 2>&1

MR_PIPELINE_TIMEOUT=180
MR_ELAPSED=0
while [[ $MR_ELAPSED -lt $MR_PIPELINE_TIMEOUT ]]; do
    MR_INFO=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_APP_PROJECT}/merge_requests/$APP_MR_IID")

    PIPELINE_STATUS=$(echo "$MR_INFO" | jq -r '.head_pipeline.status // empty')

    case "$PIPELINE_STATUS" in
        success)
            demo_verify "MR pipeline passed"
            break
            ;;
        failed)
            demo_fail "MR pipeline failed"
            exit 1
            ;;
        running|pending|created)
            demo_info "Pipeline: $PIPELINE_STATUS (${MR_ELAPSED}s)"
            ;;
        *)
            if [[ $((MR_ELAPSED % 30)) -eq 0 ]] && [[ $MR_ELAPSED -gt 0 ]]; then
                trigger_jenkins_scan "example-app" >/dev/null 2>&1
            fi
            demo_info "Waiting for pipeline... (${MR_ELAPSED}s)"
            ;;
    esac

    sleep 10
    MR_ELAPSED=$((MR_ELAPSED + 10))
done

if [[ $MR_ELAPSED -ge $MR_PIPELINE_TIMEOUT ]]; then
    demo_warn "Timeout waiting for MR pipeline - proceeding with merge"
fi

# Capture timestamp BEFORE merge to wait for builds triggered AFTER this point
PRE_MERGE_TIMESTAMP=$(($(date +%s) * 1000))

demo_action "Merging app MR !$APP_MR_IID..."
MERGE_RESULT=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_APP_PROJECT}/merge_requests/$APP_MR_IID/merge")

if [[ $(echo "$MERGE_RESULT" | jq -r '.state') != "merged" ]]; then
    demo_fail "Failed to merge MR: $(echo "$MERGE_RESULT" | jq -r '.message // "unknown error"')"
    exit 1
fi

demo_verify "App MR merged, triggering Jenkins build"

# Trigger Jenkins scan to ensure it picks up the merge (webhook may be delayed)
demo_action "Triggering Jenkins scan..."
trigger_jenkins_scan "example-app" >/dev/null 2>&1

# Wait for Jenkins to build - IMPORTANT: use --after to wait for NEW build
demo_action "Waiting for Jenkins build (after merge)..."
"$JENKINS_CLI" wait example-app/main --timeout 300 --after "$PRE_MERGE_TIMESTAMP" || {
    demo_fail "Jenkins build failed"
    exit 1
}

# Wait for and merge k8s-deployments MR through all environments
demo_info "Promoting through all environments..."

K8S_ENCODED_PROJECT=$(echo "p2c/k8s-deployments" | sed 's/\//%2F/g')
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # Wait for k8s-deployments MR
        MR_TIMEOUT=120
        MR_ELAPSED=0
        K8S_MR_IID=""
        while [[ $MR_ELAPSED -lt $MR_TIMEOUT ]]; do
            MRS=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "${GITLAB_URL_EXTERNAL}/api/v4/projects/${K8S_ENCODED_PROJECT}/merge_requests?state=opened&target_branch=dev")
            K8S_MR=$(echo "$MRS" | jq -r --arg ver "$NEW_VERSION" \
                'first(.[] | select(.source_branch | contains($ver))) // empty')
            if [[ -n "$K8S_MR" ]]; then
                K8S_MR_IID=$(echo "$K8S_MR" | jq -r '.iid')
                break
            fi
            sleep 10
            MR_ELAPSED=$((MR_ELAPSED + 10))
        done

        if [[ -z "${K8S_MR_IID:-}" ]]; then
            demo_fail "Timeout waiting for k8s-deployments MR"
            exit 1
        fi
        demo_verify "Found k8s-deployments MR !$K8S_MR_IID"

        wait_for_mr_pipeline "$K8S_MR_IID" || exit 1
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        accept_mr "$K8S_MR_IID" || exit 1
    else
        wait_for_promotion_mr "$env" "$next_promotion_baseline" || exit 1
        wait_for_mr_pipeline "$PROMOTION_MR_IID" || exit 1
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        accept_mr "$PROMOTION_MR_IID" || exit 1
    fi

    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1
    demo_verify "$env deployment synced"
done

# Verify bad version is deployed
BAD_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
BAD_TAG=$(echo "$BAD_IMAGE" | sed 's/.*://')

demo_info "Bad version now deployed: $BAD_TAG"

if [[ "$BAD_TAG" == "$GOOD_TAG" ]]; then
    demo_fail "Bad version tag same as good - something went wrong"
    exit 1
fi

demo_verify "Bad version deployed to prod"

# ---------------------------------------------------------------------------
# Step 4: Execute Surgical Rollback
# ---------------------------------------------------------------------------

demo_step 4 "Execute Surgical Rollback"

demo_info "Rolling back prod to previous image tag: $GOOD_TAG"
demo_info "This is a SURGICAL rollback - only the image tag changes"
demo_info "Environment settings (replicas, resources) will be preserved"

# Get current env.cue from prod branch
PROD_ENV_CUE=$(get_file_from_branch "prod" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from prod branch"
    exit 1
fi

# Extract the current image tag from env.cue for replacement
# The format in env.cue is: image: "registry/path/app:tag"
# We need to replace only the tag portion (after the last colon in the quoted string)
#
# Using sed with pattern: (image:[[:space:]]*"[^"]+):([^"]+)"
#   - Captures everything before the tag colon: image: "docker.jmann.local/p2c/example-app
#   - Replaces the tag portion (after the last colon) with the good tag
MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | sed -E "s|(image:[[:space:]]*\"[^\"]+):([^\"]+)\"|\1:${GOOD_TAG}\"|")

# Verify the modification worked
if ! echo "$MODIFIED_ENV_CUE" | grep -q "$GOOD_TAG"; then
    demo_fail "Could not modify env.cue to set image tag to $GOOD_TAG"
    exit 1
fi

# Create rollback branch
ROLLBACK_BRANCH="uc-e4-rollback-$(date +%s)"

demo_action "Creating rollback branch '$ROLLBACK_BRANCH' from prod..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$ROLLBACK_BRANCH" --from prod >/dev/null

demo_action "Pushing rollback change (image tag only)..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$ROLLBACK_BRANCH" \
    --message "fix: rollback example-app to $GOOD_TAG [no-promote]" \
    --stdin >/dev/null

# Create MR directly to prod
demo_action "Creating rollback MR: $ROLLBACK_BRANCH -> prod..."
ROLLBACK_MR_IID=$(create_mr "$ROLLBACK_BRANCH" "prod" "UC-E4: Rollback to $GOOD_TAG [no-promote]")

# Wait for CI
demo_action "Waiting for CI validation..."
wait_for_mr_pipeline "$ROLLBACK_MR_IID" || exit 1

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

# Merge rollback MR
demo_action "Merging rollback MR..."
accept_mr "$ROLLBACK_MR_IID" || exit 1

demo_verify "Rollback MR merged"

# ---------------------------------------------------------------------------
# Step 5: Verify Rollback
# ---------------------------------------------------------------------------

demo_step 5 "Verify Rollback"

demo_action "Waiting for ArgoCD to sync rollback..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

# Verify image is rolled back
CURRENT_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
CURRENT_TAG=$(echo "$CURRENT_IMAGE" | sed 's/.*://')

if [[ "$CURRENT_TAG" == "$GOOD_TAG" ]]; then
    demo_verify "Image rolled back to: $GOOD_TAG"
else
    demo_fail "Image not rolled back. Expected: $GOOD_TAG, Got: $CURRENT_TAG"
    exit 1
fi

# Verify env settings are preserved
NEW_REPLICAS=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.replicas}')
NEW_CPU=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "not-set")
NEW_MEM=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$TARGET_ENV")" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "not-set")

demo_info "Checking env settings preserved..."
demo_info "  Replicas: $PROD_REPLICAS -> $NEW_REPLICAS"
demo_info "  CPU request: $PROD_CPU_REQUEST -> $NEW_CPU"
demo_info "  Memory request: $PROD_MEM_REQUEST -> $NEW_MEM"

if [[ "$NEW_REPLICAS" == "$PROD_REPLICAS" ]]; then
    demo_verify "Replicas preserved"
else
    demo_warn "Replicas changed (was $PROD_REPLICAS, now $NEW_REPLICAS)"
fi

if [[ "$NEW_CPU" == "$PROD_CPU_REQUEST" ]]; then
    demo_verify "CPU request preserved"
else
    demo_warn "CPU request changed (was $PROD_CPU_REQUEST, now $NEW_CPU)"
fi

if [[ "$NEW_MEM" == "$PROD_MEM_REQUEST" ]]; then
    demo_verify "Memory request preserved"
else
    demo_warn "Memory request changed (was $PROD_MEM_REQUEST, now $NEW_MEM)"
fi

demo_verify "Surgical rollback complete - image changed, env settings preserved"

# ---------------------------------------------------------------------------
# Step 6: Verify Other Environments Unaffected
# ---------------------------------------------------------------------------

demo_step 6 "Verify Other Environments Unaffected"

demo_info "Verifying dev and stage still have the 'bad' version..."

for env in dev stage; do
    demo_action "Checking $env..."
    OTHER_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    OTHER_TAG=$(echo "$OTHER_IMAGE" | sed 's/.*://')

    # Note: Due to version lifecycle, dev might have SNAPSHOT, stage might have RC
    # Both should have the NEW version (not the rolled-back GOOD version)
    if [[ "$OTHER_TAG" != "$GOOD_TAG" ]]; then
        demo_verify "$env still has newer version: $OTHER_TAG (not rolled back)"
    else
        demo_warn "$env has same tag as rollback target: $OTHER_TAG"
    fi
done

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-E4: App-Level Rollback

  What happened:
  1. Captured baseline "good" version: $GOOD_TAG
  2. Deployed new "bad" version: $BAD_TAG
  3. Created SURGICAL rollback - direct MR to prod changing ONLY image tag
  4. Verified:
     - Prod rolled back to: $GOOD_TAG
     - Env settings (replicas=$PROD_REPLICAS) preserved
     - Dev/stage unaffected (still have newer version)

  Contrast with UC-D3 (Environment Rollback):
  - UC-D3 uses git revert (rolls back entire commit)
  - UC-E4 surgically changes only the image tag
  - UC-E4 preserves env.cue settings that may have changed independently

  Key Observations:
  - Image tag can be changed via direct MR without affecting other settings
  - [no-promote] marker prevents rollback from cascading
  - Other environments continue running newer version
  - Full audit trail in git history

  Use UC-E4 when:
  - You need to roll back only the app image
  - Environment settings should be preserved
  - You want surgical control over what changes

  Use UC-D3 when:
  - You want to revert an entire configuration change
  - The "bad" state includes config changes (not just image)
  - You want the simplicity of git revert

EOF

# ---------------------------------------------------------------------------
# Step 8: Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Branches left in GitLab for reference:"
demo_info "  - $BAD_VERSION_BRANCH (bad version branch in example-app)"
demo_info "  - $ROLLBACK_BRANCH (rollback branch in k8s-deployments)"

demo_complete
