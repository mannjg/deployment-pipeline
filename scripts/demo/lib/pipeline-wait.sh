#!/bin/bash
# pipeline-wait.sh - MR, Jenkins, and ArgoCD helpers for demo scripts
#
# Source this file: source "$(dirname "$0")/lib/pipeline-wait.sh"
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - config/infra.env sourced
#   - demo-helpers.sh sourced (for demo_action, demo_verify, etc.)
#   - GITLAB_TOKEN, JENKINS_USER, JENKINS_TOKEN set (or loaded from secrets)

# ============================================================================
# CONFIGURATION
# ============================================================================

PIPELINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PIPELINE_LIB_DIR/../../.." && pwd)"

# Load infrastructure config if not already loaded
if [[ -z "${GITLAB_URL_EXTERNAL:-}" ]]; then
    if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
        source "$REPO_ROOT/config/infra.env"
    else
        echo "ERROR: config/infra.env not found and GITLAB_URL_EXTERNAL not set"
        exit 1
    fi
fi

# Default timeouts (can be overridden)
MR_CREATE_TIMEOUT="${MR_CREATE_TIMEOUT:-30}"
MR_PIPELINE_TIMEOUT="${MR_PIPELINE_TIMEOUT:-180}"
JENKINS_BUILD_START_TIMEOUT="${JENKINS_BUILD_START_TIMEOUT:-60}"
JENKINS_BUILD_TIMEOUT="${JENKINS_BUILD_TIMEOUT:-120}"
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-120}"

# ============================================================================
# CREDENTIAL LOADING
# ============================================================================

# Load credentials from K8s secrets if not already set
load_pipeline_credentials() {
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${JENKINS_USER:-}" ]]; then
        JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    # Verify credentials loaded
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        demo_fail "GITLAB_TOKEN not available"
        return 1
    fi
    if [[ -z "${JENKINS_USER:-}" ]] || [[ -z "${JENKINS_TOKEN:-}" ]]; then
        demo_fail "Jenkins credentials not available"
        return 1
    fi

    return 0
}

# ============================================================================
# GITLAB MR OPERATIONS
# ============================================================================

# URL-encode a project path
_encode_project() {
    echo "$1" | sed 's/\//%2F/g'
}

# Create a merge request and return the MR IID
# Usage: create_mr <source_branch> <target_branch> <title> [description]
# Returns: MR IID on stdout, or exits on failure
create_mr() {
    local source_branch="$1"
    local target_branch="$2"
    local title="$3"
    local description="${4:-Automated MR from demo script}"

    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    demo_action "Creating MR: $source_branch → $target_branch"

    local response
    response=$(curl -sk -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"source_branch\":\"$source_branch\",\"target_branch\":\"$target_branch\",\"title\":\"$title\",\"description\":\"$description\"}" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests" 2>/dev/null)

    local mr_iid
    mr_iid=$(echo "$response" | jq -r '.iid // empty')

    if [[ -n "$mr_iid" ]]; then
        demo_verify "Created MR !$mr_iid"
        echo "$mr_iid"
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.message // .error // "Unknown error"')
        demo_fail "Failed to create MR: $error"
        return 1
    fi
}

# Get MR details
# Usage: get_mr <mr_iid>
get_mr() {
    local mr_iid="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests/$mr_iid" 2>/dev/null
}

# Get commit statuses from GitLab
# Usage: get_commit_statuses <commit_sha>
get_commit_statuses() {
    local commit_sha="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/repository/commits/${commit_sha}/statuses" 2>/dev/null
}

# Wait for Jenkins CI to report status on an MR
# Usage: wait_for_mr_pipeline <mr_iid> [timeout]
# Returns: 0 if passed, 1 if failed
#
# This project uses Jenkins for CI (not GitLab CI).
# Jenkins reports build status via GitLab commit status API.
wait_for_mr_pipeline() {
    local mr_iid="$1"
    local timeout="${2:-$MR_PIPELINE_TIMEOUT}"
    local job_name="${DEPLOYMENTS_REPO_NAME:-k8s-deployments}"

    demo_action "Waiting for Jenkins CI on MR !$mr_iid (timeout ${timeout}s)..."

    # Get MR SHA
    local mr_info
    mr_info=$(get_mr "$mr_iid")
    local source_sha
    source_sha=$(echo "$mr_info" | jq -r '.sha // empty')

    if [[ -z "$source_sha" ]]; then
        demo_fail "Could not get MR source SHA"
        return 1
    fi

    # Trigger Jenkins scan to discover the branch
    trigger_jenkins_scan "$job_name"

    local poll_interval=10
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local statuses
        statuses=$(get_commit_statuses "$source_sha")

        # Look for jenkins status (matches "jenkins/*" or "continuous-integration/jenkins/*")
        local jenkins_status
        jenkins_status=$(echo "$statuses" | jq -r '[.[] | select(.name | test("jenkins"; "i"))] | sort_by(.created_at) | last | .status // empty')

        case "$jenkins_status" in
            success)
                demo_verify "Jenkins CI passed"
                return 0
                ;;
            failed)
                demo_fail "Jenkins CI failed"
                return 1
                ;;
            pending|running)
                demo_info "Jenkins: $jenkins_status (${elapsed}s)"
                ;;
            *)
                demo_info "Waiting for Jenkins... (${elapsed}s)"
                ;;
        esac

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    demo_fail "Timeout waiting for Jenkins CI (${timeout}s)"
    return 1
}

