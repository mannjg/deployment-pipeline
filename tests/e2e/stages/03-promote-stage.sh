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

    # Use k8s-deployments project ID from GitLab
    # Stages 3-6 promote between branches within k8s-deployments repository
    local project_id="${K8S_DEPLOYMENTS_PROJECT_ID:-2}"
    log_pass "Using k8s-deployments project ID: $project_id"
    echo "$project_id" > "${E2E_STATE_DIR}/gitlab_project_id.txt"

    # Navigate to k8s-deployments repository
    log_info "Fetching latest changes from k8s-deployments..."
    local deployment_pipeline_root
    deployment_pipeline_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    local k8s_repo_path="${deployment_pipeline_root}/${K8S_DEPLOYMENTS_PATH}"

    if [ ! -d "$k8s_repo_path/.git" ]; then
        log_error "k8s-deployments repository not found: $k8s_repo_path"
        return 1
    fi

    cd "$k8s_repo_path" || return 1
    log_info "Working in: $(pwd)"

    fetch_remote origin || {
        log_error "Failed to fetch from remote"
        return 1
    }

    # Get latest commit SHA from dev branch
    local dev_commit
    dev_commit=$(git rev-parse "origin/${DEV_BRANCH}")
    log_info "Latest dev commit: $dev_commit"

    # Create merge request from dev to stage
    log_info "Creating merge request: ${DEV_BRANCH} -> ${STAGE_BRANCH}"

    local mr_title="E2E Test: Promote to stage ($(date '+%Y-%m-%d %H:%M'))"
    local mr_description="
## E2E Pipeline Test Promotion

Promoting from dev to stage as part of automated E2E testing.

**Source Branch**: \`${DEV_BRANCH}\`
**Target Branch**: \`${STAGE_BRANCH}\`
**Test Timestamp**: $(date '+%Y-%m-%d %H:%M:%S')
**Commit SHA**: \`$dev_commit\`

This is an automated test merge request. It will be automatically merged and can be safely cleaned up.
"

    local mr_iid
    mr_iid=$(create_merge_request \
        "$project_id" \
        "${DEV_BRANCH}" \
        "${STAGE_BRANCH}" \
        "$mr_title" \
        "$mr_description")

    if [ $? -ne 0 ] || [ -z "$mr_iid" ]; then
        log_error "Failed to create merge request"
        return 1
    fi

    echo "$mr_iid" > "${E2E_STATE_DIR}/stage_mr_iid.txt"
    log_pass "Merge request created: !${mr_iid}"

    # Wait a moment for MR to be processed
    sleep 5

    # Check if MR requires approval
    if [ "${REQUIRE_APPROVALS}" = "true" ]; then
        log_info "Approving merge request..."

        approve_merge_request "$project_id" "$mr_iid" || {
            log_warn "Failed to approve MR, continuing anyway"
        }

        sleep 2
    fi

    # Merge the merge request
    log_info "Merging merge request !${mr_iid}..."

    merge_merge_request "$project_id" "$mr_iid" || {
        log_error "Failed to merge MR"

        # Get MR status for debugging
        local mr_status
        mr_status=$(get_merge_request_status "$project_id" "$mr_iid")
        log_error "MR status: $mr_status"

        return 1
    }

    # Wait for merge to complete
    log_info "Waiting for merge to complete..."
    wait_for_merge "$project_id" "$mr_iid" 120 || {
        log_error "Timeout waiting for MR to merge"
        return 1
    }

    # Force ArgoCD to refresh and sync immediately to avoid waiting for git poll interval
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

    # Pull latest stage branch locally
    log_info "Updating local stage branch..."
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
