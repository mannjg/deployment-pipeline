#!/bin/bash
# Infrastructure Health Check Script
# Quick verification that all pipeline components are ready
#
# Usage: ./check-health.sh
#
# Exit codes:
#   0 - All components healthy
#   1 - One or more components unhealthy

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Load infrastructure config via lib/infra.sh
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

# Load credentials from K8s secrets
load_credentials() {
    JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
}

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

log_pass()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_fail()  { echo -e "${RED}[✗]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_info()  { echo "    $*"; }

# Track failures
FAILED=0

check_pass() {
    log_pass "$1"
}

check_fail() {
    log_fail "$1"
    FAILED=1
}

check_warn() {
    log_warn "$1"
}

# -----------------------------------------------------------------------------
# Health Checks
# -----------------------------------------------------------------------------

check_kubernetes() {
    echo ""
    echo "=== Kubernetes ==="

    if kubectl cluster-info &>/dev/null; then
        local context=$(kubectl config current-context 2>/dev/null)
        check_pass "Cluster connected (context: $context)"
    else
        check_fail "Cannot connect to cluster"
        return 1
    fi

    # Check core namespaces exist
    local namespaces=("$GITLAB_NAMESPACE" "$JENKINS_NAMESPACE" "$NEXUS_NAMESPACE" "$ARGOCD_NAMESPACE" "$DEV_NAMESPACE" "$STAGE_NAMESPACE" "$PROD_NAMESPACE")
    local missing=()

    for ns in "${namespaces[@]}"; do
        if ! kubectl get namespace "$ns" &>/dev/null; then
            missing+=("$ns")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        check_pass "All namespaces exist"
    else
        check_fail "Missing namespaces: ${missing[*]}"
    fi
}

check_gitlab() {
    echo ""
    echo "=== GitLab ==="

    # Check pod status
    local gitlab_pods=$(kubectl get pods -n "$GITLAB_NAMESPACE" -l app=gitlab -o json 2>/dev/null)
    local ready_pods=$(echo "$gitlab_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$ready_pods" -gt 0 ]]; then
        check_pass "GitLab pod running"
    else
        check_fail "GitLab pod not running"
        return 1
    fi

    # Check API health
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        check_warn "GitLab API token not available"
        return 0
    fi

    local gitlab_user=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL_EXTERNAL/api/v4/user" 2>/dev/null | jq -r '.username // empty')

    if [[ -n "$gitlab_user" ]]; then
        check_pass "GitLab API reachable (user: $gitlab_user)"
    else
        check_fail "GitLab API unreachable or auth failed"
    fi

    # Check repositories exist
    local encoded_app=$(echo "$APP_REPO_PATH" | sed 's/\//%2F/g')
    local encoded_deploy=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    local app_exists=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL_EXTERNAL/api/v4/projects/$encoded_app" 2>/dev/null | jq -r '.id // empty')
    local deploy_exists=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL_EXTERNAL/api/v4/projects/$encoded_deploy" 2>/dev/null | jq -r '.id // empty')

    if [[ -n "$app_exists" && -n "$deploy_exists" ]]; then
        check_pass "Repositories exist ($APP_REPO_PATH, $DEPLOYMENTS_REPO_PATH)"
    else
        [[ -z "$app_exists" ]] && check_fail "Repository not found: $APP_REPO_PATH"
        [[ -z "$deploy_exists" ]] && check_fail "Repository not found: $DEPLOYMENTS_REPO_PATH"
    fi
}

check_jenkins() {
    echo ""
    echo "=== Jenkins ==="

    # Check pod status
    local jenkins_pods=$(kubectl get pods -n "$JENKINS_NAMESPACE" -l app=jenkins -o json 2>/dev/null)
    local ready_pods=$(echo "$jenkins_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$ready_pods" -gt 0 ]]; then
        check_pass "Jenkins pod running"
    else
        check_fail "Jenkins pod not running"
        return 1
    fi

    # Check API health
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        check_warn "Jenkins credentials not available"
        return 0
    fi

    local jenkins_mode=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL_EXTERNAL/api/json" 2>/dev/null | jq -r '.mode // empty')

    if [[ -n "$jenkins_mode" ]]; then
        check_pass "Jenkins API reachable (mode: $jenkins_mode)"
    else
        check_fail "Jenkins API unreachable or auth failed"
    fi

    # Check jobs exist
    local ci_job=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL_EXTERNAL/job/$APP_REPO_NAME/api/json" 2>/dev/null | jq -r '.name // empty')
    local promote_job=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL_EXTERNAL/job/$JENKINS_PROMOTE_JOB_NAME/api/json" 2>/dev/null | jq -r '.name // empty')

    if [[ -n "$ci_job" ]]; then
        check_pass "CI job exists: $APP_REPO_NAME"
    else
        check_fail "CI job not found: $APP_REPO_NAME"
    fi

    if [[ -n "$promote_job" ]]; then
        check_pass "Promotion job exists: $JENKINS_PROMOTE_JOB_NAME"
    else
        check_fail "Promotion job not found: $JENKINS_PROMOTE_JOB_NAME"
    fi
}