# Accept/merge an MR
# Usage: accept_mr <mr_iid>
accept_mr() {
    local mr_iid="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    demo_action "Merging MR !$mr_iid..."

    local response
    response=$(curl -sk -X PUT \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests/$mr_iid/merge" 2>/dev/null)

    local state
    state=$(echo "$response" | jq -r '.state // .message // "unknown"')

    if [[ "$state" == "merged" ]]; then
        demo_verify "MR !$mr_iid merged"
        return 0
    else
        demo_fail "Failed to merge MR: $state"
        return 1
    fi
}

# Get MR diff to verify contents
# Usage: get_mr_diff <mr_iid>
get_mr_diff() {
    local mr_iid="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests/$mr_iid/changes" 2>/dev/null
}

# Assert MR diff contains expected content
# Usage: assert_mr_contains_diff <mr_iid> <file_pattern> <expected_content>
assert_mr_contains_diff() {
    local mr_iid="$1"
    local file_pattern="$2"
    local expected_content="$3"

    demo_action "Verifying MR !$mr_iid contains expected changes..."

    local changes
    changes=$(get_mr_diff "$mr_iid")

    # Check if any file matching pattern has the expected content in diff
    local matching_diff
    matching_diff=$(echo "$changes" | jq -r --arg pattern "$file_pattern" \
        '.changes[] | select(.new_path | test($pattern)) | .diff' 2>/dev/null)

    if [[ "$matching_diff" == *"$expected_content"* ]]; then
        demo_verify "MR diff contains '$expected_content' in files matching '$file_pattern'"
        return 0
    else
        demo_fail "MR diff does not contain '$expected_content' in files matching '$file_pattern'"
        return 1
    fi
}

# ============================================================================
# JENKINS OPERATIONS
# ============================================================================

# Trigger MultiBranch Pipeline scan
trigger_jenkins_scan() {
    local job_name="${1:-k8s-deployments}"

    demo_action "Triggering Jenkins branch scan for $job_name..."

    # Get CSRF crumb
    local cookie_jar=$(mktemp)
    local crumb_file=$(mktemp)

    curl -sk -c "$cookie_jar" -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL_EXTERNAL}/crumbIssuer/api/json" > "$crumb_file" 2>/dev/null || true

    local crumb_header=""
    if jq empty "$crumb_file" 2>/dev/null; then
        local crumb_field=$(jq -r '.crumbRequestField // empty' "$crumb_file")
        local crumb_value=$(jq -r '.crumb // empty' "$crumb_file")
        if [[ -n "$crumb_field" && -n "$crumb_value" ]]; then
            crumb_header="-H ${crumb_field}:${crumb_value}"
        fi
    fi

    # Trigger scan
    curl -sk -w "%{http_code}" -o /dev/null -X POST \
        -b "$cookie_jar" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        $crumb_header \
        "${JENKINS_URL_EXTERNAL}/job/${job_name}/build?delay=0sec" 2>/dev/null || true

    rm -f "$cookie_jar" "$crumb_file"

    sleep 3  # Give Jenkins time to start scanning
}

# Get current build number for a branch
# Usage: get_jenkins_build_number <branch>
get_jenkins_build_number() {
    local branch="$1"
    local job_name="${2:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    local response
    response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL_EXTERNAL}/${job_path}/lastBuild/api/json" 2>/dev/null) || true

    if echo "$response" | jq empty 2>/dev/null; then
        echo "$response" | jq -r '.number // 0'
    else
        echo "0"
    fi
}

