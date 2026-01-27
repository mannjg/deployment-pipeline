# UC-B1: Add App Environment Variable - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a demo script that proves app-level environment variables propagate to ALL environments through the GitOps pipeline.

**Architecture:** Single-phase demo that adds a `FEATURE_FLAGS` env var to `services/apps/example-app.cue`, promotes it through dev→stage→prod, and verifies all environments have the env var in their deployments.

**Tech Stack:** Bash, CUE, kubectl, GitLab API (via gitlab-cli.sh), Jenkins, ArgoCD

---

## Task 1: Add Deployment Env Var Assertion

**Files:**
- Modify: `scripts/demo/lib/assertions.sh` (append after line 435)

**Step 1: Add assertion functions**

Add these functions to the end of `assertions.sh`:

```bash
# ============================================================================
# DEPLOYMENT ENVIRONMENT VARIABLE ASSERTIONS
# ============================================================================

# Assert a deployment container has a specific env var with expected value
# Usage: assert_deployment_env_var <namespace> <deployment_name> <env_name> <expected_value>
assert_deployment_env_var() {
    local namespace="$1"
    local deployment="$2"
    local env_name="$3"
    local expected_value="$4"

    local actual
    actual=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$env_name\")].value}" 2>/dev/null)

    if [[ "$actual" == "$expected_value" ]]; then
        demo_verify "Env var $env_name = '$expected_value' in $namespace/$deployment"
        return 0
    else
        demo_fail "Env var $env_name: expected '$expected_value', got '$actual' in $namespace/$deployment"
        return 1
    fi
}

# Assert a deployment container does NOT have a specific env var
# Usage: assert_deployment_env_var_absent <namespace> <deployment_name> <env_name>
assert_deployment_env_var_absent() {
    local namespace="$1"
    local deployment="$2"
    local env_name="$3"

    local actual
    actual=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$env_name\")].value}" 2>/dev/null)

    if [[ -z "$actual" ]]; then
        demo_verify "Env var $env_name absent (expected) in $namespace/$deployment"
        return 0
    else
        demo_fail "Env var $env_name exists but should not: '$actual' in $namespace/$deployment"
        return 1
    fi
}
```

**Step 2: Verify syntax**

Run: `bash -n scripts/demo/lib/assertions.sh`
Expected: No output (valid syntax)

**Step 3: Commit**

```bash
git add scripts/demo/lib/assertions.sh
git commit -m "feat(demo): add deployment env var assertions for UC-B1"
```

---

## Task 2: Create UC-B1 Demo Script

**Files:**
- Create: `scripts/demo/demo-uc-b1-app-env-var.sh`

**Step 1: Create the demo script**

