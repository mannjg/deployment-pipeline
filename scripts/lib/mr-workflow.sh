#!/bin/bash
# mr-workflow.sh - MR-based workflow helpers for operational scripts
#
# Provides high-level functions for the MR workflow pattern:
#   create feature branch → make changes → create MR → wait for CI → merge
#
# Source this file: source "$SCRIPT_DIR/../lib/mr-workflow.sh"
#
# Prerequisites:
#   - Credentials available (env vars or K8s secrets)
#
# Required environment variables (set by caller or fail):
#   - MR_WORKFLOW_TIMEOUT: seconds to wait for pipeline
#   - MR_WORKFLOW_POLL_INTERVAL: seconds between polls

set -euo pipefail

MR_WORKFLOW_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies (these validate their own requirements)
source "$MR_WORKFLOW_LIB_DIR/infra.sh"
source "$MR_WORKFLOW_LIB_DIR/credentials.sh"

# Preflight checks - fail fast if required variables not set
: "${MR_WORKFLOW_TIMEOUT:?MR_WORKFLOW_TIMEOUT must be set (e.g., 300)}"
: "${MR_WORKFLOW_POLL_INTERVAL:?MR_WORKFLOW_POLL_INTERVAL must be set (e.g., 10)}"

# Get credentials via require_* functions (fail-fast)
GITLAB_TOKEN=$(require_gitlab_token)
_JENKINS_CREDS=$(require_jenkins_credentials)
JENKINS_USER="${_JENKINS_CREDS%%:*}"
JENKINS_TOKEN="${_JENKINS_CREDS#*:}"

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

_mw_encode_project() {
    echo "$1" | sed 's/\//%2F/g'
}

_mw_encode_path() {
    echo "$1" | sed 's/\//%2F/g'
}

# ============================================================================
# BRANCH OPERATIONS
# ============================================================================

# Create a feature branch from a base branch
# Usage: mw_create_branch <project> <branch_name> <base_branch>
# Returns: 0 on success, 1 on failure
mw_create_branch() {
    local project="$1"
    local branch_name="$2"
    local base_branch="$3"

    local gitlab_cli="$MR_WORKFLOW_LIB_DIR/../04-operations/gitlab-cli.sh"

    if "$gitlab_cli" branch create "$project" "$branch_name" --from "$base_branch" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Delete a branch
# Usage: mw_delete_branch <project> <branch_name>
mw_delete_branch() {
    local project="$1"
    local branch_name="$2"

    local gitlab_cli="$MR_WORKFLOW_LIB_DIR/../04-operations/gitlab-cli.sh"
    "$gitlab_cli" branch delete "$project" "$branch_name" >/dev/null 2>&1 || true
}

# ============================================================================
# FILE OPERATIONS
# ============================================================================

# Commit multiple files to a branch in a single commit
# Usage: mw_commit_files <project> <branch> <commit_message> <file1:content1> [file2:content2] ...
# File content can be passed as base64 by prefixing with "base64:"
# Returns: 0 on success, 1 on failure
mw_commit_files() {
    local project="$1"
    local branch="$2"
    local commit_message="$3"
    shift 3

    local encoded_project=$(_mw_encode_project "$project")
    local gitlab_url="${GITLAB_URL_EXTERNAL}"
    local gitlab_token="${GITLAB_TOKEN}"

    # Build actions array
    local actions="["
    local first=true

    for file_spec in "$@"; do
        local file_path="${file_spec%%:*}"
        local content="${file_spec#*:}"

        # Check if content is base64 encoded
        local encoding="text"
        if [[ "$content" == base64:* ]]; then
            content="${content#base64:}"
            encoding="base64"
        fi

        # Check if file exists to determine action
        local encoded_path=$(_mw_encode_path "$file_path")
        local file_check=$(curl -sk -H "PRIVATE-TOKEN: $gitlab_token" \
            "$gitlab_url/api/v4/projects/$encoded_project/repository/files/$encoded_path?ref=$branch" 2>/dev/null)

        local action="create"
        if echo "$file_check" | jq -e '.file_name' >/dev/null 2>&1; then
            action="update"
        fi

        [[ "$first" == "true" ]] || actions+=","
        first=false

        # Escape content for JSON
        local escaped_content=$(echo "$content" | jq -Rs '.')

        actions+="{\"action\":\"$action\",\"file_path\":\"$file_path\",\"content\":$escaped_content,\"encoding\":\"$encoding\"}"
    done

    actions+="]"

    # Create commit
    local payload=$(jq -n \
        --arg branch "$branch" \
        --arg message "$commit_message" \
        --argjson actions "$actions" \
        '{branch: $branch, commit_message: $message, actions: $actions}')

    local result=$(curl -sk -X POST -H "PRIVATE-TOKEN: $gitlab_token" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$gitlab_url/api/v4/projects/$encoded_project/repository/commits" 2>/dev/null)

    if echo "$result" | jq -e '.id' >/dev/null 2>&1; then
        return 0
    else
        echo "Commit failed: $(echo "$result" | jq -r '.message // .error // "Unknown error"')" >&2
        return 1
    fi
}

# Get file content from a branch
# Usage: mw_get_file <project> <branch> <file_path>
# Returns: File content on stdout
mw_get_file() {
    local project="$1"
    local branch="$2"
    local file_path="$3"

    local gitlab_cli="$MR_WORKFLOW_LIB_DIR/../04-operations/gitlab-cli.sh"
    "$gitlab_cli" file get "$project" "$file_path" --ref "$branch" 2>/dev/null
}

# ============================================================================
# MR OPERATIONS
# ============================================================================

# Create an MR
# Usage: mw_create_mr <project> <source_branch> <target_branch> <title>
# Returns: MR IID on stdout, 0 on success, 1 on failure
mw_create_mr() {
    local project="$1"
    local source_branch="$2"
    local target_branch="$3"
    local title="$4"

    local encoded_project=$(_mw_encode_project "$project")
    local gitlab_url="${GITLAB_URL_EXTERNAL}"
    local gitlab_token="${GITLAB_TOKEN}"

    local response=$(curl -sk -X POST \
        -H "PRIVATE-TOKEN: $gitlab_token" \
        -H "Content-Type: application/json" \
        -d "{\"source_branch\":\"$source_branch\",\"target_branch\":\"$target_branch\",\"title\":\"$title\"}" \
        "$gitlab_url/api/v4/projects/$encoded_project/merge_requests" 2>/dev/null)

    local mr_iid=$(echo "$response" | jq -r '.iid // empty')

    if [[ -n "$mr_iid" ]]; then
        echo "$mr_iid"
        return 0
    else
        echo "MR creation failed: $(echo "$response" | jq -r '.message // .error // "Unknown error"')" >&2
        return 1
    fi
}

# Wait for MR pipeline (Jenkins CI) to complete
# Usage: mw_wait_for_mr_pipeline <project> <mr_iid> [timeout]
# Returns: 0 if passed, 1 if failed or timeout
mw_wait_for_mr_pipeline() {
    local project="$1"
    local mr_iid="$2"
    local timeout="${3:-$MR_WORKFLOW_TIMEOUT}"

    local encoded_project=$(_mw_encode_project "$project")
    local gitlab_url="${GITLAB_URL_EXTERNAL}"
    local gitlab_token="${GITLAB_TOKEN}"
    local jenkins_url="${JENKINS_URL_EXTERNAL}"
    local jenkins_user="${JENKINS_USER}"
    local jenkins_token="${JENKINS_TOKEN}"

    # Trigger Jenkins scan to discover the branch
    curl -sk -X POST -u "$jenkins_user:$jenkins_token" \
        "$jenkins_url/job/k8s-deployments/build?delay=0sec" >/dev/null 2>&1 || true

    local poll_interval="${MR_WORKFLOW_POLL_INTERVAL}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local mr_info=$(curl -sk -H "PRIVATE-TOKEN: $gitlab_token" \
            "$gitlab_url/api/v4/projects/$encoded_project/merge_requests/$mr_iid" 2>/dev/null)

        local pipeline_status=$(echo "$mr_info" | jq -r '.head_pipeline.status // empty')

        case "$pipeline_status" in
            success)
                return 0
                ;;
            failed)
                return 1
                ;;
        esac

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    return 1  # Timeout
}

