#!/usr/bin/env bash
# Demo: Add Pod Security Context (UC-C2)
#
# This demo showcases how platform-wide security requirements propagate
# to all apps in all environments through the CUE layering system.
#
# Use Case UC-C2:
# "As a security team, we require all pods to run as non-root"
#
# What This Demonstrates:
# - Changes to services/base/defaults.cue propagate to ALL apps in ALL environments
# - Security contexts are enforced at the pod level
# - Pipeline generates manifests with security context included
# - Promotion preserves the security requirement across environments
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Container images must support running as non-root (verified: UBI images use uid 185)
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
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C2: Add Pod Security Context"

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

demo_action "Verifying container runs as non-root (prerequisite)..."
dev_uid=$(kubectl exec -n "$(get_namespace dev)" deployment/${DEMO_APP} -- id -u 2>/dev/null || echo "unknown")
if [[ "$dev_uid" != "0" ]] && [[ "$dev_uid" != "unknown" ]]; then
    demo_verify "Container runs as non-root (uid=$dev_uid)"
else
    demo_fail "Container runs as root or cannot determine uid. runAsNonRoot would break deployment."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Make CUE Change (Base Layer)
# ---------------------------------------------------------------------------

demo_step 2 "Enable Pod Security Context in Base Layer"

demo_info "Enabling 'runAsNonRoot: true' in services/base/defaults.cue"

# Check current state
if grep -q "runAsNonRoot: true" services/base/defaults.cue 2>/dev/null && \
   ! grep -q "// runAsNonRoot: true" services/base/defaults.cue 2>/dev/null; then
    demo_warn "runAsNonRoot: true already enabled"
    demo_info "This demo will verify the current state"
fi

# Enable runAsNonRoot in #DefaultPodSecurityContext
# Change: "// runAsNonRoot: true" -> "runAsNonRoot: true"
sed -i 's|// runAsNonRoot: true|runAsNonRoot: true|' services/base/defaults.cue

# Verify the change was made
if grep -q "^[[:space:]]*runAsNonRoot: true" services/base/defaults.cue; then
    demo_verify "Enabled runAsNonRoot: true in #DefaultPodSecurityContext"
else
    demo_fail "Failed to enable runAsNonRoot in defaults.cue"
    exit 1
fi

# Verify CUE is valid
demo_action "Validating CUE configuration..."
if cue vet -c=false ./...; then
    demo_verify "CUE validation passed"
else
    demo_fail "CUE validation failed"
    exit 1
fi

demo_action "Changed section in services/base/defaults.cue:"
grep -A5 "#DefaultPodSecurityContext" services/base/defaults.cue | head -8 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 3: Push CUE Change via GitLab API
# ---------------------------------------------------------------------------

demo_step 3 "Push CUE Change to GitLab"

# Generate feature branch name
FEATURE_BRANCH="uc-c2-security-context-$(date +%s)"

GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing CUE change to GitLab..."
cat services/base/defaults.cue | "$GITLAB_CLI" file update p2c/k8s-deployments services/base/defaults.cue \
    --ref "$FEATURE_BRANCH" \
    --message "feat: enable runAsNonRoot security context (UC-C2)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Restore local changes
git checkout services/base/defaults.cue 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 4 "MR-Gated Promotion Through Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C2: Enable runAsNonRoot security context")

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "services/base/defaults.cue" "runAsNonRoot" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "runAsNonRoot" || exit 1

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
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "runAsNonRoot" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state - check pod security context
    demo_action "Verifying securityContext in K8s deployment..."
    run_as_non_root=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "")

    if [[ "$run_as_non_root" == "true" ]]; then
        demo_verify "securityContext.runAsNonRoot = true in $env"
    else
        demo_fail "securityContext.runAsNonRoot not set to true in $env (got: '$run_as_non_root')"
        exit 1
    fi

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 5: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 5 "Cross-Environment Verification"

demo_info "Verifying securityContext present in ALL environments..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."

    # Check deployment spec
    run_as_non_root=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "")

    if [[ "$run_as_non_root" == "true" ]]; then
        demo_verify "$env: securityContext.runAsNonRoot = true"
    else
        demo_fail "$env: securityContext.runAsNonRoot not true (got: '$run_as_non_root')"
        exit 1
    fi

    # Verify pod is actually running (security context didn't break it)
    pod_status=$(kubectl get pods -n "$(get_namespace "$env")" -l app="$DEMO_APP" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$pod_status" == "Running" ]]; then
        demo_verify "$env: Pod is Running with security context enforced"
    else
        demo_fail "$env: Pod not running (status: $pod_status)"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------

demo_step 6 "Summary"

cat << EOF

  This demo validated UC-C2: Add Pod Security Context

  What happened:
  1. Enabled 'runAsNonRoot: true' in services/base/defaults.cue
  2. Pushed CUE change only (no manual manifest generation)
  3. Promoted through environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  4. For each environment:
     - Pipeline generated manifests with securityContext included
     - Merged MR after pipeline passed
     - ArgoCD synced the change
     - Verified securityContext.runAsNonRoot = true in deployment
     - Verified pod still runs correctly (container supports non-root)

  Key Observations:
  - Security requirements propagate to ALL apps in ALL environments
  - Platform team can enforce security policies centrally
  - No per-app or per-environment changes needed
  - Pod Security Standards compatibility achieved

  Security Context Applied:
  - spec.template.spec.securityContext.runAsNonRoot: true
  - Container image must support non-root (UBI images use uid 185)

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 7 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Restoring local changes if any..."
git checkout . 2>/dev/null || true

demo_info "GitLab feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "To delete: ./scripts/04-operations/gitlab-cli.sh branch delete p2c/k8s-deployments $FEATURE_BRANCH"

demo_complete
