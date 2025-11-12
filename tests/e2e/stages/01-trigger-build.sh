#!/bin/bash
# E2E Pipeline Stage 1: Trigger Build
# Creates a test commit on dev branch and triggers Jenkins build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/../../../k8s-deployments/tests/lib/common.sh"
source "$SCRIPT_DIR/../lib/git-operations.sh"
source "$SCRIPT_DIR/../lib/jenkins-api.sh"
source "$SCRIPT_DIR/../lib/gitlab-api.sh"

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

    # Navigate to the appropriate repository
    log_info "Target repository: ${TEST_REPO}"

    local deployment_pipeline_root
    deployment_pipeline_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    local repo_path
    if [ "${TEST_REPO}" = "example-app" ]; then
        repo_path="${deployment_pipeline_root}/${EXAMPLE_APP_PATH}"
    else
        repo_path="${deployment_pipeline_root}/${K8S_DEPLOYMENTS_PATH}"
    fi

    if [ ! -d "$repo_path/.git" ]; then
        log_error "Repository not found or not a git repo: $repo_path"
        return 1
    fi

    cd "$repo_path" || return 1
    log_info "Working in: $(pwd)"

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

    # Create test commit based on repository type
    log_info "Creating test commit..."
    local test_version
    test_version="e2e-test-$(date +%Y%m%d-%H%M%S)"

    if [ "${TEST_REPO}" = "example-app" ]; then
        # For example-app, bump the Maven version to trigger a new Docker image build
        log_info "Creating application code change..."

        # Generate unique version with timestamp
        local new_version="1.2.0-e2e-$(date +%Y%m%d%H%M%S)"

        # Update pom.xml version using Maven
        if [ -f "pom.xml" ]; then
            log_info "Bumping Maven version to: ${new_version}"

            # Use Maven versions plugin to set version (more robust than sed)
            if mvn versions:set -DnewVersion="${new_version}" -DgenerateBackupPoms=false -q 2>&1 | grep -v "^\[" | grep -v "^$" | head -20; then
                log_pass "Maven version updated successfully"
            else
                log_warn "Maven command produced output (may be normal)"
            fi

            git add pom.xml
            git commit -m "E2E test: Bump version to ${new_version}"
        else
            log_error "pom.xml not found"
            return 1
        fi
    else
        # For k8s-deployments, use version bump
        log_info "Creating configuration change..."
        local version_file="${E2E_VERSION_FILE:-VERSION.txt}"
        create_version_bump_commit \
            "$version_file" \
            "$test_version" \
            "E2E test: version bump to $test_version"
    fi

    if [ $? -ne 0 ]; then
        log_error "Failed to create test commit"
        return 1
    fi

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

    # Trigger SCM poll to ensure Jenkins has latest commits
    log_info "Triggering Jenkins SCM poll to fetch latest commits..."
    
    # Check Jenkins is accessible
    check_jenkins_api || {
        log_error "Jenkins API not accessible"
        return 1
    }
    
    # Trigger SCM poll via Jenkins API
    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)
    
    local poll_response
    poll_response=$(curl -s -w "
%{http_code}" \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        --request POST \
        "${jenkins_url}/job/${JENKINS_JOB_NAME}/polling" 2>&1)
    
    local poll_code
    poll_code=$(echo "$poll_response" | tail -n1)
    
    if [ "$poll_code" = "200" ] || [ "$poll_code" = "201" ]; then
        log_pass "SCM poll triggered successfully"
    else
        log_warn "SCM poll trigger returned HTTP $poll_code (may not be supported)"
    fi
    
    # Wait for SCM poll to complete and fetch latest commits
    log_info "Waiting for Jenkins to fetch latest commits..."
    sleep 10
    
    # Now manually trigger build with latest commits
    log_info "Triggering Jenkins build..."
    local queue_item
    if [ -n "${JENKINS_BUILD_PARAMS:-}" ]; then
        # Pass parameters as separate arguments (word splitting intentional)
        queue_item=$(trigger_jenkins_build "${JENKINS_JOB_NAME}" $JENKINS_BUILD_PARAMS)
    else
        queue_item=$(trigger_jenkins_build "${JENKINS_JOB_NAME}")
    fi
    
    if [ $? -ne 0 ]; then
        log_error "Failed to trigger Jenkins build"
        return 1
    fi
    
    # Wait for build to start and get build number
    local build_number=""
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

    # If testing example-app, merge the Jenkins-created MR in k8s-deployments
    if [ "${TEST_REPO}" = "example-app" ]; then
        log_info "Looking for Jenkins-created MR in k8s-deployments..."

        # k8s-deployments project ID in GitLab
        local k8s_project_id="${K8S_DEPLOYMENTS_PROJECT_ID:-2}"

        # Wait a moment for Jenkins to create the MR
        sleep 5

        # Get the expected image tag from Jenkins console output
        local expected_image
        expected_image=$(get_build_console_output "${JENKINS_JOB_NAME}" "$build_number" 300 | \
            grep "Deploy image:" | tail -1 | sed 's/.*Deploy image: //' | tr -d '\r')

        if [ -n "$expected_image" ]; then
            log_pass "Expected image: $expected_image"
            echo "$expected_image" > "${E2E_STATE_DIR}/expected_image.txt"
        else
            log_warn "Could not determine expected image from Jenkins output"
        fi

        # Get the most recent open MR targeting dev branch
        local jenkins_mr_iid
        jenkins_mr_iid=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/projects/${k8s_project_id}/merge_requests?state=opened&target_branch=dev&per_page=1" | \
            jq -r '.[0].iid' 2>/dev/null)

        if [ -n "$jenkins_mr_iid" ] && [ "$jenkins_mr_iid" != "null" ]; then
            log_pass "Found Jenkins MR !${jenkins_mr_iid}"
            echo "$jenkins_mr_iid" > "${E2E_STATE_DIR}/jenkins_mr_iid.txt"

            # Verify image update isolation (test the fix)
            log_info "Verifying MR only updates example-app image (not postgres)..."

            # Get MR changes from GitLab API
            local mr_changes
            mr_changes=$(curl -s \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                "${GITLAB_URL}/api/v4/projects/${k8s_project_id}/merge_requests/${jenkins_mr_iid}/changes")

            # Extract diff for envs/dev.cue
            local dev_cue_diff
            dev_cue_diff=$(echo "$mr_changes" | jq -r '.changes[] | select(.new_path == "envs/dev.cue") | .diff' 2>/dev/null)

            if [ -n "$dev_cue_diff" ]; then
                # Check if example-app image was updated
                if echo "$dev_cue_diff" | grep -q "docker.local/example/example-app"; then
                    log_pass "✓ MR updates example-app image (correct)"
                else
                    log_warn "MR does not update example-app image (unexpected)"
                fi

                # Check if postgres image was NOT changed (this is the critical test)
                if echo "$dev_cue_diff" | grep -q "postgres:.*-alpine"; then
                    log_fail "✗ MR modifies postgres image (BUG - fix failed!)"
                    log_error "The image update isolation fix did not work!"
                    log_error "MR diff shows postgres image change:"
                    echo "$dev_cue_diff" | grep "postgres"
                    return 1
                else
                    log_pass "✓ MR does NOT modify postgres image (fix working!)"
                fi

                # Count total image changes
                local image_changes
                image_changes=$(echo "$dev_cue_diff" | grep -c "^[+-].*image:" || echo "0")
                log_info "Total image lines changed in diff: $image_changes (expected: 2 for 1 image update)"

            else
                log_warn "Could not extract dev.cue diff from MR"
            fi

            # Approve the MR
            log_info "Approving MR !${jenkins_mr_iid}..."
            approve_merge_request "$k8s_project_id" "$jenkins_mr_iid" || {
                log_warn "Failed to approve MR (may not require approval)"
            }

            # Merge the MR
            log_info "Merging MR !${jenkins_mr_iid}..."
            if merge_merge_request "$k8s_project_id" "$jenkins_mr_iid"; then
                log_pass "Jenkins MR merged successfully"

                # Wait for merge to complete
                if wait_for_merge "$k8s_project_id" "$jenkins_mr_iid" 60; then
                    log_pass "MR merge confirmed"

                    # Force ArgoCD to refresh and sync immediately to avoid waiting for git poll interval
                    log_info "Forcing ArgoCD refresh for dev environment..."
                    if kubectl patch application "${ARGOCD_APP_PREFIX}-dev" -n argocd --type merge \
                        -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null; then
                        log_pass "ArgoCD refresh triggered for dev"
                    else
                        log_warn "Failed to trigger ArgoCD refresh (may require manual sync)"
                    fi
                else
                    log_error "MR merge confirmation timeout"
                    return 1
                fi
            else
                # Merge failed - likely conflicts, try to rebase and retry
                log_warn "Failed to merge Jenkins MR (may have conflicts), attempting to resolve..."

                # Navigate to k8s-deployments
                local deployment_pipeline_root
                deployment_pipeline_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"
                local k8s_repo_path="${deployment_pipeline_root}/${K8S_DEPLOYMENTS_PATH}"

                if [ -d "$k8s_repo_path" ]; then
                    cd "$k8s_repo_path" || return 1

                    # Fetch latest
                    git fetch origin || true

                    # Get MR source branch name
                    local mr_source_branch
                    mr_source_branch=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                        "${GITLAB_URL}/api/v4/projects/${k8s_project_id}/merge_requests/${jenkins_mr_iid}" | \
                        jq -r '.source_branch')

                    if [ -n "$mr_source_branch" ] && [ "$mr_source_branch" != "null" ]; then
                        log_info "Rebasing MR branch $mr_source_branch onto latest dev..."

                        # Stash any local changes that might interfere
                        if ! git diff --quiet || ! git diff --cached --quiet; then
                            log_info "Stashing local changes..."
                            git stash push -m "E2E test: temporary stash before rebase" || true
                        fi

                        # Checkout the MR's source branch
                        git checkout "$mr_source_branch" 2>&1 || git checkout -b "$mr_source_branch" "origin/$mr_source_branch" 2>&1 || {
                            log_error "Failed to checkout MR branch"
                            return 1
                        }

                        # Rebase onto latest dev
                        if git rebase "origin/${DEV_BRANCH}" 2>&1; then
                            log_pass "Rebase successful"

                            # Push the rebased branch
                            git push -f origin "$mr_source_branch" 2>&1 || {
                                log_error "Failed to push rebased branch"
                                return 1
                            }

                            log_pass "Rebased branch pushed, retrying merge..."

                            # Wait for GitLab to process the push
                            sleep 5

                            # Retry the merge
                            if merge_merge_request "$k8s_project_id" "$jenkins_mr_iid"; then
                                log_pass "Jenkins MR merged successfully after rebase"

                                if wait_for_merge "$k8s_project_id" "$jenkins_mr_iid" 60; then
                                    log_pass "MR merge confirmed"
                                else
                                    log_error "MR merge confirmation timeout"
                                    return 1
                                fi
                            else
                                # Merge still failed - check if changes are already in target
                                log_warn "Failed to merge MR even after rebase, checking if changes already applied..."

                                # Check if expected image is already in dev manifests
                                local manifest_image=""
                                if [ -f "manifests/dev/example-app.yaml" ]; then
                                    manifest_image=$(git show "origin/${DEV_BRANCH}:manifests/dev/example-app.yaml" 2>/dev/null | grep "image:" | awk '{print $2}' || echo "")
                                fi

                                if [ -n "$manifest_image" ] && [ "$manifest_image" = "$expected_image" ]; then
                                    log_pass "Dev branch already contains expected image: $expected_image"
                                    log_info "Closing stale MR !${jenkins_mr_iid} since changes are already applied"

                                    # Close the MR since changes are already applied
                                    curl -s --request PUT \
                                        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                                        --header "Content-Type: application/json" \
                                        --data '{"state_event": "close"}' \
                                        "${GITLAB_URL}/api/v4/projects/${k8s_project_id}/merge_requests/${jenkins_mr_iid}" >/dev/null

                                    log_pass "Changes already in dev, continuing with test"
                                else
                                    log_error "Manifest image ($manifest_image) doesn't match expected ($expected_image)"
                                    log_error "Failed to merge MR and changes are not in dev"
                                    return 1
                                fi
                            fi
                        else
                            log_error "Rebase failed, conflicts may require manual resolution"
                            git rebase --abort 2>&1 || true
                            return 1
                        fi
                    else
                        log_error "Could not determine MR source branch"
                        return 1
                    fi
                else
                    log_error "k8s-deployments path not found"
                    return 1
                fi
            fi
        else
            log_warn "No open MR found in k8s-deployments (Jenkins may not have created one yet)"
        fi
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
