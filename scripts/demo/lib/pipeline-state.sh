#!/bin/bash
# pipeline-state.sh - Check and cleanup pipeline state (MRs, builds, branches)
#
# Source this file: source "$(dirname "$0")/lib/pipeline-state.sh"
#
# Provides:
#   check_pipeline_quiescent() - Returns 0 if clean, 1 if dirty (sets STATE_* vars)
#   cleanup_pipeline_state()   - Closes MRs, cancels builds, deletes branches
#   display_pipeline_state()   - Displays current state for reporting
#
# Prerequisites:
#   - demo-helpers.sh sourced (for demo_action, demo_verify, etc.)
#   - pipeline-wait.sh sourced (for _encode_project, credential loading)
#   - GITLAB_TOKEN, JENKINS_USER, JENKINS_TOKEN set

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

PIPELINE_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load infrastructure config if not already loaded
if [[ -z "${GITLAB_URL_EXTERNAL:-}" ]]; then
    REPO_ROOT="$(cd "$PIPELINE_STATE_LIB_DIR/../../.." && pwd)"
    if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
        source "$REPO_ROOT/config/infra.env"
    fi
fi

# State variables (populated by check_pipeline_quiescent)
STATE_OPEN_MRS=()           # Array of "repo|iid|title|web_url" strings
STATE_RUNNING_BUILDS=()     # Array of "job/branch:number" strings
STATE_QUEUED_BUILDS=()      # Array of "queue_id:task_name" strings
STATE_LINGERING_BRANCHES=() # Array of "repo:branch" strings

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

# URL-encode a project path (reuse from pipeline-wait.sh if available)
_ps_encode_project() {
    echo "$1" | sed 's/\//%2F/g'
}

# Get CSRF crumb for Jenkins API calls
_ps_get_jenkins_crumb() {
    local cookie_jar="$1"
    local crumb_file="$2"

    curl -sk -c "$cookie_jar" -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL_EXTERNAL}/crumbIssuer/api/json" > "$crumb_file" 2>/dev/null || true
}

# ============================================================================
# CHECK FUNCTIONS
# ============================================================================

# Check for open MRs in both repos
# Populates STATE_OPEN_MRS array
_check_open_mrs() {
    STATE_OPEN_MRS=()

    local repos=("${APP_REPO_PATH:-p2c/example-app}" "${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}")

    for repo in "${repos[@]}"; do
        local encoded_repo=$(_ps_encode_project "$repo")
        local response

        response=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_repo}/merge_requests?state=opened" 2>/dev/null) || continue

        # Parse MRs from response
        local count
        count=$(echo "$response" | jq -r 'length // 0')

        if [[ "$count" -gt 0 ]]; then
            while IFS= read -r line; do
                STATE_OPEN_MRS+=("$line")
            done < <(echo "$response" | jq -r --arg repo "$repo" '.[] | "\($repo)|\(.iid)|\(.title)|\(.web_url)"' 2>/dev/null)
        fi
    done

    return 0
}

# Check for running/queued Jenkins builds
# Populates STATE_RUNNING_BUILDS and STATE_QUEUED_BUILDS arrays
_check_running_builds() {
    STATE_RUNNING_BUILDS=()
    STATE_QUEUED_BUILDS=()

    local jobs=("${APP_REPO_NAME:-example-app}" "${DEPLOYMENTS_REPO_NAME:-k8s-deployments}")

    for job in "${jobs[@]}"; do
        # Check running builds
        local builds_response
        builds_response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "${JENKINS_URL_EXTERNAL}/job/${job}/api/json?tree=jobs[name,builds[number,building]]" 2>/dev/null) || continue

        # For MultiBranch pipelines, iterate through branch jobs
        local branches
        branches=$(echo "$builds_response" | jq -r '.jobs[]?.name // empty' 2>/dev/null)

        for branch in $branches; do
            local branch_builds
            branch_builds=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
                "${JENKINS_URL_EXTERNAL}/job/${job}/job/${branch}/api/json?tree=builds[number,building]" 2>/dev/null) || continue

            # Find any building
            local running
            running=$(echo "$branch_builds" | jq -r '.builds[]? | select(.building == true) | .number' 2>/dev/null)

            for num in $running; do
                STATE_RUNNING_BUILDS+=("${job}/${branch}:${num}")
            done
        done
    done

    # Check build queue
    local queue_response
    queue_response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL_EXTERNAL}/queue/api/json" 2>/dev/null) || true

    if [[ -n "$queue_response" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && STATE_QUEUED_BUILDS+=("$line")
        done < <(echo "$queue_response" | jq -r '.items[]? | "\(.id):\(.task.name // "unknown")"' 2>/dev/null)
    fi

    return 0
}

# Check for lingering update-*/promote-* branches without open MRs
# Populates STATE_LINGERING_BRANCHES array
_check_lingering_branches() {
    STATE_LINGERING_BRANCHES=()

    local repo="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_repo=$(_ps_encode_project "$repo")

    # Get branches matching our patterns
    local patterns=("update-" "promote-")

    for pattern in "${patterns[@]}"; do
        local branches_response
        branches_response=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_repo}/repository/branches?search=${pattern}" 2>/dev/null) || continue

        # For each branch, check if there's a corresponding open MR
        local branch_names
        branch_names=$(echo "$branches_response" | jq -r '.[].name // empty' 2>/dev/null)

        for branch in $branch_names; do
            # Check if there's an open MR with this source branch
            local mr_check
            mr_check=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_repo}/merge_requests?state=opened&source_branch=${branch}" 2>/dev/null)

            local mr_count
            mr_count=$(echo "$mr_check" | jq -r 'length // 0' 2>/dev/null)

            if [[ "$mr_count" -eq 0 ]]; then
                # Branch exists without corresponding open MR - it's lingering
                STATE_LINGERING_BRANCHES+=("${repo}:${branch}")
            fi
        done
    done

    return 0
}

