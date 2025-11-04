#!/bin/bash
# Jenkins API integration library for E2E pipeline testing

# Get Jenkins API URL
get_jenkins_api_url() {
    echo "${JENKINS_URL:-http://jenkins.jenkins.svc.cluster.local}"
}

# Check Jenkins API connectivity and authentication
check_jenkins_api() {
    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    log_debug "Checking Jenkins API connectivity..."

    if [ -z "${JENKINS_USER}" ]; then
        log_error "JENKINS_USER not set"
        return 1
    fi

    if [ -z "${JENKINS_TOKEN}" ]; then
        log_error "JENKINS_TOKEN not set"
        return 1
    fi

    local response
    response=$(curl -s -w "\n%{http_code}" \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${jenkins_url}/api/json" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "200" ]; then
        log_pass "Jenkins API accessible and credentials valid"
        return 0
    else
        log_error "Jenkins API check failed (HTTP $http_code)"
        return 1
    fi
}

# Get Jenkins crumb for CSRF protection
# Usage: get_jenkins_crumb
get_jenkins_crumb() {
    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    local crumb
    crumb=$(curl -s \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${jenkins_url}/crumbIssuer/api/json" | \
        jq -r '.crumb' 2>/dev/null)

    if [ -n "$crumb" ] && [ "$crumb" != "null" ]; then
        echo "$crumb"
        return 0
    else
        log_debug "No Jenkins crumb required (CSRF protection may be disabled)"
        echo ""
        return 0
    fi
}

# Trigger a Jenkins build
# Usage: trigger_jenkins_build JOB_NAME [PARAM1=value1] [PARAM2=value2] ...
trigger_jenkins_build() {
    local job_name=$1
    shift

    log_info "Triggering Jenkins job: $job_name"

    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    local crumb
    crumb=$(get_jenkins_crumb)

    # Build the curl command
    local curl_cmd=(
        curl -s -w "\n%{http_code}"
        --user "${JENKINS_USER}:${JENKINS_TOKEN}"
    )

    # Add crumb header if present
    if [ -n "$crumb" ]; then
        curl_cmd+=(--header "Jenkins-Crumb: ${crumb}")
    fi

    # Determine if we have parameters
    if [ $# -gt 0 ]; then
        # Build with parameters
        local params=""
        for param in "$@"; do
            if [ -n "$params" ]; then
                params="${params}&"
            fi
            params="${params}${param}"
        done

        curl_cmd+=(--request POST)
        curl_cmd+=("${jenkins_url}/job/${job_name}/buildWithParameters?${params}")
    else
        # Build without parameters
        curl_cmd+=(--request POST)
        curl_cmd+=("${jenkins_url}/job/${job_name}/build")
    fi

    local response
    response=$("${curl_cmd[@]}" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        log_pass "Jenkins job triggered: $job_name"

        # Get queue item from Location header (if available)
        local queue_item
        queue_item=$(echo "$response" | grep -i "Location:" | sed 's/.*queue\/item\/\([0-9]*\).*/\1/')

        if [ -n "$queue_item" ]; then
            log_debug "Job queued with item ID: $queue_item"
            echo "$queue_item"
        fi

        return 0
    else
        log_error "Failed to trigger Jenkins job (HTTP $http_code)"
        echo "$response" | sed '$d'
        return 1
    fi
}

# Get build number from queue item
# Usage: get_build_number_from_queue QUEUE_ITEM_ID [TIMEOUT]
get_build_number_from_queue() {
    local queue_item=$1
    local timeout=${2:-60}

    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    log_debug "Waiting for build to start (queue item: $queue_item)..."

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local build_number
        build_number=$(curl -s \
            --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${jenkins_url}/queue/item/${queue_item}/api/json" | \
            jq -r '.executable.number' 2>/dev/null)

        if [ -n "$build_number" ] && [ "$build_number" != "null" ]; then
            log_debug "Build started: #${build_number}"
            echo "$build_number"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Timeout waiting for build to start"
    return 1
}

# Wait for Jenkins build to complete
# Usage: wait_for_build_completion JOB_NAME BUILD_NUMBER [TIMEOUT]
wait_for_build_completion() {
    local job_name=$1
    local build_number=$2
    local timeout=${3:-600}

    log_info "Waiting for Jenkins build #${build_number} to complete..."

    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    local elapsed=0
    local last_stage=""

    while [ $elapsed -lt $timeout ]; do
        local build_info
        build_info=$(curl -s \
            --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${jenkins_url}/job/${job_name}/${build_number}/api/json")

        local building
        building=$(echo "$build_info" | jq -r '.building')

        local result
        result=$(echo "$build_info" | jq -r '.result')

        # Show progress if we can extract stage info
        local current_stage
        current_stage=$(echo "$build_info" | jq -r '.stages[]? | select(.status == "IN_PROGRESS") | .name' 2>/dev/null | head -n1)

        if [ -n "$current_stage" ] && [ "$current_stage" != "$last_stage" ]; then
            log_debug "Build progress: $current_stage"
            last_stage="$current_stage"
        fi

        if [ "$building" = "false" ]; then
            if [ "$result" = "SUCCESS" ]; then
                log_pass "Jenkins build #${build_number} completed successfully"
                return 0
            else
                log_error "Jenkins build #${build_number} failed with result: $result"
                return 1
            fi
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_error "Timeout waiting for Jenkins build to complete"
    return 1
}

# Get build status
# Usage: get_build_status JOB_NAME BUILD_NUMBER
get_build_status() {
    local job_name=$1
    local build_number=$2

    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    curl -s \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${jenkins_url}/job/${job_name}/${build_number}/api/json" | \
        jq -r '.result'
}

# Get build console output
# Usage: get_build_console_output JOB_NAME BUILD_NUMBER [LINES]
get_build_console_output() {
    local job_name=$1
    local build_number=$2
    local lines=${3:-100}

    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    local output
    output=$(curl -s \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${jenkins_url}/job/${job_name}/${build_number}/consoleText")

    if [ -n "$lines" ] && [ "$lines" != "all" ]; then
        echo "$output" | tail -n "$lines"
    else
        echo "$output"
    fi
}

# Get the latest build number for a job
# Usage: get_latest_build_number JOB_NAME
get_latest_build_number() {
    local job_name=$1

    local jenkins_url
    jenkins_url=$(get_jenkins_api_url)

    curl -s \
        --user "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${jenkins_url}/job/${job_name}/api/json" | \
        jq -r '.lastBuild.number'
}

# Trigger build and wait for completion
# Usage: trigger_and_wait JOB_NAME [TIMEOUT] [PARAM1=value1] [PARAM2=value2] ...
trigger_and_wait() {
    local job_name=$1
    local timeout=${2:-600}
    shift 2

    # Trigger the build
    local queue_item
    queue_item=$(trigger_jenkins_build "$job_name" "$@")

    if [ $? -ne 0 ]; then
        log_error "Failed to trigger Jenkins build"
        return 1
    fi

    # If we got a queue item, wait for build number
    local build_number
    if [ -n "$queue_item" ]; then
        build_number=$(get_build_number_from_queue "$queue_item" 60)
    else
        # Fall back to polling for latest build
        sleep 5
        build_number=$(get_latest_build_number "$job_name")
    fi

    if [ -z "$build_number" ] || [ "$build_number" = "null" ]; then
        log_error "Could not determine build number"
        return 1
    fi

    # Wait for completion
    wait_for_build_completion "$job_name" "$build_number" "$timeout"
    return $?
}
