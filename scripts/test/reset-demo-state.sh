#!/usr/bin/env bash
#
# reset-demo-state.sh
# Reset the demo environment to a clean state
#
# This script cleans up:
# - Failed/InvalidImageName pods and their ReplicaSets in dev/stage/prod
# - Stuck Jenkins builds and queued items
# - Stale MR branches in GitLab (update-dev-*, update-stage-*, update-prod-*)
# - Optionally recreates environment branches with valid configurations
#
# Usage:
#   ./scripts/test/reset-demo-state.sh              # Clean up failed resources
#   ./scripts/test/reset-demo-state.sh --full       # Full reset including env branches
#   ./scripts/test/reset-demo-state.sh --dry-run    # Show what would be cleaned
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[→]${NC} $1"; }

# Parse arguments
DRY_RUN=false
FULL_RESET=false
CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --full) FULL_RESET=true; shift ;;
        -h|--help)
            echo "Usage: $0 <config-file> [--dry-run] [--full]"
            echo ""
            echo "Options:"
            echo "  --dry-run  Show what would be cleaned without making changes"
            echo "  --full     Full reset including environment branches"
            exit 0
            ;;
        *.env) CONFIG_FILE="$1"; shift ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Source infrastructure config via lib/infra.sh
source "$SCRIPT_DIR/../lib/infra.sh" "${CONFIG_FILE:-${CLUSTER_CONFIG:-}}"

echo ""
echo "========================================"
echo "  Demo State Reset"
echo "========================================"
echo ""
if $DRY_RUN; then
    log_warn "DRY RUN MODE - No changes will be made"
    echo ""
fi

# =============================================================================
# 1. Clean up failed Kubernetes resources
# =============================================================================
cleanup_failed_k8s_resources() {
    log_step "Cleaning up failed Kubernetes resources..."

    local namespaces=("dev" "stage" "prod")
    local total_cleaned=0

    for ns in "${namespaces[@]}"; do
        # Find failed pods (InvalidImageName, Error, CrashLoopBackOff)
        local failed_pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | \
            grep -E "InvalidImageName|Error|CrashLoopBackOff|ImagePullBackOff" | \
            awk '{print $1}' || true)

        if [[ -n "$failed_pods" ]]; then
            log_info "Found failed pods in $ns:"
            echo "$failed_pods" | sed 's/^/    /'

            if ! $DRY_RUN; then
                # Get the ReplicaSets for these pods and delete them
                for pod in $failed_pods; do
                    local rs=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
                    if [[ -n "$rs" ]]; then
                        kubectl delete replicaset "$rs" -n "$ns" --ignore-not-found=true 2>/dev/null || true
                        log_info "  Deleted ReplicaSet: $rs"
                        ((total_cleaned++)) || true
                    fi
                done
            fi
        else
            log_info "No failed pods in $ns"
        fi
    done

    if $DRY_RUN; then
        log_info "Would clean up failed pods/replicasets"
    else
        log_info "Cleaned up $total_cleaned ReplicaSets"
    fi
    echo ""
}

