#!/bin/bash
# Jenkins CLI - Centralized Jenkins operations
#
# Usage:
#   jenkins-cli.sh trigger <job>           - Trigger a new build
#   jenkins-cli.sh console <job> [build]   - Get console output
#   jenkins-cli.sh status <job> [build]    - Get build status (JSON)
#   jenkins-cli.sh wait <job> [--timeout]  - Wait for build to complete
#
# Job notation: Use slash notation (example-app/main) which maps to
# Jenkins MultiBranch paths (example-app/job/main)
#
# Examples:
#   jenkins-cli.sh console example-app/main
#   jenkins-cli.sh console example-app/main 138
#   jenkins-cli.sh status k8s-deployments/dev
#   jenkins-cli.sh wait example-app/main --timeout 600

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get Jenkins auth once
JENKINS_AUTH=$(require_jenkins_credentials)
JENKINS_URL="${JENKINS_URL_EXTERNAL}"

# Convert slash notation to Jenkins API path
# example-app/main -> example-app/job/main
to_jenkins_path() {
    local input="$1"
    echo "$input" | sed 's|/|/job/|g'
}

show_help() {
    cat << 'EOF'
Jenkins CLI - Centralized Jenkins operations

Usage:
  jenkins-cli.sh <command> <job> [options]

Commands:
  trigger <job>             Trigger a new build
  console <job> [build]     Get console output (default: lastBuild)
  status <job> [build]      Get build status as JSON (default: lastBuild)
  wait <job> [options]      Wait for build to complete

Wait Options:
  --timeout N     Timeout in seconds (default: 300)
  --after N       Only accept builds started after timestamp (ms since epoch)
                  Useful to avoid race conditions with fast builds
  --interval N    Poll interval in seconds (default: 10)

Job Notation:
  Use slash notation: example-app/main, k8s-deployments/dev
  Automatically converts to Jenkins path: example-app/job/main

Examples:
  jenkins-cli.sh trigger k8s-deployments/stage
  jenkins-cli.sh console example-app/main
  jenkins-cli.sh console example-app/main 138
  jenkins-cli.sh status k8s-deployments/dev
  jenkins-cli.sh wait example-app/main --timeout 600
  jenkins-cli.sh wait k8s-deployments/dev --after 1737750000000

Exit Codes:
  0 - Success
  1 - Error (network, auth, job not found, build failed)
  2 - Timeout (wait command)
EOF
    exit 0
}

cmd_console() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: jenkins-cli.sh console <job> [build]"
        exit 1
    fi

    local job_path build_num="${2:-lastBuild}"
    job_path=$(to_jenkins_path "$1")

    local url="${JENKINS_URL}/job/${job_path}/${build_num}/consoleText"

    if ! curl -sfk -u "$JENKINS_AUTH" "$url" 2>/dev/null; then
        log_error "Failed to fetch console for ${1} build ${build_num}"
        log_error "URL: $url"
        exit 1
    fi
}

cmd_status() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: jenkins-cli.sh status <job> [build]"
        exit 1
    fi

    local job_path build_num="${2:-lastBuild}"
    job_path=$(to_jenkins_path "$1")

    local url="${JENKINS_URL}/job/${job_path}/${build_num}/api/json"
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    if ! curl -sfk -u "$JENKINS_AUTH" "$url" > "$tmp_file" 2>/dev/null; then
        log_error "Failed to fetch status for ${1} build ${build_num}"
        log_error "URL: $url"
        exit 1
    fi

    # Output minimal JSON with key fields
    jq '{number, result, building, timestamp, duration, url}' "$tmp_file"
}

cmd_wait() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: jenkins-cli.sh wait <job> [--timeout N] [--after TIMESTAMP]"
        exit 1
    fi

    local job="$1"
    shift

    local timeout=300
    local interval=10
    local after_timestamp=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --interval) interval="$2"; shift 2 ;;
            --after) after_timestamp="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local elapsed=0
    local status_json

    if [[ $after_timestamp -gt 0 ]]; then
        echo "Waiting for ${job} build started after $(date -d @$((after_timestamp/1000)) '+%H:%M:%S' 2>/dev/null || date -r $((after_timestamp/1000)) '+%H:%M:%S' 2>/dev/null || echo "timestamp $after_timestamp") (timeout: ${timeout}s)..." >&2
    else
        echo "Waiting for ${job} to complete (timeout: ${timeout}s)..." >&2
    fi

    while (( elapsed < timeout )); do
        # Try to get status, continue on failure (build might not exist yet)
        if status_json=$(cmd_status "$job" 2>/dev/null); then
            local building result build_timestamp
            building=$(echo "$status_json" | jq -r '.building')
            result=$(echo "$status_json" | jq -r '.result // "BUILDING"')
            build_timestamp=$(echo "$status_json" | jq -r '.timestamp // 0')

            # If --after specified, skip builds that started before that time
            if [[ $after_timestamp -gt 0 ]] && [[ $build_timestamp -lt $after_timestamp ]]; then
                echo "Current build started before trigger, waiting for new build... (${elapsed}s elapsed)" >&2
                sleep "$interval"
                ((elapsed += interval))
                continue
            fi

            if [[ "$building" == "false" ]]; then
                echo "Build complete: $result" >&2
                echo "$status_json"
                if [[ "$result" == "SUCCESS" ]]; then
                    return 0
                else
                    return 1
                fi
            fi

            local build_num
            build_num=$(echo "$status_json" | jq -r '.number')
            echo "Build #${build_num} in progress... (${elapsed}s elapsed)" >&2
        else
            echo "Waiting for build to start... (${elapsed}s elapsed)" >&2
        fi

        sleep "$interval"
        ((elapsed += interval))
    done

    log_error "Timeout waiting for build after ${timeout}s"
    return 2
}

cmd_trigger() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: jenkins-cli.sh trigger <job>"
        exit 1
    fi

    local job_path
    job_path=$(to_jenkins_path "$1")

    # Get CSRF crumb with session cookies
    local cookie_jar
    cookie_jar=$(mktemp)
    trap "rm -f '$cookie_jar'" RETURN

    local crumb_json crumb crumb_field
    crumb_json=$(curl -sfk -u "$JENKINS_AUTH" -c "$cookie_jar" "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null) || {
        log_error "Failed to get Jenkins crumb"
        exit 1
    }
    crumb=$(echo "$crumb_json" | jq -r '.crumb')
    crumb_field=$(echo "$crumb_json" | jq -r '.crumbRequestField')

    # Trigger the build
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" -u "$JENKINS_AUTH" \
        -b "$cookie_jar" \
        -H "${crumb_field}: ${crumb}" \
        -X POST "${JENKINS_URL}/job/${job_path}/build")

    if [[ "$http_code" == "201" ]]; then
        log_info "Build triggered for $1"
        return 0
    else
        log_error "Failed to trigger build (HTTP $http_code)"
        return 1
    fi
}

# Main dispatch
case "${1:-}" in
    trigger) shift; cmd_trigger "$@" ;;
    console) shift; cmd_console "$@" ;;
    status)  shift; cmd_status "$@" ;;
    wait)    shift; cmd_wait "$@" ;;
    -h|--help) show_help ;;
    "")
        log_error "No command specified"
        echo "" >&2
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        echo "" >&2
        echo "Available commands: trigger, console, status, wait" >&2
        exit 1
        ;;
esac