check_nexus() {
    echo ""
    echo "=== Nexus ==="

    # Check pod status
    local nexus_pods=$(kubectl get pods -n "$NEXUS_NAMESPACE" -l app=nexus -o json 2>/dev/null)
    local ready_pods=$(echo "$nexus_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$ready_pods" -gt 0 ]]; then
        check_pass "Nexus pod running"
    else
        check_fail "Nexus pod not running"
        return 1
    fi

    # Check Nexus web UI is accessible (may require auth for API)
    local nexus_http=$(curl -sk -o /dev/null -w "%{http_code}" "$NEXUS_URL_EXTERNAL/" 2>/dev/null)

    if [[ "$nexus_http" == "200" || "$nexus_http" == "302" ]]; then
        check_pass "Nexus web UI reachable (HTTP $nexus_http)"
    else
        check_fail "Nexus unreachable (HTTP $nexus_http)"
    fi

    # Check Docker registry (via catalog endpoint)
    local docker_catalog=$(curl -sk "https://$DOCKER_REGISTRY_EXTERNAL/v2/_catalog" 2>/dev/null | jq -r '.repositories // empty')

    if [[ -n "$docker_catalog" ]]; then
        check_pass "Docker registry reachable ($DOCKER_REGISTRY_EXTERNAL)"
    else
        check_warn "Docker registry catalog unavailable (may require auth)"
    fi
}

check_argocd() {
    echo ""
    echo "=== ArgoCD ==="

    # Check controller pod
    local controller_pods=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-application-controller -o json 2>/dev/null)
    local ready_pods=$(echo "$controller_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$ready_pods" -gt 0 ]]; then
        check_pass "ArgoCD controller running"
    else
        check_fail "ArgoCD controller not running"
        return 1
    fi

    # Check server pod
    local server_pods=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server -o json 2>/dev/null)
    local server_ready=$(echo "$server_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$server_ready" -gt 0 ]]; then
        check_pass "ArgoCD server running"
    else
        check_fail "ArgoCD server not running"
    fi

    # Check applications
    local apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
    local app_count=$(echo "$apps" | jq '.items | length')

    if [[ "$app_count" -eq 0 ]]; then
        check_warn "No ArgoCD applications found"
        return 0
    fi

    # Check each app status
    for env in dev stage prod; do
        local app_name="${APP_REPO_NAME}-${env}"
        local app_status=$(echo "$apps" | jq -r --arg name "$app_name" \
            '.items[] | select(.metadata.name == $name) | "\(.status.sync.status)/\(.status.health.status)"')

        if [[ -z "$app_status" ]]; then
            check_fail "Application not found: $app_name"
        elif [[ "$app_status" == "Synced/Healthy" ]]; then
            check_pass "Application healthy: $app_name"
        else
            check_warn "Application status: $app_name ($app_status)"
        fi
    done
}

check_deployments() {
    echo ""
    echo "=== Application Deployments ==="

    for env in dev stage prod; do
        local namespace="$env"
        local pod_info=$(kubectl get pods -n "$namespace" -l "app=$APP_REPO_NAME" -o json 2>/dev/null)
        local total=$(echo "$pod_info" | jq '.items | length')
        local running=$(echo "$pod_info" | jq '[.items[] | select(.status.phase == "Running")] | length')

        if [[ "$total" -eq 0 ]]; then
            check_warn "No pods in $env namespace"
        elif [[ "$running" -eq "$total" ]]; then
            local image=$(echo "$pod_info" | jq -r '.items[0].spec.containers[0].image' | sed 's/.*://')
            check_pass "$env: $running/$total pods running (image: $image)"
        else
            check_fail "$env: $running/$total pods running"
        fi
    done
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_summary() {
    echo ""
    echo "==========================================="
    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}All infrastructure components healthy${NC}"
    else
        echo -e "${RED}Some components have issues${NC}"
    fi
    echo "==========================================="
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "=== Infrastructure Health Check ==="
    echo "$(date '+%Y-%m-%d %H:%M:%S')"

    load_credentials

    check_kubernetes
    check_gitlab
    check_jenkins
    check_nexus
    check_argocd
    check_deployments

    print_summary

    exit $FAILED
}

main "$@"
