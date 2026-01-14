#!/bin/bash
# Pipeline Validation Script
# Proves the CI/CD pipeline works: commit → build → deploy to dev
#
# Usage: ./validate-pipeline.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - config/validate-pipeline.env with credentials
#   - curl, jq, git installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/config/validate-pipeline.env" ]]; then
    source "$SCRIPT_DIR/config/validate-pipeline.env"
elif [[ -f "$SCRIPT_DIR/config/validate-pipeline.env.template" ]]; then
    echo "[✗] Config file not found"
    echo "    Copy config/validate-pipeline.env.template to config/validate-pipeline.env"
    echo "    and fill in your credentials"
    exit 1
fi

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
    echo "=== Pipeline Validation ==="
    echo ""
    log_step "Running pre-flight checks..."

    local failed=0

    # Check kubectl
    if kubectl cluster-info &>/dev/null; then
        log_info "kubectl: connected to cluster"
    else
        log_fail "kubectl: cannot connect to cluster"
        failed=1
    fi

    # Check GitLab
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_fail "GitLab: GITLAB_TOKEN not set"
        failed=1
    elif curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/user" &>/dev/null; then
        log_info "GitLab: $GITLAB_URL (reachable)"
    else
        log_fail "GitLab: $GITLAB_URL (not reachable or token invalid)"
        failed=1
    fi

    # Check Jenkins
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        log_fail "Jenkins: JENKINS_TOKEN not set"
        failed=1
    elif curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/api/json" &>/dev/null; then
        log_info "Jenkins: $JENKINS_URL (reachable)"
    else
        log_fail "Jenkins: $JENKINS_URL (not reachable or credentials invalid)"
        failed=1
    fi

    # Check ArgoCD application exists
    if kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_info "ArgoCD: $ARGOCD_APP_NAME application exists"
    else
        log_fail "ArgoCD: $ARGOCD_APP_NAME application not found in $ARGOCD_NAMESPACE namespace"
        failed=1
    fi

    if [[ $failed -eq 1 ]]; then
        echo ""
        log_fail "Pre-flight checks failed"
        exit 1
    fi

    log_pass "Pre-flight checks passed"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local start_time=$(date +%s)

    preflight_checks

    # TODO: Implement remaining steps
    echo "Pre-flight checks complete. Implementation continues in next tasks."
}

main "$@"