```bash
#!/bin/bash
# Demo: Add App Environment Variable (UC-B1)
#
# This demo proves that app-level environment variables propagate to ALL
# environments through the GitOps pipeline.
#
# Use Case UC-B1:
# "As an app team, we need a new FEATURE_FLAGS env var in all environments"
#
# What This Demonstrates:
# - Changes to services/apps/example-app.cue flow through promotion chain
# - The appEnvVars array in CUE correctly generates container env vars
# - All environments (dev/stage/prod) receive the same app-level configuration
#
# Flow:
#   1. Add FEATURE_FLAGS env var to services/apps/example-app.cue
#   2. Create MR: feature → dev
#   3. Promote through dev → stage → prod
#   4. Verify all envs have FEATURE_FLAGS
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

DEMO_ENV_VAR_NAME="FEATURE_FLAGS"
DEMO_ENV_VAR_VALUE="dark-mode,new-checkout"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
APP_CUE_PATH="services/apps/example-app.cue"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-B1: Add App Environment Variable"

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

demo_info "Confirming '$DEMO_ENV_VAR_NAME' does not exist in any environment..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_deployment_env_var_absent "$env" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" || {
        demo_warn "Env var '$DEMO_ENV_VAR_NAME' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    }
done

demo_verify "Baseline confirmed: '$DEMO_ENV_VAR_NAME' absent from all environments"

# ---------------------------------------------------------------------------
# Step 3: Modify App CUE (add env var)
# ---------------------------------------------------------------------------

demo_step 3 "Add Environment Variable to App CUE"

demo_info "Adding '$DEMO_ENV_VAR_NAME: $DEMO_ENV_VAR_VALUE' to $APP_CUE_PATH"
demo_info "This will propagate to ALL environments (dev, stage, prod)"

# Check if entry already exists
if grep -q "\"$DEMO_ENV_VAR_NAME\"" "$APP_CUE_PATH"; then
    demo_warn "Env var '$DEMO_ENV_VAR_NAME' already exists in $APP_CUE_PATH"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Add env var entry to appEnvVars array
# Find the closing bracket of appEnvVars and insert before it
demo_action "Adding env var to appEnvVars array..."

# Use awk to insert before the closing bracket of appEnvVars
awk -v name="$DEMO_ENV_VAR_NAME" -v val="$DEMO_ENV_VAR_VALUE" '
/appEnvVars: \[/ { in_env_vars=1 }
in_env_vars && /^\t\]$/ {
    print "\t\t{"
    print "\t\t\tname:  \"" name "\""
    print "\t\t\tvalue: \"" val "\""
    print "\t\t},"
    in_env_vars=0
}
{print}
' "$APP_CUE_PATH" > "${APP_CUE_PATH}.tmp" && mv "${APP_CUE_PATH}.tmp" "$APP_CUE_PATH"

demo_verify "Added env var to $APP_CUE_PATH"

# Verify the change was actually made
if ! grep -q "\"$DEMO_ENV_VAR_NAME\"" "$APP_CUE_PATH"; then
    demo_fail "Failed to add env var - appEnvVars block may be malformed"
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
grep -A5 "$DEMO_ENV_VAR_NAME" "$APP_CUE_PATH" | head -10 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 4: Push Change via GitLab MR
# ---------------------------------------------------------------------------

demo_step 4 "Push Change via GitLab MR"

# Generate feature branch name
FEATURE_BRANCH="uc-b1-app-env-var-$(date +%s)"

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
    --message "feat: add $DEMO_ENV_VAR_NAME env var to example-app (UC-B1)" \
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
mr_iid=$(create_mr "$FEATURE_BRANCH" "dev" "UC-B1: Add $DEMO_ENV_VAR_NAME env var")

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
        assert_mr_contains_diff "$mr_iid" "$APP_CUE_PATH" "$DEMO_ENV_VAR_NAME" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_ENV_VAR_NAME" || exit 1
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
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_ENV_VAR_NAME" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state
    demo_action "Verifying env var in deployment..."
    assert_deployment_env_var "$env" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" "$DEMO_ENV_VAR_VALUE" || exit 1

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 6: Final Verification
# ---------------------------------------------------------------------------

demo_step 6 "Final Verification"

demo_info "Verifying env var propagated to ALL environments..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    assert_deployment_env_var "$env" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" "$DEMO_ENV_VAR_VALUE" || exit 1
done

demo_verify "VERIFIED: '$DEMO_ENV_VAR_NAME' present in all environments!"
demo_info "  - dev:   $DEMO_ENV_VAR_NAME = $DEMO_ENV_VAR_VALUE"
demo_info "  - stage: $DEMO_ENV_VAR_NAME = $DEMO_ENV_VAR_VALUE"
demo_info "  - prod:  $DEMO_ENV_VAR_NAME = $DEMO_ENV_VAR_VALUE"

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-B1: Add App Environment Variable

  What happened:
  1. Added '$DEMO_ENV_VAR_NAME: $DEMO_ENV_VAR_VALUE' to services/apps/example-app.cue
  2. Promoted through all environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  3. Verified all environments have the new env var

  Key Observations:
  - App-level env vars propagate to ALL environments
  - All changes go through MR with pipeline validation (GitOps)
  - Single change automatically flows through the entire promotion chain

  CUE Hierarchy Validated:
    App (services/apps/example-app.cue) → appEnvVars array
        ↓
    All Environments (dev, stage, prod) → same env var in deployment

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
```

**Step 2: Make executable**

Run: `chmod +x scripts/demo/demo-uc-b1-app-env-var.sh`

**Step 3: Verify syntax**

Run: `bash -n scripts/demo/demo-uc-b1-app-env-var.sh`
Expected: No output (valid syntax)

**Step 4: Commit**

```bash
git add scripts/demo/demo-uc-b1-app-env-var.sh
git commit -m "feat(demo): add UC-B1 app environment variable demo script"
```

---

## Task 3: Add UC-B1 to Test Suite

**Files:**
- Modify: `scripts/demo/run-all-demos.sh` (line ~34)

**Step 1: Add UC-B1 to DEMO_ORDER array**