# Wait for a new Jenkins build to complete
# Usage: wait_for_jenkins_build <branch> [baseline_build] [timeout]
wait_for_jenkins_build() {
    local branch="$1"
    local baseline="${2:-}"
    local timeout="${3:-$JENKINS_BUILD_TIMEOUT}"

    local job_name="${DEPLOYMENTS_REPO_NAME:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    # Trigger scan to ensure Jenkins sees the branch
    trigger_jenkins_scan "$job_name"

    # Get baseline if not provided
    if [[ -z "$baseline" ]]; then
        baseline=$(get_jenkins_build_number "$branch")
    fi

    demo_action "Waiting for Jenkins build on $branch (baseline #$baseline, timeout ${timeout}s)..."

    local poll_interval=10
    local elapsed=0
    local build_number=""
    local build_url=""

    # Wait for new build to start
    local start_timeout="${JENKINS_BUILD_START_TIMEOUT:-60}"
    while [[ $elapsed -lt $start_timeout ]]; do
        local current=$(get_jenkins_build_number "$branch")

        if [[ "$current" -gt "$baseline" ]]; then
            build_number="$current"
            build_url="${JENKINS_URL_EXTERNAL}/${job_path}/$build_number"
            demo_info "Build #$build_number started"
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        demo_fail "Timeout waiting for build to start (${start_timeout}s)"
        return 1
    fi

    # Wait for build to complete
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local build_info
        build_info=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" "$build_url/api/json" 2>/dev/null)

        local building=$(echo "$build_info" | jq -r '.building')
        local result=$(echo "$build_info" | jq -r '.result // "null"')

        if [[ "$building" == "false" ]]; then
            if [[ "$result" == "SUCCESS" ]]; then
                demo_verify "Build #$build_number completed successfully"
                return 0
            else
                demo_fail "Build #$build_number $result"
                return 1
            fi
        fi

        demo_info "Build #$build_number running... (${elapsed}s elapsed)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    demo_fail "Timeout waiting for build to complete (${timeout}s)"
    return 1
}

# ============================================================================
# ARGOCD OPERATIONS
# ============================================================================

# Get current ArgoCD sync revision
# Usage: get_argocd_revision <app_name>
get_argocd_revision() {
    local app_name="$1"
    local namespace="${ARGOCD_NAMESPACE:-argocd}"

    kubectl get application "$app_name" -n "$namespace" \
        -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo ""
}

# Trigger ArgoCD refresh
# Usage: trigger_argocd_refresh <app_name>
trigger_argocd_refresh() {
    local app_name="$1"
    local namespace="${ARGOCD_NAMESPACE:-argocd}"

    kubectl annotate application "$app_name" -n "$namespace" \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

# Wait for ArgoCD to sync
# Usage: wait_for_argocd_sync <app_name> [baseline_revision] [timeout]
wait_for_argocd_sync() {
    local app_name="$1"
    local baseline="${2:-}"
    local timeout="${3:-$ARGOCD_SYNC_TIMEOUT}"
    local namespace="${ARGOCD_NAMESPACE:-argocd}"

    # Get baseline if not provided
    if [[ -z "$baseline" ]]; then
        baseline=$(get_argocd_revision "$app_name")
    fi

    demo_action "Waiting for ArgoCD sync: $app_name (timeout ${timeout}s)..."

    # Trigger refresh
    trigger_argocd_refresh "$app_name"

    local poll_interval=10
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local app_status
        app_status=$(kubectl get application "$app_name" -n "$namespace" -o json 2>/dev/null)

        local sync_status=$(echo "$app_status" | jq -r '.status.sync.status // "Unknown"')
        local health_status=$(echo "$app_status" | jq -r '.status.health.status // "Unknown"')
        local current_revision=$(echo "$app_status" | jq -r '.status.sync.revision // ""')

        # Wait for revision to change AND status to be Synced+Healthy
        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$current_revision" != "$baseline" ]]; then
            demo_verify "$app_name synced and healthy"
            return 0
        fi

        demo_info "Status: sync=$sync_status health=$health_status rev=${current_revision:0:7} (${elapsed}s)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    demo_fail "Timeout waiting for ArgoCD sync (${timeout}s)"
    return 1
}

# ============================================================================
# COMBINED FLOWS
# ============================================================================

# Complete MR-gated promotion flow for one environment
# Usage: promote_via_mr <source_branch> <target_env> <title> [timeout]
promote_via_mr() {
    local source_branch="$1"
    local target_env="$2"
    local title="$3"
    local timeout="${4:-$MR_PIPELINE_TIMEOUT}"

    demo_info "Starting MR-gated promotion: $source_branch → $target_env"

    # Create MR
    local mr_iid
    mr_iid=$(create_mr "$source_branch" "$target_env" "$title") || return 1

    # Wait for pipeline
    wait_for_mr_pipeline "$mr_iid" "$timeout" || return 1

    # Merge
    accept_mr "$mr_iid" || return 1

    # Wait for ArgoCD
    local app_name="${APP_REPO_NAME:-example-app}-${target_env}"
    wait_for_argocd_sync "$app_name" || return 1

    demo_verify "Promotion to $target_env complete"
    return 0
}
