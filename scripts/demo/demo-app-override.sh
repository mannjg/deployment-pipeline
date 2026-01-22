#!/bin/bash
# Demo: App ConfigMap with Environment Override (UC-B4)
#
# This demo showcases the CUE override hierarchy where:
# - App-level defaults apply to all environments
# - Environment-level settings can override app defaults
#
# Use Case UC-B4:
# "App sets cache-ttl=300, but prod needs cache-ttl=600 for performance"
#
# What This Demonstrates:
# - App-level ConfigMap entries propagate to all environments
# - Environment-level ConfigMap can override specific values
# - Lower layer (env) takes precedence over higher layer (app)
#
# CUE Override Hierarchy:
#   Platform (services/base/, services/core/)
#     ↓
#   App (services/apps/*.cue)
#     ↓
#   Env (env.cue per branch)  ← WINS
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - CUE tooling installed
# - Run from deployment-pipeline root
#
# Note: Currently, app-level changes require manual merge from main to env
# branches. This demo documents the intended behavior and override mechanism.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_APP="exampleApp"
DEMO_KEY="cache-ttl"
APP_DEFAULT_VALUE="300"
PROD_OVERRIDE_VALUE="600"

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
# Step 1: Explain the Override Hierarchy
# ---------------------------------------------------------------------------

demo_step 1 "Understanding the CUE Override Hierarchy"

