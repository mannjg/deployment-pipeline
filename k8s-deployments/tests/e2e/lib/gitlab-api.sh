#!/bin/bash
# GitLab API integration library for E2E pipeline testing

# Get GitLab API URL
get_gitlab_api_url() {
    echo "${GITLAB_URL:-http://gitlab.gitlab.svc.cluster.local}/api/v4"
}

# Check GitLab API connectivity and authentication
check_gitlab_api() {
    local api_url
    api_url=$(get_gitlab_api_url)

    log_debug "Checking GitLab API connectivity..."

    if [ -z "${GITLAB_TOKEN}" ]; then
        log_error "GITLAB_TOKEN not set"
        return 1
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/user" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "200" ]; then
        log_pass "GitLab API accessible and token valid"
        return 0
    else
        log_error "GitLab API check failed (HTTP $http_code)"
        return 1
    fi
}

# Create a merge request
# Usage: create_merge_request PROJECT_ID SOURCE_BRANCH TARGET_BRANCH TITLE [DESCRIPTION]
create_merge_request() {
    local project_id=$1
    local source_branch=$2
    local target_branch=$3
    local title=$4
    local description=${5:-"Automated E2E test merge request"}

    log_info "Creating MR: $source_branch -> $target_branch in project $project_id"

    local api_url
    api_url=$(get_gitlab_api_url)

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{
            \"source_branch\": \"$source_branch\",
            \"target_branch\": \"$target_branch\",
            \"title\": \"$title\",
            \"description\": \"$description\",
            \"remove_source_branch\": false
        }" \
        "${api_url}/projects/${project_id}/merge_requests" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "201" ]; then
        local mr_iid
        mr_iid=$(echo "$body" | jq -r '.iid')
        log_pass "Merge request created: !${mr_iid}"
        echo "$mr_iid"
        return 0
    else
        log_error "Failed to create merge request (HTTP $http_code)"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        return 1
    fi
}

# Approve a merge request
# Usage: approve_merge_request PROJECT_ID MR_IID
approve_merge_request() {
    local project_id=$1
    local mr_iid=$2

    log_info "Approving MR !${mr_iid} in project $project_id"

    local api_url
    api_url=$(get_gitlab_api_url)

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/projects/${project_id}/merge_requests/${mr_iid}/approve" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        log_pass "Merge request approved: !${mr_iid}"
        return 0
    else
        log_warn "Approval may have failed (HTTP $http_code) - continuing anyway"
        # Don't fail - approval might not be required
        return 0
    fi
}

# Merge a merge request
# Usage: merge_merge_request PROJECT_ID MR_IID
merge_merge_request() {
    local project_id=$1
    local mr_iid=$2

    log_info "Merging MR !${mr_iid} in project $project_id"

    # First check if MR can be merged
    local api_url
    api_url=$(get_gitlab_api_url)

    local mr_status
    mr_status=$(curl -s \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/projects/${project_id}/merge_requests/${mr_iid}" | \
        jq -r '.merge_status')

    log_debug "MR merge_status: $mr_status"

    if [ "$mr_status" != "can_be_merged" ]; then
        log_warn "MR cannot be merged yet (status: $mr_status), waiting..."
        sleep 5
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --request PUT \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data '{
            "should_remove_source_branch": false,
            "merge_when_pipeline_succeeds": false
        }' \
        "${api_url}/projects/${project_id}/merge_requests/${mr_iid}/merge" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        log_pass "Merge request merged: !${mr_iid}"
        return 0
    else
        log_error "Failed to merge MR (HTTP $http_code)"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        return 1
    fi
}

# Get merge request status
# Usage: get_merge_request_status PROJECT_ID MR_IID
get_merge_request_status() {
    local project_id=$1
    local mr_iid=$2

    local api_url
    api_url=$(get_gitlab_api_url)

    curl -s \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/projects/${project_id}/merge_requests/${mr_iid}" | \
        jq -r '.state'
}

# Wait for merge request to be merged
# Usage: wait_for_merge PROJECT_ID MR_IID [TIMEOUT]
wait_for_merge() {
    local project_id=$1
    local mr_iid=$2
    local timeout=${3:-120}

    log_info "Waiting for MR !${mr_iid} to be merged..."

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local state
        state=$(get_merge_request_status "$project_id" "$mr_iid")

        if [ "$state" = "merged" ]; then
            log_pass "MR !${mr_iid} merged successfully"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "Timeout waiting for MR to merge"
    return 1
}

# Get latest commit from branch
# Usage: get_branch_commit PROJECT_ID BRANCH
get_branch_commit() {
    local project_id=$1
    local branch=$2

    local api_url
    api_url=$(get_gitlab_api_url)

    curl -s \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/projects/${project_id}/repository/branches/${branch}" | \
        jq -r '.commit.id'
}

# Close a merge request
# Usage: close_merge_request PROJECT_ID MR_IID
close_merge_request() {
    local project_id=$1
    local mr_iid=$2

    log_info "Closing MR !${mr_iid}"

    local api_url
    api_url=$(get_gitlab_api_url)

    curl -s \
        --request PUT \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data '{"state_event": "close"}' \
        "${api_url}/projects/${project_id}/merge_requests/${mr_iid}" \
        > /dev/null
}

# List open merge requests for cleanup
# Usage: list_test_merge_requests PROJECT_ID
list_test_merge_requests() {
    local project_id=$1

    local api_url
    api_url=$(get_gitlab_api_url)

    curl -s \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/projects/${project_id}/merge_requests?state=opened&search=E2E" | \
        jq -r '.[].iid'
}
