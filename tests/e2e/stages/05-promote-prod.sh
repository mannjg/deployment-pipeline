#!/bin/bash
# E2E Pipeline Stage 5: Promote to Production
# Creates merge request from stage to prod and merges it

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

stage_05_promote_prod() {
    log_info "======================================"
    log_info "  STAGE 5: Promote to Production"
    log_info "======================================"
    echo

    # Verify previous stage completed
    if [ ! -f "${E2E_STATE_DIR}/stage_status.txt" ]; then
        log_error "Stage deployment not verified"
        return 1
    fi

    # Check GitLab API connectivity
    log_info "Checking GitLab API connectivity..."
    check_gitlab_api || {
        log_error "GitLab API not accessible"
        return 1
    }

    # Get GitLab project ID (from previous stage)
    local project_id
    if [ -f "${E2E_STATE_DIR}/gitlab_project_id.txt" ]; then
        project_id=$(cat "${E2E_STATE_DIR}/gitlab_project_id.txt")
    else
        project_id=$(get_gitlab_project_id)
    fi

    if [ -z "$project_id" ]; then
        log_error "Could not determine GitLab project ID"
        return 1
    fi

    log_pass "GitLab project ID: $project_id"

    # Fetch latest changes
    log_info "Fetching latest changes..."
    local repo_root
    repo_root=$(get_repo_root)
    cd "$repo_root" || return 1

    fetch_remote origin || {
        log_error "Failed to fetch from remote"
        return 1
    }

    # Get latest commit SHA from stage branch
    local stage_commit
    stage_commit=$(git rev-parse "origin/${STAGE_BRANCH}")
    log_info "Latest stage commit: $stage_commit"

    # Create merge request from stage to prod
    log_info "Creating merge request: ${STAGE_BRANCH} -> ${PROD_BRANCH}"

    local mr_title="E2E Test: Promote to production ($(date '+%Y-%m-%d %H:%M'))"
    local mr_description="
## E2E Pipeline Test Promotion to Production

Promoting from stage to production as part of automated E2E testing.

**Source Branch**: \`${STAGE_BRANCH}\`
**Target Branch**: \`${PROD_BRANCH}\`
**Test Timestamp**: $(date '+%Y-%m-%d %H:%M:%S')
**Commit SHA**: \`$stage_commit\`

### Verification Checklist
- [x] Dev deployment verified
- [x] Stage deployment verified
- [x] All tests passing

This is an automated test merge request. It will be automatically merged and can be safely cleaned up.

⚠️ **PRODUCTION PROMOTION** - Automated E2E Test
"

    local mr_iid
    mr_iid=$(create_merge_request \
        "$project_id" \
        "${STAGE_BRANCH}" \
        "${PROD_BRANCH}" \
        "$mr_title" \
        "$mr_description")

    if [ $? -ne 0 ] || [ -z "$mr_iid" ]; then
        log_error "Failed to create merge request"
        return 1
    fi

    echo "$mr_iid" > "${E2E_STATE_DIR}/prod_mr_iid.txt"
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

    # Additional safety check for production
    if [ "${PROD_SAFETY_CHECK}" = "true" ]; then
        log_warn "Production safety check enabled - waiting ${PROD_SAFETY_WAIT:-30}s..."
        sleep "${PROD_SAFETY_WAIT:-30}"
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
    log_info "Forcing ArgoCD refresh for prod environment..."
    if kubectl patch application "${ARGOCD_APP_PREFIX}-prod" -n argocd --type merge \
        -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null; then
        log_pass "ArgoCD refresh triggered for prod"
    else
        log_warn "Failed to trigger ArgoCD refresh (may require manual sync)"
    fi

    # Get the merged commit SHA
    local prod_commit
    prod_commit=$(get_branch_commit "$project_id" "${PROD_BRANCH}")

    echo "$prod_commit" > "${E2E_STATE_DIR}/prod_commit_sha.txt"
    log_pass "Production branch updated: $prod_commit"

    # Pull latest prod branch locally
    log_info "Updating local production branch..."
    switch_branch "${PROD_BRANCH}" || {
        log_error "Failed to switch to prod branch"
        return 1
    }

    pull_current_branch || {
        log_error "Failed to pull prod branch"
        return 1
    }

    # Save promotion timestamp
    echo "$(date +%s)" > "${E2E_STATE_DIR}/prod_promoted_timestamp.txt"

    echo
    log_info "======================================"
    log_pass "  STAGE 5: Complete"
    log_info "======================================"
    echo

    return 0
}

# Run stage if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    stage_05_promote_prod
fi