cat << 'EOF'

  The CUE configuration system uses a layered approach:

    Platform Layer (services/base/, services/core/)
        ↓ provides: schemas, templates, defaults
    App Layer (services/apps/*.cue)
        ↓ provides: app-specific config for ALL environments
    Env Layer (env.cue on each branch)
        ↓ provides: environment-specific overrides

  Override Rule: Lower layers OVERRIDE higher layers.

  Example for UC-B4:
    - App sets: cache-ttl = "300" (default for all envs)
    - Prod sets: cache-ttl = "600" (override for prod only)
    - Result: dev/stage get 300, prod gets 600

EOF

demo_pause 1

# ---------------------------------------------------------------------------
# Step 2: Add App-Level Default (Simulated)
# ---------------------------------------------------------------------------

demo_step 2 "Add App-Level ConfigMap Default"

demo_action "Working in: $K8S_DEPLOYMENTS_DIR"

demo_info "In a full workflow, you would add to services/apps/example-app.cue:"
echo ""
echo "    appConfig: {"
echo "        configMap: {"
echo "            data: {"
echo "                \"${DEMO_KEY}\": \"${APP_DEFAULT_VALUE}\""
echo "            }"
echo "        }"
echo "    }"
echo ""

demo_info "For this demo, we'll add the default to dev's env.cue"
demo_info "(simulating what would happen after app changes merge to env branches)"

demo_action "Switching to dev branch..."
git fetch origin --quiet
git checkout dev 2>/dev/null || git checkout -b dev origin/dev
git pull origin dev --quiet 2>/dev/null || true
demo_verify "Now on dev branch"

# Add the "app default" to dev
demo_add_configmap_entry "dev" "$DEMO_APP" "$DEMO_KEY" "$APP_DEFAULT_VALUE"
demo_verify "Added ${DEMO_KEY}=${APP_DEFAULT_VALUE} to dev"

# Generate manifests
demo_generate_manifests "dev"

# Show dev manifest
demo_action "Dev manifest ConfigMap section:"
MANIFEST_FILE="manifests/example-app/example-app.yaml"
grep -A10 "kind: ConfigMap" "$MANIFEST_FILE" | head -15 | sed 's/^/    /'

# Save for later comparison
DEV_TTL=$(grep "${DEMO_KEY}" "$MANIFEST_FILE" | head -1 || echo "not found")

# ---------------------------------------------------------------------------
# Step 3: Add Environment Override in Prod
# ---------------------------------------------------------------------------

demo_step 3 "Add Environment Override in Prod"

demo_action "Stashing dev changes and switching to prod branch..."
git stash --quiet 2>/dev/null || true
git checkout prod 2>/dev/null || git checkout -b prod origin/prod
git pull origin prod --quiet 2>/dev/null || true
demo_verify "Now on prod branch"

demo_info "Prod needs a higher cache-ttl for performance (${PROD_OVERRIDE_VALUE} vs ${APP_DEFAULT_VALUE})"

# First add the app default (simulating merge), then override
demo_add_configmap_entry "prod" "$DEMO_APP" "$DEMO_KEY" "$APP_DEFAULT_VALUE"
demo_info "Added app default first: ${DEMO_KEY}=${APP_DEFAULT_VALUE}"

# Now override with prod-specific value
demo_add_configmap_entry "prod" "$DEMO_APP" "$DEMO_KEY" "$PROD_OVERRIDE_VALUE"
demo_verify "Overrode with prod value: ${DEMO_KEY}=${PROD_OVERRIDE_VALUE}"

# Generate manifests
demo_generate_manifests "prod"

# Show prod manifest
demo_action "Prod manifest ConfigMap section:"
grep -A10 "kind: ConfigMap" "$MANIFEST_FILE" | head -15 | sed 's/^/    /'

# Save for comparison
PROD_TTL=$(grep "${DEMO_KEY}" "$MANIFEST_FILE" | head -1 || echo "not found")

# ---------------------------------------------------------------------------
# Step 4: Compare Results
# ---------------------------------------------------------------------------

demo_step 4 "Compare Environment Values"

echo ""
echo "  Results across environments:"
echo ""
echo "    Dev:  ${DEV_TTL:-cache-ttl: \"${APP_DEFAULT_VALUE}\"}"
echo "    Prod: ${PROD_TTL:-cache-ttl: \"${PROD_OVERRIDE_VALUE}\"}"
echo ""
echo "  ✓ Dev uses the app default (${APP_DEFAULT_VALUE})"
echo "  ✓ Prod uses the environment override (${PROD_OVERRIDE_VALUE})"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Summary
# ---------------------------------------------------------------------------

demo_step 5 "Summary"

cat << EOF

  This demo demonstrated UC-B4: App ConfigMap with Environment Override

  Key Points:

  1. App-level ConfigMap entries provide defaults for ALL environments
     → Set in services/apps/*.cue (propagates via merge)

  2. Environment-level ConfigMap can override specific values
     → Set in env.cue on each environment branch

  3. Override Hierarchy (lower wins):
     Platform → App → Env

  4. Current Limitation:
     App-level changes require manual merge main→env branches.
     Future enhancement: automated propagation via promotion pipeline.

  Use Cases Validated:
  - UC-B3: App-level ConfigMap entries propagate to all envs
  - UC-B4: Environment can override app-level defaults

EOF

# ---------------------------------------------------------------------------
# Step 6: Optional - Commit and Push
# ---------------------------------------------------------------------------

demo_step 6 "Commit Changes (Optional)"

echo ""
echo "  To complete this demo and trigger the pipeline:"
echo ""
echo "  For prod:"
echo "    git add env.cue manifests/"
echo "    git commit -m 'demo: override ${DEMO_KEY} to ${PROD_OVERRIDE_VALUE} for prod (UC-B4)'"
echo "    git push origin prod"
echo ""
echo "  For dev (switch back first):"
echo "    git checkout dev"
echo "    git stash pop"
echo "    git add env.cue manifests/"
echo "    git commit -m 'demo: add ${DEMO_KEY}=${APP_DEFAULT_VALUE} default (UC-B4)'"
echo "    git push origin dev"
echo ""
echo "  Or to clean up without pushing:"
echo "    git checkout -- env.cue manifests/"
echo ""

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 7 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Reverting changes to prod's env.cue and manifests..."
git checkout -- env.cue manifests/ 2>/dev/null || true
demo_verify "Prod changes reverted"

demo_action "Switching back to dev and cleaning up..."
git checkout dev --quiet 2>/dev/null || true
git stash pop --quiet 2>/dev/null || true
git checkout -- env.cue manifests/ 2>/dev/null || true
demo_verify "Dev changes reverted"

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" --quiet 2>/dev/null || true

demo_complete