Find this section (around line 28-40):
```bash
DEMO_ORDER=(
    # Core: App code lifecycle (SNAPSHOT → RC → Release)
    "validate-pipeline:../test/validate-pipeline.sh:App code lifecycle across dev/stage/prod"
    # Category A: Environment-Specific
    "UC-A3:demo-uc-a3-env-configmap.sh:Environment-specific ConfigMap (isolated)"
    # Category B: App-Level Cross-Environment
    "UC-B4:demo-uc-b4-app-override.sh:App ConfigMap with environment override"
```

Change to:
```bash
DEMO_ORDER=(
    # Core: App code lifecycle (SNAPSHOT → RC → Release)
    "validate-pipeline:../test/validate-pipeline.sh:App code lifecycle across dev/stage/prod"
    # Category A: Environment-Specific
    "UC-A3:demo-uc-a3-env-configmap.sh:Environment-specific ConfigMap (isolated)"
    # Category B: App-Level Cross-Environment
    "UC-B1:demo-uc-b1-app-env-var.sh:App env var propagates to all environments"
    "UC-B4:demo-uc-b4-app-override.sh:App ConfigMap with environment override"
```

**Step 2: Verify syntax**

Run: `bash -n scripts/demo/run-all-demos.sh`
Expected: No output (valid syntax)

**Step 3: Verify UC-B1 appears in list**

Run: `./scripts/demo/run-all-demos.sh --list`
Expected: UC-B1 appears between UC-A3 and UC-B4

**Step 4: Commit**

```bash
git add scripts/demo/run-all-demos.sh
git commit -m "feat(demo): add UC-B1 to test suite"
```

---

## Task 4: Update USE_CASES.md Status

**Files:**
- Modify: `docs/USE_CASES.md` (line ~395)

**Step 1: Update UC-B1 status row**

Find this line (around line 395):
```
| UC-B1 | Add app env var | 🔲 | 🔲 | 🔲 | — | |
```

Change to:
```
| UC-B1 | Add app env var | ✅ | ✅ | 🚧 | `uc-b1-app-env-var` | Full pipeline demo |
```

**Step 2: Add demo script reference**

Find the "Initial Demos (Phase 1)" section (around line 331) and add UC-B1:

After the UC-A3 and UC-B4 entries, the section should include:
```markdown
| [`scripts/demo/demo-uc-b1-app-env-var.sh`](../scripts/demo/demo-uc-b1-app-env-var.sh) | UC-B1 | App env vars propagate to all environments |
```

**Step 3: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: update UC-B1 status to in-progress"
```

---

## Task 5: Run UC-B1 Demo (Integration Test)

**Step 1: Reset demo state**

Run: `./scripts/03-pipelines/reset-demo-state.sh`
Expected: Clean state, no open MRs, no running builds

**Step 2: Run UC-B1 demo**

Run: `./scripts/demo/demo-uc-b1-app-env-var.sh`
Expected: Demo completes successfully with all verifications passing

**Step 3: If demo passes, update status**

Update `docs/USE_CASES.md` line ~395:
```
| UC-B1 | Add app env var | ✅ | ✅ | ✅ | `uc-b1-app-env-var` | Pipeline verified YYYY-MM-DD |
```

**Step 4: Commit status update**

```bash
git add docs/USE_CASES.md
git commit -m "docs: mark UC-B1 as pipeline verified"
```

---

## Task 6: Run Full Test Suite (Regression Test)

**Step 1: Run all demos**

Run: `./scripts/demo/run-all-demos.sh`
Expected: All tests pass (validate-pipeline, UC-A3, UC-B1, UC-B4, UC-C1, UC-C2, UC-C4, UC-C6)

**Step 2: Note status of UC-A3, UC-B4, UC-C2**

Record the pass/fail status of these three use cases for the final report.

**Step 3: If all pass, final commit**

```bash
git add -A
git commit -m "chore: UC-B1 implementation complete, all demos passing"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add deployment env var assertions | `scripts/demo/lib/assertions.sh` |
| 2 | Create UC-B1 demo script | `scripts/demo/demo-uc-b1-app-env-var.sh` |
| 3 | Add UC-B1 to test suite | `scripts/demo/run-all-demos.sh` |
| 4 | Update USE_CASES.md status | `docs/USE_CASES.md` |
| 5 | Run UC-B1 demo (integration test) | — |
| 6 | Run full test suite (regression test) | — |

**Total estimated tasks:** 6
**Key verification:** `./scripts/demo/run-all-demos.sh` passes with no regressions
