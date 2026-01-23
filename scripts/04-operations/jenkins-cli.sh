#!/bin/bash
# Jenkins CLI - Centralized Jenkins operations
#
# Usage:
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
  console <job> [build]     Get console output (default: lastBuild)
  status <job> [build]      Get build status as JSON (default: lastBuild)
  wait <job> [--timeout N]  Wait for build to complete (default: 300s)

Job Notation:
  Use slash notation: example-app/main, k8s-deployments/dev
  Automatically converts to Jenkins path: example-app/job/main

Examples:
  jenkins-cli.sh console example-app/main
  jenkins-cli.sh console example-app/main 138
  jenkins-cli.sh status k8s-deployments/dev
  jenkins-cli.sh wait example-app/main --timeout 600

Exit Codes:
  0 - Success
  1 - Error (network, auth, job not found)
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
        log_error "Usage: jenkins-cli.sh wait <job> [--timeout N]"
        exit 1
    fi

    local job="$1"
    shift

    local timeout=300
    local interval=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --interval) interval="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local elapsed=0
    local status_json

    echo "Waiting for ${job} to complete (timeout: ${timeout}s)..." >&2

    while (( elapsed < timeout )); do
        # Try to get status, continue on failure (build might not exist yet)
        if status_json=$(cmd_status "$job" 2>/dev/null); then
            local building result
            building=$(echo "$status_json" | jq -r '.building')
            result=$(echo "$status_json" | jq -r '.result // "BUILDING"')

            if [[ "$building" == "false" ]]; then
                echo "Build complete: $result" >&2
                echo "$status_json"
                return 0
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

# Main dispatch
case "${1:-}" in
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
        echo "Available commands: console, status, wait" >&2
        exit 1
        ;;
esac
