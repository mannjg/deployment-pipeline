#!/bin/bash
# E2E Pipeline Stage 1: Trigger Build
# Creates a test commit on dev branch and triggers Jenkins build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/../../lib/common.sh"
source "$SCRIPT_DIR/../lib/git-operations.sh"
source "$SCRIPT_DIR/../lib/jenkins-api.sh"

# Load E2E configuration
if [ -f "$SCRIPT_DIR/../config/e2e-config.sh" ]; then
    source "$SCRIPT_DIR/../config/e2e-config.sh"
else
    log_error "E2E configuration not found"
    exit 1
fi

stage_01_trigger_build() {
    log_info "======================================"
    log_info "  STAGE 1: Trigger Build"
    log_info "======================================"
    echo

    # Navigate to repository root
    local repo_root
    repo_root=$(get_repo_root)

    if [ -z "$repo_root" ]; then
        log_error "Not in a git repository"
        return 1
    fi

    cd "$repo_root" || return 1

    # Verify we have clean state
    log_info "Verifying repository state..."
    if ! verify_clean_state; then
        log_warn "Repository has uncommitted changes, stashing..."
        stash_changes "E2E test stash before starting"
    fi

    # Fetch latest changes
    log_info "Fetching latest changes from remote..."
    fetch_remote origin || {
        log_error "Failed to fetch from remote"
        return 1
    }

    # Switch to dev branch and pull latest
    log_info "Switching to dev branch..."
    switch_branch "${DEV_BRANCH}" || {
        log_error "Failed to switch to dev branch"
        return 1
    }

    pull_current_branch || {
        log_error "Failed to pull latest changes"
        return 1
    }

    # Create feature branch for this test
    log_info "Creating E2E test feature branch..."
    local feature_branch
    feature_branch=$(create_e2e_feature_branch "${DEV_BRANCH}")

    if [ -z "$feature_branch" ]; then
        log_error "Failed to create feature branch"
        return 1
    fi

    # Export feature branch for other stages
    echo "$feature_branch" > "${E2E_STATE_DIR}/feature_branch.txt"
    log_pass "Created feature branch: $feature_branch"

    # Create test commit
    log_info "Creating test commit..."
    local test_version
    test_version="e2e-test-$(date +%Y%m%d-%H%M%S)"

    local version_file="${E2E_VERSION_FILE:-VERSION.txt}"

    create_version_bump_commit \
        "$version_file" \
        "$test_version" \
        "E2E test: version bump to $test_version" || {
        log_error "Failed to create test commit"
        return 1
    }

    local commit_sha
    commit_sha=$(get_last_commit_sha)
    echo "$commit_sha" > "${E2E_STATE_DIR}/commit_sha.txt"
    log_pass "Created test commit: $commit_sha"

    # Push feature branch
    log_info "Pushing feature branch to remote..."
    push_branch "$feature_branch" origin || {
        log_error "Failed to push feature branch"
        return 1
    }

    # Merge feature branch to dev (simulating a merge)
    log_info "Merging feature branch to dev..."
    switch_branch "${DEV_BRANCH}" || {
        log_error "Failed to switch to dev branch"
        return 1
    }

    git merge --no-ff "$feature_branch" -m "E2E test: Merge $feature_branch to dev" || {
        log_error "Failed to merge feature branch"
        return 1
    }

    # Push dev branch
    log_info "Pushing dev branch..."
    push_branch "${DEV_BRANCH}" origin || {
        log_error "Failed to push dev branch"
        return 1
    }

    local dev_commit_sha
    dev_commit_sha=$(get_last_commit_sha)
    echo "$dev_commit_sha" > "${E2E_STATE_DIR}/dev_commit_sha.txt"
    log_pass "Dev branch updated: $dev_commit_sha"

    # Trigger Jenkins build
    log_info "Triggering Jenkins build..."
    check_jenkins_api || {
        log_error "Jenkins API not accessible"
        return 1
    }

    local build_params=""
    if [ -n "${JENKINS_BUILD_PARAMS}" ]; then
        build_params="${JENKINS_BUILD_PARAMS}"
    fi

    local queue_item
    if [ -n "$build_params" ]; then
        queue_item=$(trigger_jenkins_build "${JENKINS_JOB_NAME}" "$build_params")
    else
        queue_item=$(trigger_jenkins_build "${JENKINS_JOB_NAME}")
    fi

    if [ $? -ne 0 ]; then
        log_error "Failed to trigger Jenkins build"
        return 1
    fi

    # Wait for build to start and get build number
    local build_number
    if [ -n "$queue_item" ]; then
        log_info "Waiting for build to start (queue item: $queue_item)..."
        build_number=$(get_build_number_from_queue "$queue_item" 120)
    else
        log_info "Waiting for build to appear..."
        sleep 10
        build_number=$(get_latest_build_number "${JENKINS_JOB_NAME}")
    fi

    if [ -z "$build_number" ] || [ "$build_number" = "null" ]; then
        log_error "Could not determine build number"
        return 1
    fi

    echo "$build_number" > "${E2E_STATE_DIR}/build_number.txt"
    log_pass "Jenkins build started: #${build_number}"

    # Wait for build to complete
    log_info "Waiting for Jenkins build to complete..."
    if wait_for_build_completion "${JENKINS_JOB_NAME}" "$build_number" "${JENKINS_BUILD_TIMEOUT:-600}"; then
        log_pass "Jenkins build completed successfully"
        echo "SUCCESS" > "${E2E_STATE_DIR}/build_status.txt"
    else
        log_error "Jenkins build failed"
        echo "FAILURE" > "${E2E_STATE_DIR}/build_status.txt"

        # Get console output for debugging
        log_error "Build console output (last 50 lines):"
        get_build_console_output "${JENKINS_JOB_NAME}" "$build_number" 50

        return 1
    fi

    echo
    log_info "======================================"
    log_pass "  STAGE 1: Complete"
    log_info "======================================"
    echo

    return 0
}

# Run stage if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    stage_01_trigger_build
fi
