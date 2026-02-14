#!/usr/bin/env bash
# Demo: Environment-Specific ConfigMap Entry (UC-A3)
#
# This demo showcases how environment-specific changes in env.cue
# remain isolated to a single environment and do NOT propagate to others.
#
# Use Case UC-A3:
# "As a platform operator, I want dev to use a different Redis URL than prod"
#
# What This Demonstrates:
# - Changes to env.cue on an environment branch stay in that environment
# - MR-based GitOps workflow for environment-specific changes
# - Promotion system correctly preserves env-specific config (doesn't override)
# - Different environments can have different ConfigMap values
#
# Flow:
# 1. Create feature branch from dev
# 2. Add redis-url ConfigMap entry to dev's env.cue
# 3. Create MR: feature → dev
# 4. Wait for Jenkins CI to generate manifests
# 5. Merge MR
# 6. Wait for ArgoCD sync
# 7. Verify: dev ConfigMap HAS the entry
# 8. Verify: stage/prod ConfigMaps do NOT have the entry (isolation)
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

DEMO_KEY="demo-redis-url"
DEMO_VALUE="redis://redis.dev.svc:6379"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
DEMO_CONFIGMAP="${DEMO_APP}-config"
TARGET_ENV="dev"
OTHER_ENVS=("stage" "prod")

# Only check for MRs targeting this branch in postflight (auto-promote MRs are expected)
DEMO_QUIESCENT_BRANCHES="$TARGET_ENV"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-A3: Environment-Specific ConfigMap Entry"

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
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

demo_action "Checking ConfigMaps exist in all environments..."
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
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

for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env..."
    assert_configmap_entry_absent "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
        demo_warn "Key '$DEMO_KEY' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_KEY' absent from all environments"

# ---------------------------------------------------------------------------
# Step 3: Add ConfigMap Entry to Dev's env.cue
# ---------------------------------------------------------------------------

demo_step 3 "Add ConfigMap Entry to Dev's env.cue"

demo_info "Adding '$DEMO_KEY: $DEMO_VALUE' to $TARGET_ENV environment only"

# Get current env.cue content from dev branch
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Check if entry already exists
if echo "$DEV_ENV_CUE" | grep -q "\"$DEMO_KEY\""; then
    demo_warn "Key '$DEMO_KEY' already exists in $TARGET_ENV's env.cue"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Modify the content using awk (no local CUE validation - Jenkins CI will validate)
# Add configMap entry to the dev exampleApp appConfig block
demo_action "Adding ConfigMap entry to env.cue..."

# Find the dev: exampleApp: block and add entry to its configMap.data
MODIFIED_ENV_CUE=$(echo "$DEV_ENV_CUE" | awk -v env="$TARGET_ENV" -v key="$DEMO_KEY" -v val="$DEMO_VALUE" '
BEGIN { in_target=0; in_app=0; in_appconfig=0; in_configmap=0 }
$0 ~ "^" env ":" { in_target=1 }
in_target && /exampleApp:/ { in_app=1 }
in_app && /appConfig:/ { in_appconfig=1 }
in_appconfig && /configMap:/ { in_configmap=1 }
in_configmap && /data: \{/ {
    print
    print "\t\t\t\t\"" key "\": \"" val "\""
    next
}
# Reset when we exit the target block (next top-level key)
/^[a-z]+:/ && $0 !~ "^" env ":" { in_target=0; in_app=0; in_appconfig=0; in_configmap=0 }
{print}
')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi

# Verify the change was actually made
if [[ "$MODIFIED_ENV_CUE" == "$DEV_ENV_CUE" ]]; then
    demo_fail "No change made - configMap data block pattern not found in $TARGET_ENV env.cue"
    exit 1
fi

# Verify the key appears in modified content
if ! echo "$MODIFIED_ENV_CUE" | grep -q "\"$DEMO_KEY\""; then
    demo_fail "Failed to add ConfigMap entry - key not found in modified content"
    exit 1
fi

demo_verify "Modified env.cue with ConfigMap entry"

demo_action "Change preview:"
diff <(echo "$DEV_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true

# ---------------------------------------------------------------------------
# Step 4: Push Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-a3-env-configmap-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}
demo_verify "Created branch $FEATURE_BRANCH from $TARGET_ENV"

demo_action "Pushing CUE change to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add $DEMO_KEY to $TARGET_ENV ConfigMap (UC-A3)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Create MR from feature branch to dev
demo_action "Creating MR: $FEATURE_BRANCH → $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "UC-A3: Add $DEMO_KEY to $TARGET_ENV ConfigMap")

# ---------------------------------------------------------------------------
# Step 5: Wait for Pipeline and Merge
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Pipeline and Merge"

# Wait for MR pipeline (Jenkins generates manifests)
demo_action "Waiting for Jenkins CI to generate manifests..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains expected changes..."
assert_mr_contains_diff "$mr_iid" "env.cue" "$DEMO_KEY" || exit 1
assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_KEY" || exit 1
demo_verify "MR contains CUE change and regenerated manifests"

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

# Merge MR
accept_mr "$mr_iid" || exit 1

# ---------------------------------------------------------------------------
# Step 6: Wait for ArgoCD Sync
# ---------------------------------------------------------------------------

demo_step 6 "Wait for ArgoCD Sync"

# Wait for ArgoCD to sync dev
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_verify "$TARGET_ENV environment synced"

# ---------------------------------------------------------------------------
# Step 7: Verify Environment Isolation
# ---------------------------------------------------------------------------

demo_step 7 "Verify Environment Isolation"

demo_info "Verifying '$DEMO_KEY' exists in $TARGET_ENV but NOT in other environments..."

# Verify dev HAS the entry
demo_action "Checking $TARGET_ENV..."
assert_configmap_entry "$(get_namespace "$TARGET_ENV")" "$DEMO_CONFIGMAP" "$DEMO_KEY" "$DEMO_VALUE" || exit 1

# Verify stage/prod do NOT have the entry
for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env..."
    assert_configmap_entry_absent "$(get_namespace "$env")" "$DEMO_CONFIGMAP" "$DEMO_KEY" || {
        demo_fail "ISOLATION VIOLATED: $env has '$DEMO_KEY' but should not!"
        exit 1
    }
done

demo_verify "ISOLATION CONFIRMED: Only $TARGET_ENV has '$DEMO_KEY'"

# ---------------------------------------------------------------------------
# Step 8: Summary
# ---------------------------------------------------------------------------

demo_step 8 "Summary"

cat << EOF

  This demo validated UC-A3: Environment-Specific ConfigMap Entry

  What happened:
  1. Added '$DEMO_KEY: $DEMO_VALUE' to $TARGET_ENV's env.cue
  2. Pushed change via GitOps MR workflow:
     - Created feature branch from $TARGET_ENV
     - Committed CUE change to feature branch
     - Created MR: feature → $TARGET_ENV
     - Jenkins CI regenerated manifests
     - Merged MR
     - ArgoCD synced $TARGET_ENV
  3. Verified isolation:
     - $TARGET_ENV ConfigMap HAS '$DEMO_KEY'
     - stage ConfigMap does NOT have '$DEMO_KEY'
     - prod ConfigMap does NOT have '$DEMO_KEY'

  Key Observations:
  - Changes to env.cue stay in that environment
  - All changes go through MR with pipeline validation (GitOps)
  - Promotion system preserves env-specific config
  - No manual manifest editing required

  CUE Layering Validated:
    Platform (templates/core/) -> defaults
        |
    App (templates/apps/) -> app-wide config
        |
    Environment (env.cue on $TARGET_ENV) -> env-specific override
                                            (STAYS HERE)

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 9 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
