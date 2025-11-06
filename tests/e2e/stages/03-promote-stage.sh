#!/bin/bash
# E2E Pipeline Stage 3: Promote to Stage
# Creates merge request from dev to stage and merges it

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/../../../k8s-deployments/tests/lib/common.sh"
source "$SCRIPT_DIR/../lib/git-operations.sh"
source "$SCRIPT_DIR/../lib/gitlab-api.sh"

# Load E2E configuration
if [ -f "$SCRIPT_DIR/../config/e2e-config.sh" ]; then
    source "$SCRIPT_DIR/../config/e2e-config.sh"
else
    log_error "E2E configuration not found"
    exit 1
fi

stage_03_promote_stage() {
    log_info "======================================"
    log_info "  STAGE 3: Promote to Stage"
    log_info "======================================"
    echo

    # Verify previous stage completed
    if [ ! -f "${E2E_STATE_DIR}/dev_status.txt" ]; then
        log_error "Dev deployment not verified"
        return 1
    fi

    # Check GitLab API connectivity
    log_info "Checking GitLab API connectivity..."
    check_gitlab_api || {
        log_error "GitLab API not accessible"
        return 1
    }

    # Use k8s-deployments project ID from stage 1
    local project_id
    if [ -f "${E2E_STATE_DIR}/gitlab_project_id.txt" ]; then
        project_id=$(cat "${E2E_STATE_DIR}/gitlab_project_id.txt")
    else
        project_id="${K8S_DEPLOYMENTS_PROJECT_ID:-2}"
    fi
    log_pass "Using k8s-deployments project ID: $project_id"

    # Find Jenkins-created MR for stage promotion
    log_info "Looking for Jenkins-created MR for stage..."

    # Get the most recent open MR targeting stage branch
    local stage_mr_iid
    stage_mr_iid=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${project_id}/merge_requests?state=opened&target_branch=stage&per_page=1" | \
        jq -r '.[0].iid' 2>/dev/null)

    if [ -z "$stage_mr_iid" ] || [ "$stage_mr_iid" = "null" ]; then
        log_error "No open MR found for stage promotion"
        log_error "Jenkins should have created an MR targeting stage branch"
        log_error "Check Jenkins build output and SKIP_STAGE_PROMOTION parameter"
        return 1
    fi

    log_pass "Found Jenkins stage MR !${stage_mr_iid}"
    echo "$stage_mr_iid" > "${E2E_STATE_DIR}/stage_mr_iid.txt"

    # Approve the MR if required
    if [ "${REQUIRE_APPROVALS}" = "true" ]; then
        log_info "Approving MR !${stage_mr_iid}..."
        approve_merge_request "$project_id" "$stage_mr_iid" || {
            log_warn "Failed to approve MR, continuing anyway"
        }
        sleep 2
    fi

    # Merge the MR
    log_info "Merging MR !${stage_mr_iid}..."
    merge_merge_request "$project_id" "$stage_mr_iid" || {
        log_error "Failed to merge stage MR"
        local mr_status
        mr_status=$(get_merge_request_status "$project_id" "$stage_mr_iid")
        log_error "MR status: $mr_status"
        return 1
    }

    # Wait for merge to complete
    log_info "Waiting for merge to complete..."
    wait_for_merge "$project_id" "$stage_mr_iid" 120 || {
        log_error "Timeout waiting for MR to merge"
        return 1
    }

    log_pass "Stage MR merged successfully"

    # Force ArgoCD to refresh and sync immediately
    log_info "Forcing ArgoCD refresh for stage environment..."
    if kubectl patch application "${ARGOCD_APP_PREFIX}-stage" -n argocd --type merge \
        -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null; then
        log_pass "ArgoCD refresh triggered for stage"
    else
        log_warn "Failed to trigger ArgoCD refresh (may require manual sync)"
    fi

    # Get the merged commit SHA
    local stage_commit
    stage_commit=$(get_branch_commit "$project_id" "${STAGE_BRANCH}")
    echo "$stage_commit" > "${E2E_STATE_DIR}/stage_commit_sha.txt"
    log_pass "Stage branch updated: $stage_commit"

    # Navigate to k8s-deployments and update local stage branch
    local deployment_pipeline_root
    deployment_pipeline_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    local k8s_repo_path="${deployment_pipeline_root}/${K8S_DEPLOYMENTS_PATH}"

    cd "$k8s_repo_path" || return 1

    log_info "Updating local stage branch..."
    fetch_remote origin || {
        log_error "Failed to fetch from remote"
        return 1
    }

    switch_branch "${STAGE_BRANCH}" || {
        log_error "Failed to switch to stage branch"
        return 1
    }

    pull_current_branch || {
        log_error "Failed to pull stage branch"
        return 1
    }

    # Save promotion timestamp
    echo "$(date +%s)" > "${E2E_STATE_DIR}/stage_promoted_timestamp.txt"

    echo
    log_info "======================================"
    log_pass "  STAGE 3: Complete"
    log_info "======================================"
    echo

    return 0
}

# Run stage if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    stage_03_promote_stage
fi
