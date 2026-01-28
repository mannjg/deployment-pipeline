# UC-B5 & UC-B6: App-Level Override Demos Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement two demo scripts that validate app-level configuration can be overridden at the environment level.

**Architecture:** Both demos follow the UC-B4 two-phase pattern: (1) add app-level default that propagates to all environments, (2) add environment override that only affects one environment. Each demo creates GitLab MRs, waits for Jenkins CI, and verifies K8s state.

**Tech Stack:** Bash scripts, CUE configuration, GitLab API (via gitlab-cli.sh), kubectl assertions

---

## Task 1: Add Probe Timeout Assertion Helper

**Files:**
- Modify: `scripts/demo/lib/assertions.sh`

**Step 1: Add readiness probe timeout assertion**

Add this function at the end of the file (before any closing comments):

```bash
# ============================================================================
# PROBE ASSERTIONS
# ============================================================================

# Assert readiness probe timeoutSeconds equals expected value
# Usage: assert_readiness_probe_timeout <namespace> <deployment_name> <expected_timeout>
assert_readiness_probe_timeout() {
    local namespace="$1"
    local deployment="$2"
    local expected="$3"

    assert_field_equals "$namespace" "deployment" "$deployment" \
        "{.spec.template.spec.containers[0].readinessProbe.timeoutSeconds}" "$expected"
}
```

**Step 2: Verify syntax**

Run: `bash -n scripts/demo/lib/assertions.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/demo/lib/assertions.sh
git commit -m "feat(demo): add readiness probe timeout assertion helper"
```

---

## Task 2: Add Last Env Var Value Assertion Helper

**Files:**
- Modify: `scripts/demo/lib/assertions.sh`

**Step 1: Add env var "last value" assertion**

This assertion finds the LAST occurrence of an env var (for K8s "last wins" behavior).
Add after the probe assertions:

```bash
# ============================================================================
# ENV VAR "LAST WINS" ASSERTIONS
# ============================================================================

# Assert the LAST occurrence of an env var equals expected value
# Kubernetes uses "last wins" when duplicate env vars exist
# Usage: assert_deployment_env_var_last <namespace> <deployment_name> <env_name> <expected_value>
assert_deployment_env_var_last() {
    local namespace="$1"
    local deployment="$2"
    local env_name="$3"
    local expected_value="$4"

    # Get all env vars as JSON, find all matching names, take the last one
    local actual
    actual=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$env_name\")].value}" 2>/dev/null | \
        awk '{print $NF}')  # Take last space-separated value

    if [[ "$actual" == "$expected_value" ]]; then
        demo_verify "Env var $env_name (last value) = '$expected_value' in $namespace/$deployment"
        return 0
    else
        demo_fail "Env var $env_name (last value): expected '$expected_value', got '$actual' in $namespace/$deployment"
        return 1
    fi
}

# Assert that an env var appears exactly N times (for verifying concatenation behavior)
# Usage: assert_deployment_env_var_count <namespace> <deployment_name> <env_name> <expected_count>
assert_deployment_env_var_count() {
    local namespace="$1"
    local deployment="$2"
    local env_name="$3"
    local expected_count="$4"

    local actual_count
    actual_count=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath="{.spec.template.spec.containers[0].env[*].name}" 2>/dev/null | \
        tr ' ' '\n' | grep -c "^${env_name}$" || echo "0")

    if [[ "$actual_count" == "$expected_count" ]]; then
        demo_verify "Env var $env_name appears $expected_count time(s) in $namespace/$deployment"
        return 0
    else
        demo_fail "Env var $env_name count: expected $expected_count, got $actual_count in $namespace/$deployment"
        return 1
    fi
}
```

**Step 2: Verify syntax**

Run: `bash -n scripts/demo/lib/assertions.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/demo/lib/assertions.sh
git commit -m "feat(demo): add env var last-wins and count assertion helpers"
```

---

## Task 3: Create UC-B5 Demo Script (Probe Override)

**Files:**
- Create: `scripts/demo/demo-uc-b5-probe-override.sh`

**Step 1: Create the demo script**

