#!/bin/bash
# K8s-Deployments Pipeline Validation Script
# Validates CUE configuration changes flow correctly through the pipeline
#
# Usage: ./validate-k8s-deployments-pipeline.sh [--test=<name>]
#
# Options:
#   --test=all    Run all tests (default)
#   --test=L2     Run L2 tests only (default changes)
#   --test=L5     Run L5 tests only (app definition changes)
#   --test=L6     Run L6 tests only (environment config changes)
#   --test=T1     Run specific test by ID
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - curl, jq, git, yq, cue installed
#   - config/infra.env with infrastructure URLs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Load infrastructure config via lib/infra.sh
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

# Load test library
if [[ -f "$SCRIPT_DIR/lib/k8s-deployments-tests.sh" ]]; then
    source "$SCRIPT_DIR/lib/k8s-deployments-tests.sh"
else
    echo "[✗] Test library not found: lib/k8s-deployments-tests.sh"
    exit 1
fi

# Map infra.env to script variables
GITLAB_URL="${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set}"
JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"
K8S_DEPLOYMENTS_REPO_URL="${GITLAB_URL}/${K8S_DEPLOYMENTS_REPO_PATH:?K8S_DEPLOYMENTS_REPO_PATH not set}.git"

# Timeouts
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-300}"
K8S_DEPLOYMENTS_BUILD_TIMEOUT="${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-300}"

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
preflight_checks() {
    echo "=== K8s-Deployments Pipeline Validation ==="
    echo ""
    log_step "Running pre-flight checks..."

    local failed=0

    # Check required tools
    for tool in kubectl curl jq git yq cue; do
        if command -v "${tool}" &>/dev/null; then
            log_info "${tool}: $(command -v ${tool})"
        else
            log_fail "${tool}: not found"
            failed=1
        fi
    done

    # Check kubectl access
    if kubectl cluster-info &>/dev/null; then
        log_info "kubectl: connected to cluster"
    else
        log_fail "kubectl: cannot connect to cluster"
        failed=1
    fi

    # Load credentials from K8s secrets
    log_info "Loading credentials..."
    load_credentials_from_secrets

    # Check GitLab access
    if [[ -n "${GITLAB_TOKEN:-}" ]]; then
        local gitlab_user
        gitlab_user=$(curl -sfkk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/user" | jq -r '.username // empty')
        if [[ -n "$gitlab_user" ]]; then
            log_info "GitLab: authenticated as '$gitlab_user'"
            # Get project ID for API calls
            K8S_DEPLOYMENTS_PROJECT_ID=$(curl -sfk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$(echo ${K8S_DEPLOYMENTS_REPO_PATH} | sed 's/\//%2F/g')" | jq -r '.id')
            log_info "GitLab project ID: ${K8S_DEPLOYMENTS_PROJECT_ID}"
        else
            log_fail "GitLab: authentication failed"
            failed=1
        fi
    else
        log_fail "GitLab: GITLAB_TOKEN not set"
        failed=1
    fi

    # Check Jenkins access
    if [[ -n "${JENKINS_TOKEN:-}" ]]; then
        local jenkins_mode
        jenkins_mode=$(curl -sfk -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/api/json" | jq -r '.mode // empty')
        if [[ -n "$jenkins_mode" ]]; then
            log_info "Jenkins: authenticated as '$JENKINS_USER'"
        else
            log_fail "Jenkins: authentication failed"
            failed=1
        fi
    else
        log_fail "Jenkins: JENKINS_TOKEN not set"
        failed=1
    fi

    # Check ArgoCD applications
    for env in dev stage prod; do
        local app_name="example-app-${env}"
        if kubectl get application "${app_name}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
            log_info "ArgoCD: ${app_name} exists"
        else
            log_fail "ArgoCD: ${app_name} not found"
            failed=1
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_fail "Pre-flight checks failed"
        return 1
    fi

    log_pass "Pre-flight checks passed"
    echo ""
    return 0
}

# Load credentials from K8s secrets (same as validate-pipeline.sh)
load_credentials_from_secrets() {
    if [[ -z "${JENKINS_USER:-}" ]]; then
        JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi
}

# -----------------------------------------------------------------------------
# Test Runner
# -----------------------------------------------------------------------------
run_tests() {
    local test_filter="${1:-all}"
    local passed=0
    local failed=0
    local skipped=0

    echo "=== Running Tests (filter: ${test_filter}) ==="
    echo ""

    # Setup git credentials for GitLab access
    setup_git_credentials

    # Define test matrix
    declare -A tests=(
        ["T1"]="test_L2_default_resource_limit:L2:Default resource limit"
        ["T2"]="test_L5_app_env_var:L5:App environment variable"
        ["T3"]="test_L6_annotation:L6:Deployment annotation"
        ["T4"]="test_L6_replica_promotion:L6:Replica count with promotion"
        ["T5"]="test_L6_configmap_value:L6:ConfigMap value"
    )

    for test_id in "${!tests[@]}"; do
        IFS=':' read -r func layer desc <<< "${tests[$test_id]}"

        # Check filter
        case "${test_filter}" in
            all)
                ;;
            L2|L5|L6)
                if [[ "${layer}" != "${test_filter}" ]]; then
                    log_info "Skipping ${test_id} (layer ${layer})"
                    ((skipped++)) || true
                    continue
                fi
                ;;
            T*)
                if [[ "${test_id}" != "${test_filter}" ]]; then
                    log_info "Skipping ${test_id}"
                    ((skipped++)) || true
                    continue
                fi
                ;;
        esac

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "${test_id}: ${desc} (${layer})"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if ${func}; then
            ((passed++)) || true
        else
            ((failed++)) || true
        fi

        echo ""
    done

    # Cleanup git credentials
    cleanup_git_credentials

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Passed:  ${passed}"
    echo "  Failed:  ${failed}"
    echo "  Skipped: ${skipped}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${failed} -gt 0 ]]; then
        log_fail "Some tests failed"
        return 1
    fi

    log_pass "All tests passed"
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local test_filter="all"

    # Parse arguments
    for arg in "$@"; do
        case "${arg}" in
            --test=*)
                test_filter="${arg#*=}"
                ;;
            -h|--help)
                echo "Usage: $0 [--test=<filter>]"
                echo ""
                echo "Filters: all, L2, L5, L6, T1, T2, T3, T4, T5"
                exit 0
                ;;
            *)
                echo "Unknown argument: ${arg}"
                exit 1
                ;;
        esac
    done

    # Run pre-flight checks
    if ! preflight_checks; then
        exit 1
    fi

    # Run tests
    if ! run_tests "${test_filter}"; then
        exit 1
    fi

    exit 0
}

main "$@"
