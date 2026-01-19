#!/bin/bash
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
# - Different environments can have different ConfigMap values
# - Promotion does NOT override environment-specific settings
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - CUE tooling installed
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

# Load helper library
source "${SCRIPT_DIR}/lib/demo-helpers.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_APP="exampleApp"
DEMO_ENV="dev"
DEMO_KEY="demo-redis-url"
DEMO_VALUE="redis://redis.demo.svc:6379"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-A3: Environment-Specific ConfigMap Entry"

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# Step 1: Verify Prerequisites
# ---------------------------------------------------------------------------

demo_step 1 "Verify Prerequisites"

demo_action "Working in: $K8S_DEPLOYMENTS_DIR"

demo_action "Checking for environment branches..."
if ! git ls-remote --heads origin dev &>/dev/null; then
    demo_fail "Remote 'dev' branch does not exist"
    demo_info "Run setup-gitlab-env-branches.sh first"
    exit 1
fi
demo_verify "Remote 'dev' branch exists"

demo_action "Fetching latest from origin..."
git fetch origin --quiet

# ---------------------------------------------------------------------------
# Step 2: Switch to Dev Branch
# ---------------------------------------------------------------------------

demo_step 2 "Switch to Dev Environment Branch"

demo_action "Checking out dev branch..."
git checkout dev 2>/dev/null || git checkout -b dev origin/dev
git pull origin dev --quiet 2>/dev/null || true
demo_verify "Now on dev branch"

demo_action "Current env.cue structure:"
if [[ -f env.cue ]]; then
    head -30 env.cue | sed 's/^/    /'
else
    demo_fail "env.cue not found on dev branch"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Add Environment-Specific ConfigMap Entry
# ---------------------------------------------------------------------------

demo_step 3 "Add Environment-Specific ConfigMap Entry"

demo_info "Adding '${DEMO_KEY}' to dev environment only"
demo_info "This change will NOT propagate to stage or prod"

demo_add_configmap_entry "$DEMO_ENV" "$DEMO_APP" "$DEMO_KEY" "$DEMO_VALUE"

demo_verify "ConfigMap entry added to env.cue"

demo_action "Changed section in env.cue:"
grep -A5 "configMap:" env.cue | head -10 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 4: Regenerate Manifests
# ---------------------------------------------------------------------------

demo_step 4 "Regenerate Manifests"

demo_generate_manifests "$DEMO_ENV"
demo_verify "Manifests regenerated"

# ---------------------------------------------------------------------------
# Step 5: Verify Change in Manifest
# ---------------------------------------------------------------------------

demo_step 5 "Verify Change in Generated Manifest"

MANIFEST_FILE="manifests/example-app/example-app.yaml"

if [[ -f "$MANIFEST_FILE" ]]; then
    demo_action "Checking ConfigMap in manifest..."

    if grep -q "${DEMO_KEY}" "$MANIFEST_FILE"; then
        demo_verify "ConfigMap entry '${DEMO_KEY}' appears in manifest"

        demo_action "ConfigMap section from manifest:"
        grep -A15 "kind: ConfigMap" "$MANIFEST_FILE" | head -20 | sed 's/^/    /'
    else
        demo_fail "ConfigMap entry not found in manifest"
        exit 1
    fi
else
    demo_fail "Manifest file not found: $MANIFEST_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Show Environment Isolation
# ---------------------------------------------------------------------------

demo_step 6 "Demonstrate Environment Isolation"

demo_action "Saving dev manifest for comparison..."
DEV_MANIFEST_CONTENT=$(cat "$MANIFEST_FILE")

demo_action "Switching to stage branch to compare..."
git stash --quiet 2>/dev/null || true
git checkout stage --quiet 2>/dev/null || git checkout -b stage origin/stage --quiet

if [[ -f env.cue ]]; then
    demo_action "Checking stage's env.cue for '${DEMO_KEY}'..."
    if grep -q "${DEMO_KEY}" env.cue; then
        demo_warn "Key exists in stage (unexpected - this demo should be run fresh)"
    else
        demo_verify "Stage does NOT have '${DEMO_KEY}' - environment isolation confirmed"
    fi
fi

demo_action "Returning to dev branch..."
git checkout dev --quiet
git stash pop --quiet 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

echo ""
echo "  This demo showed that:"
echo ""
echo "  1. Adding '${DEMO_KEY}' to dev's env.cue"
echo "     → Appears in dev's generated ConfigMap"
echo ""
echo "  2. Stage's env.cue is unchanged"
echo "     → Environment-specific settings stay isolated"
echo ""
echo "  3. When changes are committed and pushed:"
echo "     → Pipeline regenerates dev manifests"
echo "     → ArgoCD deploys to dev namespace only"
echo "     → Stage and prod remain unaffected"
echo ""

# ---------------------------------------------------------------------------
# Step 8: Optional - Commit and Push
# ---------------------------------------------------------------------------

demo_step 8 "Commit Changes (Optional)"

echo ""
echo "  To complete this demo and trigger the pipeline:"
echo ""
echo "    git add env.cue manifests/"
echo "    git commit -m 'demo: add ${DEMO_KEY} to dev ConfigMap (UC-A3)'"
echo "    git push origin dev"
echo ""
echo "  Or to clean up without pushing:"
echo ""
echo "    git checkout -- env.cue manifests/"
echo ""

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 9 "Cleanup"

demo_action "Reverting changes to env.cue and manifests..."
git checkout -- env.cue manifests/ 2>/dev/null || true
demo_verify "Changes reverted"

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null || true

demo_complete