Copy structure from UC-B4 and modify for probe timeoutSeconds. Key differences:
- DEMO_KEY: Not applicable (we're modifying probe, not ConfigMap)
- APP_DEFAULT_VALUE: `10` (timeoutSeconds)
- PROD_OVERRIDE_VALUE: `30` (timeoutSeconds)
- Phase 1: Add `appConfig.deployment.readinessProbe.timeoutSeconds: int | *10` to example-app.cue
- Phase 2: Add `readinessProbe.timeoutSeconds: 30` to prod's env.cue
- Assertions: Use `assert_readiness_probe_timeout` instead of `assert_configmap_entry`

```bash
#!/bin/bash
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
    if kubectl get deployment "$DEMO_APP" -n "$env" &>/dev/null; then
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
demo_info "(Default from platform is 3s - we'll override to 10s at app level)"

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    current=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.timeoutSeconds}' 2>/dev/null || echo "unset")
    demo_info "$env: timeoutSeconds = $current"
done

demo_verify "Baseline state captured"

# ============================================================================
# PHASE 1: Add App-Level Default (propagates to all environments)
# ============================================================================

demo_step 3 "PHASE 1: Add App-Level Default"

demo_info "Adding readinessProbe.timeoutSeconds=$APP_DEFAULT_TIMEOUT to services/apps/example-app.cue"
demo_info "This will propagate to ALL environments (dev, stage, prod)"

# Edit LOCAL file directly (same pattern as UC-B4)
APP_CUE_PATH="services/apps/example-app.cue"

# Check if readinessProbe already exists in app config
if grep -q "readinessProbe" "$APP_CUE_PATH"; then
    demo_warn "readinessProbe already exists in $APP_CUE_PATH"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Add readinessProbe to appConfig block
# The appConfig block is currently empty, so we add after "appConfig: {"
demo_action "Adding readinessProbe to app CUE..."

# Use awk for reliable multi-line insertion after "appConfig: {"
# IMPORTANT: Use CUE default syntax (int | *10) so env.cue can override
awk -v timeout="$APP_DEFAULT_TIMEOUT" '
/appConfig: \{/ {
    print
    print "\t\tdeployment: {"
    print "\t\t\treadinessProbe: {"
    print "\t\t\t\ttimeoutSeconds: int | *" timeout
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
    assert_readiness_probe_timeout "$env" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1

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
    assert_readiness_probe_timeout "$env" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1
done

demo_verify "CHECKPOINT: All environments have readinessProbe.timeoutSeconds=$APP_DEFAULT_TIMEOUT"
demo_info "This proves app-level probe changes propagate correctly."
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
BEGIN { in_prod=0; in_app=0; in_deployment=0; in_readiness=0 }
/^prod:/ { in_prod=1 }
in_prod && /exampleApp:/ { in_app=1 }
in_app && /deployment: \{/ { in_deployment=1 }
in_deployment && /readinessProbe: \{/ { in_readiness=1 }
in_readiness && /periodSeconds:/ {
    print
    print "\t\t\t\ttimeoutSeconds: " timeout
    in_readiness=0  # Only add once
    next
}
# Reset when we exit the prod block
/^[a-z]+:/ && !/^prod:/ { in_prod=0; in_app=0; in_deployment=0; in_readiness=0 }
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
assert_readiness_probe_timeout "dev" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1

# Stage should still have app default
demo_action "Checking stage..."
assert_readiness_probe_timeout "stage" "$DEMO_APP" "$APP_DEFAULT_TIMEOUT" || exit 1

# Prod should have the override
demo_action "Checking prod..."
assert_readiness_probe_timeout "prod" "$DEMO_APP" "$PROD_OVERRIDE_TIMEOUT" || exit 1

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

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"
demo_info "Override branch '$OVERRIDE_BRANCH' left in GitLab for reference"

demo_complete
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/demo/demo-uc-b5-probe-override.sh && bash -n scripts/demo/demo-uc-b5-probe-override.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/demo/demo-uc-b5-probe-override.sh
git commit -m "feat(demo): add UC-B5 probe override demo script"
```

---

## Task 4: Create UC-B6 Demo Script (Env Var Override)

**Files:**
- Create: `scripts/demo/demo-uc-b6-env-var-override.sh`

**Step 1: Create the demo script**

Key differences from UC-B5:
- APP_DEFAULT_VALUE: `INFO` (LOG_LEVEL)
- DEV_OVERRIDE_VALUE: `DEBUG` (LOG_LEVEL)
- Phase 1: Add LOG_LEVEL=INFO to appEnvVars in example-app.cue
- Phase 2: Add LOG_LEVEL=DEBUG to dev's additionalEnv (not prod)
- Assertions: Use `assert_deployment_env_var_last` to verify K8s "last wins" behavior
- Also verify both env vars appear (concatenation, not replacement)

```bash
#!/bin/bash
# Demo: App Env Var with Environment Override (UC-B6)
#
# This demo showcases the CUE override hierarchy for environment variables:
# - App-level env vars (appEnvVars) propagate to ALL environments
# - Environment-level env vars (additionalEnv) are concatenated
# - Kubernetes uses "last wins" when duplicate env vars exist
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
#   1. Add LOG_LEVEL=INFO to appEnvVars in services/apps/example-app.cue
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
#   Current implementation concatenates env vars rather than merging by name.
#   This means both LOG_LEVEL=INFO and LOG_LEVEL=DEBUG appear in the manifest.
#   Kubernetes uses the last value, so additionalEnv wins.
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
    if kubectl get deployment "$DEMO_APP" -n "$env" &>/dev/null; then
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
    current=$(kubectl get deployment "$DEMO_APP" -n "$env" \
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

demo_info "Adding $ENV_VAR_NAME=$APP_DEFAULT_VALUE to appEnvVars in services/apps/example-app.cue"
demo_info "This will propagate to ALL environments (dev, stage, prod)"

# Edit LOCAL file directly
APP_CUE_PATH="services/apps/example-app.cue"

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
    assert_deployment_env_var "$env" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1

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
    assert_deployment_env_var "$env" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1
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

# Check if override already exists in additionalEnv
if echo "$DEV_ENV_CUE" | grep -A2 "additionalEnv" | grep -q "$ENV_VAR_NAME"; then
    demo_warn "$ENV_VAR_NAME already exists in dev's additionalEnv"
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
# Step 8: Final Verification - Override Only Affects Dev
# ---------------------------------------------------------------------------

demo_step 8 "Final Verification - Override Only Affects Dev"

demo_info "Verifying final state across all environments..."

# Dev should have DEBUG (last wins due to additionalEnv coming after appEnvVars)
demo_action "Checking dev (should have override)..."
assert_deployment_env_var_last "dev" "$DEMO_APP" "$ENV_VAR_NAME" "$DEV_OVERRIDE_VALUE" || exit 1

# Verify concatenation behavior - both values should appear in dev
demo_action "Verifying concatenation behavior in dev..."
demo_info "Both $ENV_VAR_NAME=$APP_DEFAULT_VALUE (from appEnvVars) and"
demo_info "$ENV_VAR_NAME=$DEV_OVERRIDE_VALUE (from additionalEnv) should appear in manifest."
assert_deployment_env_var_count "dev" "$DEMO_APP" "$ENV_VAR_NAME" "2" || exit 1

# Stage should still have only app default (single occurrence)
demo_action "Checking stage (should have app default only)..."
assert_deployment_env_var "stage" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1
assert_deployment_env_var_count "stage" "$DEMO_APP" "$ENV_VAR_NAME" "1" || exit 1

# Prod should still have only app default (single occurrence)
demo_action "Checking prod (should have app default only)..."
assert_deployment_env_var "prod" "$DEMO_APP" "$ENV_VAR_NAME" "$APP_DEFAULT_VALUE" || exit 1
assert_deployment_env_var_count "prod" "$DEMO_APP" "$ENV_VAR_NAME" "1" || exit 1

demo_verify "VERIFIED: Override hierarchy works correctly!"
demo_info "  - dev:   $ENV_VAR_NAME = $DEV_OVERRIDE_VALUE (additionalEnv override, last wins)"
demo_info "          (Note: both INFO and DEBUG appear in manifest; K8s uses last)"
demo_info "  - stage: $ENV_VAR_NAME = $APP_DEFAULT_VALUE (app default only)"
demo_info "  - prod:  $ENV_VAR_NAME = $APP_DEFAULT_VALUE (app default only)"

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-B6: App Env Var with Environment Override

  What happened:

  PHASE 1: App-Level Default
  1. Added $ENV_VAR_NAME=$APP_DEFAULT_VALUE to appEnvVars in services/apps/example-app.cue
  2. Promoted through all environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  3. CHECKPOINT: Verified all environments had $ENV_VAR_NAME=$APP_DEFAULT_VALUE

  PHASE 2: Dev Override
  4. Added $ENV_VAR_NAME=$DEV_OVERRIDE_VALUE to dev's additionalEnv via MR
  5. Verified final state:
     - dev: override ($DEV_OVERRIDE_VALUE) - both values in manifest, K8s uses last
     - stage/prod: app default ($APP_DEFAULT_VALUE) only

  Key Observations:
  - App-level env vars (appEnvVars) propagate to all environments
  - Environment-level env vars (additionalEnv) are CONCATENATED, not merged by name
  - Both values appear in the manifest when overridden
  - Kubernetes uses "last wins" - additionalEnv comes after appEnvVars, so it wins
  - Override only affects target environment (isolation)
  - All changes go through MR with pipeline validation (GitOps)

  CUE Override Hierarchy Validated:
    App (appEnvVars) → $ENV_VAR_NAME=$APP_DEFAULT_VALUE
        +
    Env (additionalEnv) → $ENV_VAR_NAME=$DEV_OVERRIDE_VALUE (concatenated, last wins)

  Design Note:
    Current implementation uses list concatenation for env vars.
    A future enhancement could merge by name to avoid duplicate entries.

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
```

**Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/demo/demo-uc-b6-env-var-override.sh && bash -n scripts/demo/demo-uc-b6-env-var-override.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/demo/demo-uc-b6-env-var-override.sh
git commit -m "feat(demo): add UC-B6 env var override demo script"
```

---

## Task 5: Add Demo Scripts to run-all-demos.sh

**Files:**
- Modify: `scripts/demo/run-all-demos.sh`

**Step 1: Add UC-B5 and UC-B6 to DEMO_ORDER array**

Find the Category B section in DEMO_ORDER and add after UC-B4:

```bash
    "UC-B5:demo-uc-b5-probe-override.sh:App probe with environment override"
    "UC-B6:demo-uc-b6-env-var-override.sh:App env var with environment override"
```

The full Category B section should be:
```bash
    # Category B: App-Level Cross-Environment
    "UC-B1:demo-uc-b1-app-env-var.sh:App env var propagates to all environments"
    "UC-B2:demo-uc-b2-app-annotation.sh:App annotation propagates to all environments"
    "UC-B3:demo-uc-b3-app-configmap.sh:App ConfigMap entry propagates to all environments"
    "UC-B4:demo-uc-b4-app-override.sh:App ConfigMap with environment override"
    "UC-B5:demo-uc-b5-probe-override.sh:App probe with environment override"
    "UC-B6:demo-uc-b6-env-var-override.sh:App env var with environment override"
```

**Step 2: Verify syntax**

Run: `bash -n scripts/demo/run-all-demos.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/demo/run-all-demos.sh
git commit -m "feat(demo): add UC-B5 and UC-B6 to demo suite"
```

---

## Task 6: Update USE_CASES.md Implementation Status

**Files:**
- Modify: `docs/USE_CASES.md`

**Step 1: Update UC-B5 row in Implementation Status table**

Change from:
```markdown
| UC-B5 | App probe with env override | 🔲 | 🔲 | 🔲 | — | |
```

To:
```markdown
| UC-B5 | App probe with env override | ✅ | ✅ | 🔲 | `uc-b5-probe-override` | Ready for pipeline verification |
```

**Step 2: Update UC-B6 row in Implementation Status table**

Change from:
```markdown
| UC-B6 | App env var with env override | 🔲 | 🔲 | 🔲 | — | |
```

To:
```markdown
| UC-B6 | App env var with env override | ✅ | ✅ | 🔲 | `uc-b6-env-var-override` | Ready for pipeline verification; documents concat vs merge |
```

**Step 3: Add demo script references in Demo Scripts section**

Add to the "Initial Demos (Phase 1)" table:
```markdown
| [`scripts/demo/demo-uc-b5-probe-override.sh`](../scripts/demo/demo-uc-b5-probe-override.sh) | UC-B5 | App probe settings propagate; environment can override timeoutSeconds |
| [`scripts/demo/demo-uc-b6-env-var-override.sh`](../scripts/demo/demo-uc-b6-env-var-override.sh) | UC-B6 | App env vars propagate; environment override via additionalEnv (last wins) |
```

**Step 4: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: update UC-B5 and UC-B6 implementation status"
```

---

## Task 7: Run Single Demo Test (UC-B5)

**Step 1: Reset demo state**

Run: `./scripts/03-pipelines/reset-demo-state.sh`
Expected: Clean state, no open MRs, no stale branches

**Step 2: Run UC-B5 demo**

Run: `./scripts/demo/demo-uc-b5-probe-override.sh`
Expected: All steps pass, final verification shows:
- dev/stage: timeoutSeconds=10
- prod: timeoutSeconds=30

**Step 3: Verify no regressions by checking demo output**

Look for: "Demo Complete!" at the end

---

## Task 8: Run Single Demo Test (UC-B6)

**Step 1: Reset demo state**

Run: `./scripts/03-pipelines/reset-demo-state.sh`
Expected: Clean state, no open MRs, no stale branches

**Step 2: Run UC-B6 demo**

Run: `./scripts/demo/demo-uc-b6-env-var-override.sh`
Expected: All steps pass, final verification shows:
- dev: LOG_LEVEL=DEBUG (2 occurrences, last wins)
- stage/prod: LOG_LEVEL=INFO (1 occurrence each)

**Step 3: Verify no regressions by checking demo output**

Look for: "Demo Complete!" at the end

---

## Task 9: Update USE_CASES.md with Pipeline Verified Status

**Files:**
- Modify: `docs/USE_CASES.md`

**Step 1: After successful UC-B5 run, update status**

Change UC-B5 from:
```markdown
| UC-B5 | App probe with env override | ✅ | ✅ | 🔲 | `uc-b5-probe-override` | Ready for pipeline verification |
```

To:
```markdown
| UC-B5 | App probe with env override | ✅ | ✅ | ✅ | `uc-b5-probe-override` | Pipeline verified YYYY-MM-DD |
```

**Step 2: After successful UC-B6 run, update status**

Change UC-B6 from:
```markdown
| UC-B6 | App env var with env override | ✅ | ✅ | 🔲 | `uc-b6-env-var-override` | Ready for pipeline verification; documents concat vs merge |
```

To:
```markdown
| UC-B6 | App env var with env override | ✅ | ✅ | ✅ | `uc-b6-env-var-override` | Pipeline verified YYYY-MM-DD; documents concat vs merge |
```

**Step 3: Also update UC-A1 and UC-A2 if they passed in previous session**

(User mentioned these passed but weren't marked)

**Step 4: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: mark UC-B5, UC-B6 (and UC-A1, UC-A2) as pipeline verified"
```

---

## Task 10: Run Full Demo Suite

**Step 1: Run the full suite**

Run: `./scripts/demo/run-all-demos.sh`
Expected: All demos pass (validate-pipeline, UC-A1 through UC-C6)

**Step 2: Review summary output**

Look for: "ALL VERIFICATIONS PASSED" at the end

**Step 3: Final commit with all verification**

```bash
git add -A
git commit -m "chore: all use case demos verified - UC-B5 and UC-B6 complete"
```

---

## Summary

| Task | Description | Est. Effort |
|------|-------------|-------------|
| 1 | Add probe timeout assertion | Small |
| 2 | Add env var last-wins assertions | Small |
| 3 | Create UC-B5 demo script | Medium |
| 4 | Create UC-B6 demo script | Medium |
| 5 | Add to run-all-demos.sh | Small |
| 6 | Update USE_CASES.md status | Small |
| 7 | Test UC-B5 | Medium (pipeline wait) |
| 8 | Test UC-B6 | Medium (pipeline wait) |
| 9 | Update verified status | Small |
| 10 | Run full suite | Large (all demos) |

**Dependencies:**
- Tasks 1-2: Independent, can be done in parallel
- Tasks 3-4: Depend on Tasks 1-2
- Task 5: Depends on Tasks 3-4
- Task 6: Can be done after Tasks 3-4
- Tasks 7-8: Depend on Tasks 1-5
- Task 9: Depends on Tasks 7-8
- Task 10: Depends on all previous tasks