# =============================================================================
# 2. Cancel stuck Jenkins builds
# =============================================================================
cleanup_jenkins_builds() {
    log_step "Checking for stuck Jenkins builds..."

    # Get Jenkins credentials
    local jenkins_user jenkins_token
    jenkins_user=$(kubectl get secret "${JENKINS_ADMIN_SECRET}" -n "${JENKINS_NAMESPACE}" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    jenkins_token=$(kubectl get secret "${JENKINS_ADMIN_SECRET}" -n "${JENKINS_NAMESPACE}" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$jenkins_user" || -z "$jenkins_token" ]]; then
        log_warn "Could not get Jenkins credentials, skipping Jenkins cleanup"
        return
    fi

    local jenkins_url="${JENKINS_URL_EXTERNAL}"

    # Get crumb for CSRF protection (fetch once, use for all requests)
    local crumb crumb_field
    local crumb_json=$(curl -sk -u "$jenkins_user:$jenkins_token" \
        "$jenkins_url/crumbIssuer/api/json" 2>/dev/null)
    crumb=$(echo "$crumb_json" | jq -r '.crumb' 2>/dev/null || true)
    crumb_field=$(echo "$crumb_json" | jq -r '.crumbRequestField' 2>/dev/null || echo "Jenkins-Crumb")

    if [[ -z "$crumb" ]]; then
        log_warn "Could not get Jenkins crumb, skipping Jenkins cleanup"
        return
    fi

    # Check queue
    local queue_length=$(curl -sk -u "$jenkins_user:$jenkins_token" \
        "$jenkins_url/queue/api/json" 2>/dev/null | jq '.items | length' 2>/dev/null || echo "0")

    if [[ "$queue_length" -gt 0 ]]; then
        log_info "Found $queue_length items in Jenkins queue"
        if ! $DRY_RUN; then
            # Cancel all queued items
            local queue_ids=$(curl -sk -u "$jenkins_user:$jenkins_token" \
                "$jenkins_url/queue/api/json" 2>/dev/null | jq -r '.items[].id' 2>/dev/null || true)

            for id in $queue_ids; do
                curl -sk -X POST -u "$jenkins_user:$jenkins_token" \
                    -H "$crumb_field: $crumb" \
                    "$jenkins_url/queue/cancelItem?id=$id" >/dev/null 2>&1 || true
                log_info "  Cancelled queue item: $id"
            done
        fi
    else
        log_info "Jenkins queue is empty"
    fi

    # Check for stuck/running builds on example-app/main
    local building=$(curl -sk -u "$jenkins_user:$jenkins_token" \
        "$jenkins_url/job/example-app/job/main/lastBuild/api/json" 2>/dev/null | \
        jq -r 'select(.building == true) | .number' 2>/dev/null || true)

    if [[ -n "$building" ]]; then
        log_info "Found running build #$building on example-app/main"
        if ! $DRY_RUN; then
            curl -sk -X POST -u "$jenkins_user:$jenkins_token" \
                -H "$crumb_field: $crumb" \
                "$jenkins_url/job/example-app/job/main/$building/stop" >/dev/null 2>&1 || true
            log_info "  Stopped build #$building"
        fi
    else
        log_info "No stuck builds found"
    fi

    # Delete any pending Jenkins agent pods
    local pending_agents=$(kubectl get pods -n jenkins --no-headers 2>/dev/null | \
        grep -E "example-app.*Pending|k8s-deployments.*Pending" | awk '{print $1}' || true)

    if [[ -n "$pending_agents" ]]; then
        log_info "Found pending Jenkins agent pods:"
        echo "$pending_agents" | sed 's/^/    /'
        if ! $DRY_RUN; then
            for pod in $pending_agents; do
                kubectl delete pod "$pod" -n jenkins --ignore-not-found=true 2>/dev/null || true
                log_info "  Deleted pending agent: $pod"
            done
        fi
    fi

    echo ""
}

# =============================================================================
# 3. Clean up stale GitLab MR branches
# =============================================================================
cleanup_gitlab_branches() {
    log_step "Cleaning up stale GitLab MR branches..."

    # Get GitLab credentials
    local gitlab_token
    gitlab_token=$(kubectl get secret "${GITLAB_TOKEN_SECRET}" -n "${GITLAB_NAMESPACE}" \
        -o jsonpath="{.data.${GITLAB_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$gitlab_token" ]]; then
        log_warn "Could not get GitLab token, skipping GitLab cleanup"
        return
    fi

    local gitlab_url="${GITLAB_URL_EXTERNAL}"
    local project_path="${DEPLOYMENTS_REPO_PATH}"
    local encoded_path=$(echo "$project_path" | sed 's/\//%2F/g')

    # Get branches matching update-* pattern
    local branches=$(curl -sk -H "PRIVATE-TOKEN: $gitlab_token" \
        "$gitlab_url/api/v4/projects/$encoded_path/repository/branches?search=update-" 2>/dev/null | \
        jq -r '.[].name' 2>/dev/null || true)

    if [[ -n "$branches" ]]; then
        log_info "Found stale MR branches:"
        echo "$branches" | sed 's/^/    /'

        if ! $DRY_RUN; then
            for branch in $branches; do
                local encoded_branch=$(echo "$branch" | sed 's/\//%2F/g')
                curl -sk -X DELETE -H "PRIVATE-TOKEN: $gitlab_token" \
                    "$gitlab_url/api/v4/projects/$encoded_path/repository/branches/$encoded_branch" 2>/dev/null || true
                log_info "  Deleted branch: $branch"
            done
        fi
    else
        log_info "No stale MR branches found"
    fi

    # Also close any open MRs from validation runs
    local open_mrs=$(curl -sk -H "PRIVATE-TOKEN: $gitlab_token" \
        "$gitlab_url/api/v4/projects/$encoded_path/merge_requests?state=opened" 2>/dev/null | \
        jq -r '.[] | select(.source_branch | startswith("update-")) | .iid' 2>/dev/null || true)

    if [[ -n "$open_mrs" ]]; then
        log_info "Found open MRs from validation runs:"
        echo "$open_mrs" | sed 's/^/    MR !/'

        if ! $DRY_RUN; then
            for mr_iid in $open_mrs; do
                curl -sk -X PUT -H "PRIVATE-TOKEN: $gitlab_token" \
                    "$gitlab_url/api/v4/projects/$encoded_path/merge_requests/$mr_iid" \
                    -d "state_event=close" >/dev/null 2>&1 || true
                log_info "  Closed MR !$mr_iid"
            done
        fi
    else
        log_info "No open validation MRs found"
    fi

    echo ""
}

# =============================================================================
# 4. Full reset - recreate environment branches
# =============================================================================
full_reset() {
    if ! $FULL_RESET; then
        return
    fi

    log_step "Performing full reset of environment branches..."

    if $DRY_RUN; then
        log_info "Would run: ./scripts/03-pipelines/setup-gitlab-env-branches.sh --reset"
    else
        "$PROJECT_ROOT/scripts/03-pipelines/setup-gitlab-env-branches.sh" --reset
    fi

    echo ""
}

# =============================================================================
# 5. Verify final state
# =============================================================================
verify_state() {
    log_step "Verifying final state..."

    echo ""
    echo "Kubernetes pods in app namespaces:"
    for ns in dev stage prod; do
        echo "  $ns:"
        kubectl get pods -n "$ns" --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (no pods)"
    done

    echo ""
    echo "Node resource allocation:"
    kubectl describe node 2>/dev/null | grep -E "cpu.*\([0-9]+%\)" | head -1 | sed 's/^/  /'

    echo ""
}

# =============================================================================
# Main
# =============================================================================
cleanup_failed_k8s_resources
cleanup_jenkins_builds
cleanup_gitlab_branches
full_reset
verify_state

echo "========================================"
if $DRY_RUN; then
    log_warn "DRY RUN COMPLETE - No changes were made"
    echo "Run without --dry-run to apply changes"
else
    log_info "Reset complete!"
fi
echo "========================================"