# ============================================================================
# PUBLIC FUNCTIONS
# ============================================================================

# Check if pipeline is quiescent (no open MRs, no running builds, no lingering branches)
# Returns: 0 if clean, 1 if dirty
# Sets: STATE_OPEN_MRS, STATE_RUNNING_BUILDS, STATE_QUEUED_BUILDS, STATE_LINGERING_BRANCHES
check_pipeline_quiescent() {
    _check_open_mrs
    _check_running_builds
    _check_lingering_branches

    local total_issues=0
    total_issues=$((${#STATE_OPEN_MRS[@]} + ${#STATE_RUNNING_BUILDS[@]} + ${#STATE_QUEUED_BUILDS[@]} + ${#STATE_LINGERING_BRANCHES[@]}))

    if [[ $total_issues -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Display current pipeline state (for reporting)
display_pipeline_state() {
    if [[ ${#STATE_OPEN_MRS[@]} -gt 0 ]]; then
        echo "  Open MRs:"
        for mr in "${STATE_OPEN_MRS[@]}"; do
            local repo iid title url
            IFS='|' read -r repo iid title url <<< "$mr"
            echo "    - ${repo} !${iid}: ${title}"
            echo "      ${url}"
        done
    fi

    if [[ ${#STATE_RUNNING_BUILDS[@]} -gt 0 ]]; then
        echo "  Running builds:"
        for build in "${STATE_RUNNING_BUILDS[@]}"; do
            echo "    - ${build}"
        done
    fi

    if [[ ${#STATE_QUEUED_BUILDS[@]} -gt 0 ]]; then
        echo "  Queued builds:"
        for build in "${STATE_QUEUED_BUILDS[@]}"; do
            echo "    - ${build}"
        done
    fi

    if [[ ${#STATE_LINGERING_BRANCHES[@]} -gt 0 ]]; then
        echo "  Lingering branches (no open MR):"
        for branch in "${STATE_LINGERING_BRANCHES[@]}"; do
            echo "    - ${branch}"
        done
    fi
}

# Clean up pipeline state - close MRs, cancel builds, delete branches
cleanup_pipeline_state() {
    local cleaned=0

    # Close open MRs
    for mr in "${STATE_OPEN_MRS[@]}"; do
        local repo iid
        IFS='|' read -r repo iid _ _ <<< "$mr"

        local encoded_repo=$(_ps_encode_project "$repo")
        local result
        result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -d "state_event=close" \
            "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_repo}/merge_requests/${iid}" 2>/dev/null)

        if echo "$result" | jq -e '.state == "closed"' &>/dev/null; then
            echo "    Closed MR !${iid} in ${repo}"
            cleaned=$((cleaned + 1))
        fi
    done

    # Cancel running builds
    local cookie_jar=$(mktemp)
    local crumb_file=$(mktemp)
    _ps_get_jenkins_crumb "$cookie_jar" "$crumb_file"

    # Build base curl command as array to handle arguments properly
    local curl_base=(curl -sk -X POST)
    curl_base+=(-b "$cookie_jar")
    curl_base+=(-u "$JENKINS_USER:$JENKINS_TOKEN")

    # Add crumb header if available
    if jq -e '.crumb' "$crumb_file" &>/dev/null; then
        local field value
        field=$(jq -r '.crumbRequestField' "$crumb_file")
        value=$(jq -r '.crumb' "$crumb_file")
        curl_base+=(-H "${field}:${value}")
    fi

    for build in "${STATE_RUNNING_BUILDS[@]}"; do
        local job_branch num
        IFS=':' read -r job_branch num <<< "$build"

        "${curl_base[@]}" "${JENKINS_URL_EXTERNAL}/job/${job_branch/\///job/}/${num}/stop" 2>/dev/null || true
        echo "    Stopped build ${job_branch} #${num}"
        cleaned=$((cleaned + 1))
    done

    # Cancel queued builds
    for queued in "${STATE_QUEUED_BUILDS[@]}"; do
        local queue_id
        IFS=':' read -r queue_id _ <<< "$queued"

        "${curl_base[@]}" "${JENKINS_URL_EXTERNAL}/queue/cancelItem?id=${queue_id}" 2>/dev/null || true
        echo "    Cancelled queued item ${queue_id}"
        cleaned=$((cleaned + 1))
    done

    rm -f "$cookie_jar" "$crumb_file"

    # Delete lingering branches
    local repo="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_repo=$(_ps_encode_project "$repo")

    for branch_entry in "${STATE_LINGERING_BRANCHES[@]}"; do
        local branch
        IFS=':' read -r _ branch <<< "$branch_entry"

        local encoded_branch
        encoded_branch=$(echo "$branch" | sed 's/\//%2F/g')

        local http_code
        http_code=$(curl -sk -X DELETE -w "%{http_code}" -o /dev/null -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_repo}/repository/branches/${encoded_branch}" 2>/dev/null) || true

        if [[ "$http_code" == "204" ]]; then
            echo "    Deleted branch ${branch}"
            cleaned=$((cleaned + 1))
        elif [[ "$http_code" == "404" ]]; then
            echo "    Branch ${branch} already deleted (404)"
        else
            echo "    Failed to delete branch ${branch} (HTTP $http_code)"
        fi
    done

    # Give GitLab time to update its branch index after deletions
    if [[ ${#STATE_LINGERING_BRANCHES[@]} -gt 0 ]]; then
        sleep 2
    fi

    echo "  Cleaned up ${cleaned} items"
    return 0
}