# Merge an MR
# Usage: mw_merge_mr <project> <mr_iid>
# Returns: 0 on success, 1 on failure
mw_merge_mr() {
    local project="$1"
    local mr_iid="$2"

    local gitlab_cli="$MR_WORKFLOW_LIB_DIR/../04-operations/gitlab-cli.sh"

    if "$gitlab_cli" mr merge "$project" "$mr_iid" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# HIGH-LEVEL WORKFLOW
# ============================================================================

# Complete MR workflow: create branch → commit files → create MR → wait → merge
# Usage: mw_complete_mr_workflow <project> <base_branch> <branch_name> <title> <commit_message> <file1:content1> ...
# Returns: 0 on success, 1 on failure
# Sets: MW_RESULT_MR_IID, MW_RESULT_BRANCH
mw_complete_mr_workflow() {
    local project="$1"
    local base_branch="$2"
    local branch_name="$3"
    local title="$4"
    local commit_message="$5"
    shift 5

    MW_RESULT_MR_IID=""
    MW_RESULT_BRANCH="$branch_name"

    # Step 1: Create feature branch
    if ! mw_create_branch "$project" "$branch_name" "$base_branch"; then
        echo "Failed to create branch $branch_name" >&2
        return 1
    fi

    # Step 2: Commit files
    if ! mw_commit_files "$project" "$branch_name" "$commit_message" "$@"; then
        echo "Failed to commit files to $branch_name" >&2
        mw_delete_branch "$project" "$branch_name"
        return 1
    fi

    # Step 3: Create MR
    local mr_iid
    if ! mr_iid=$(mw_create_mr "$project" "$branch_name" "$base_branch" "$title"); then
        echo "Failed to create MR" >&2
        mw_delete_branch "$project" "$branch_name"
        return 1
    fi
    MW_RESULT_MR_IID="$mr_iid"

    # Step 4: Wait for pipeline
    if ! mw_wait_for_mr_pipeline "$project" "$mr_iid"; then
        echo "Pipeline failed or timed out for MR !$mr_iid" >&2
        return 1
    fi

    # Step 5: Merge
    if ! mw_merge_mr "$project" "$mr_iid"; then
        echo "Failed to merge MR !$mr_iid" >&2
        return 1
    fi

    # Step 6: Cleanup branch (GitLab auto-deletes on merge, but ensure)
    mw_delete_branch "$project" "$branch_name" || true

    return 0
}
