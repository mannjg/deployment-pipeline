#!/usr/bin/env bash
#
# Reset Demo State
#
# Establishes a well-defined starting point for demos by cleaning up ALL
# demo artifacts, regardless of which demo was run.
#
# Usage:
#   ./scripts/03-pipelines/reset-demo-state.sh
#
# Clean Starting Point:
#   - Jenkins queue cleared (no stale running/queued jobs)
#   - No stale local demo branches (uc-*, update-dev-*, promote-*)
#   - No orphaned GitLab demo branches
#   - No open MRs targeting dev, stage, or prod branches
#   - Shared files (Jenkinsfile, scripts/, CUE definitions) synced via promotion workflow
#   - App version at 1.0.0-SNAPSHOT
#
# What it does:
#   1. Clears Jenkins queue and aborts running k8s-deployments jobs
#   2. Deletes Jenkins agent pods to prevent stale job completion
#   3. Cleans up stale local demo branches (uc-*, update-dev-*, promote-*)
#   4. Closes ALL open MRs targeting environment branches (dev, stage, prod)
#   5. Deletes orphaned GitLab demo branches (those without MRs)
#   6. Syncs shared files via proper promotion workflow:
#      - Creates feature branch from dev with updates from main
#      - Merges to dev → auto-promotes to stage → auto-promotes to prod
#      - Respects the GitOps workflow (changes flow through promotion chain)
#   7. Resets example-app/pom.xml version to 1.0.0-SNAPSHOT
#
# What it preserves:
#   - env.cue files (they have valid CI/CD-managed images)
#   - Environment branches (dev, stage, prod, main)
#   - Environment-specific configuration (namespaces, replicas, etc.)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${BLUE}[->]${NC} $*"; }

# Load infrastructure config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
    source "$REPO_ROOT/config/infra.env"
else
    log_error "Cannot find config/infra.env"
    exit 1
fi

# =============================================================================
# Get Credentials
# =============================================================================
get_credentials() {
    log_step "Loading credentials..."

    # Get GITLAB_TOKEN (env var or K8s secret)
    GITLAB_TOKEN="${GITLAB_TOKEN:-}"
    if [[ -z "$GITLAB_TOKEN" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "${GITLAB_API_TOKEN_SECRET}" -n "${GITLAB_NAMESPACE}" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "$GITLAB_TOKEN" ]]; then
        log_error "GITLAB_TOKEN not set and could not retrieve from K8s secret"
        exit 1
    fi

    # Get Jenkins credentials
    JENKINS_USER="${JENKINS_USER:-}"
    JENKINS_TOKEN="${JENKINS_TOKEN:-}"
    if [[ -z "$JENKINS_USER" ]]; then
        JENKINS_USER=$(kubectl get secret "${JENKINS_ADMIN_SECRET}" -n "${JENKINS_NAMESPACE}" \
            -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi
    if [[ -z "$JENKINS_TOKEN" ]]; then
        JENKINS_TOKEN=$(kubectl get secret "${JENKINS_ADMIN_SECRET}" -n "${JENKINS_NAMESPACE}" \
            -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    GITLAB_URL="https://${GITLAB_HOST_EXTERNAL}"
    JENKINS_URL="${JENKINS_URL_EXTERNAL:-http://jenkins.local}"
    log_info "GitLab: $GITLAB_URL"
    log_info "Jenkins: $JENKINS_URL"
}

# =============================================================================
# Clean up Jenkins queue and running jobs
# =============================================================================
# Stops all running/queued Jenkins jobs for k8s-deployments to prevent stale
# promotion MRs from being created after demo reset.
cleanup_jenkins_queue() {
    log_step "Cleaning up Jenkins queue and running jobs..."

    if [[ -z "$JENKINS_USER" ]] || [[ -z "$JENKINS_TOKEN" ]]; then
        log_warn "Jenkins credentials not available, skipping queue cleanup"
        return 0
    fi

    local jenkins_auth="$JENKINS_USER:$JENKINS_TOKEN"

    # Fetch Jenkins CRUMB for CSRF protection (required for POST operations)
    local crumb_response=$(curl -sk -u "$jenkins_auth" "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null)
    local crumb_field=$(echo "$crumb_response" | jq -r '.crumbRequestField // empty' 2>/dev/null)
    local crumb_value=$(echo "$crumb_response" | jq -r '.crumb // empty' 2>/dev/null)

    if [[ -z "$crumb_field" ]] || [[ -z "$crumb_value" ]]; then
        log_warn "Could not fetch Jenkins CRUMB, POST operations may fail"
        local crumb_header=""
    else
        local crumb_header="-H $crumb_field:$crumb_value"
    fi

    # 1. Cancel all queued items (not just k8s-deployments - clear entire queue)
    log_info "Canceling queued Jenkins jobs..."
    local queue_items=$(curl -sk -u "$jenkins_auth" "$JENKINS_URL/queue/api/json" 2>/dev/null | \
        jq -r '.items[].id' 2>/dev/null || true)

    local canceled=0
    if [[ -n "$queue_items" ]]; then
        for item_id in $queue_items; do
            curl -sk -X POST -u "$jenkins_auth" $crumb_header \
                "$JENKINS_URL/queue/cancelItem?id=$item_id" >/dev/null 2>&1 && \
                canceled=$((canceled + 1))
        done
    fi
    log_info "  Canceled $canceled queued items"

    # 2. Abort running builds for k8s-deployments branches
    log_info "Aborting running Jenkins builds..."
    local aborted=0

    # Get all jobs under k8s-deployments multibranch pipeline
    local jobs=$(curl -sk -u "$jenkins_auth" "$JENKINS_URL/job/k8s-deployments/api/json" 2>/dev/null | \
        jq -r '.jobs[].name' 2>/dev/null || true)

    if [[ -n "$jobs" ]]; then
        for job_name in $jobs; do
            # URL-encode the job name (handle slashes, etc.)
            local encoded_job=$(echo "$job_name" | jq -sRr @uri)

            # Get running builds for this job
            local builds=$(curl -sk -u "$jenkins_auth" \
                "$JENKINS_URL/job/k8s-deployments/job/$encoded_job/api/json" 2>/dev/null | \
                jq -r '.builds[]? | select(.building == true) | .number' 2>/dev/null || true)

            for build_num in $builds; do
                if [[ -n "$build_num" ]]; then
                    curl -sk -X POST -u "$jenkins_auth" $crumb_header \
                        "$JENKINS_URL/job/k8s-deployments/job/$encoded_job/$build_num/stop" >/dev/null 2>&1 && \
                        aborted=$((aborted + 1))
                fi
            done
        done
    fi
    log_info "  Aborted $aborted running builds"

    # 3. Delete all Jenkins agent pods (except main Jenkins pod)
    log_info "Deleting Jenkins agent pods..."
    local deleted_pods=$(kubectl get pods -n "${JENKINS_NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | \
        grep -v "^jenkins-" | wc -l)

    kubectl get pods -n "${JENKINS_NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | \
        grep -v "^jenkins-" | \
        xargs -r kubectl delete pod -n "${JENKINS_NAMESPACE}" --force --grace-period=0 >/dev/null 2>&1 || true

    log_info "  Deleted $deleted_pods agent pods"

    # 4. Wait a moment for Jenkins to stabilize
    log_info "Waiting for Jenkins to stabilize..."
    sleep 5
}

# =============================================================================
# Clean up stale local demo branches
# =============================================================================
# Removes local branches matching demo patterns (uc-*, update-dev-*, promote-*)
# Preserves main, dev, stage, prod
cleanup_local_branches() {
    log_step "Cleaning up local demo branches..."

    local patterns=("uc-*" "update-dev-*" "promote-*")
    local deleted=0

    for pattern in "${patterns[@]}"; do
        local branches=$(git branch --list "$pattern" 2>/dev/null | sed 's/^[* ]*//')
        if [[ -n "$branches" ]]; then
            while IFS= read -r branch; do
                if [[ -n "$branch" ]]; then
                    git branch -D "$branch" >/dev/null 2>&1 && deleted=$((deleted + 1))
                fi
            done <<< "$branches"
        fi
    done

    if [[ $deleted -gt 0 ]]; then
        log_info "Deleted $deleted local demo branches"
    else
        log_info "No local demo branches to clean"
    fi
}

# =============================================================================
# Clean up orphaned GitLab branches (without MRs)
# =============================================================================
# Removes GitLab branches matching demo patterns that don't have open MRs
cleanup_gitlab_orphan_branches() {
    local project_path="$1"
    local encoded_project=$(echo "$project_path" | sed 's/\//%2F/g')

    log_step "Cleaning up orphaned GitLab demo branches..."

    local patterns=("uc-" "update-dev-" "promote-")
    local deleted=0

    # Get all branches from GitLab
    local branches_url="$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches?per_page=100"
    local all_branches=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$branches_url" 2>/dev/null | jq -r '.[].name')

    if [[ -z "$all_branches" ]]; then
        log_info "No branches found"
        return 0
    fi

    for branch in $all_branches; do
        # Skip environment branches
        if [[ "$branch" == "main" || "$branch" == "dev" || "$branch" == "stage" || "$branch" == "prod" ]]; then
            continue
        fi

        # Check if branch matches any demo pattern
        local is_demo_branch=false
        for pattern in "${patterns[@]}"; do
            if [[ "$branch" == ${pattern}* ]]; then
                is_demo_branch=true
                break
            fi
        done

        if [[ "$is_demo_branch" == true ]]; then
            # Delete the orphan branch
            local encoded_branch=$(echo "$branch" | jq -sRr @uri)
            curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$encoded_branch" \
                >/dev/null 2>&1 && deleted=$((deleted + 1))
        fi
    done

    if [[ $deleted -gt 0 ]]; then
        log_info "Deleted $deleted orphaned GitLab demo branches"
    else
        log_info "No orphaned GitLab demo branches to clean"
    fi
}

# =============================================================================
# Close ALL open MRs targeting environment branches
# =============================================================================
# This ensures a clean starting point regardless of what demo was run.
# The GitOps promotion flow creates MRs from various sources:
# - Feature branches (uc-c1-*, update-dev-*, promote-*)
# - Environment branches (dev→stage, stage→prod)
# All of these need to be closed for a clean reset.
close_all_env_mrs() {
    local project_path="$1"
    local encoded_project=$(echo "$project_path" | sed 's/\//%2F/g')

    log_info "Closing ALL open MRs targeting environment branches..."

    # Close MRs targeting each environment branch
    for target_branch in dev stage prod; do
        local api_url="$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_branch"
        local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$api_url" 2>/dev/null)

        if [[ -z "$mrs" ]] || [[ "$mrs" == "[]" ]]; then
            log_info "  $target_branch: no open MRs"
            continue
        fi

        # Get all MRs (no pattern filtering)
        local all_mrs=$(echo "$mrs" | jq -r '.[] | "\(.iid):\(.source_branch)"')

        if [[ -z "$all_mrs" ]]; then
            log_info "  $target_branch: no open MRs"
            continue
        fi

        local count=0
        while IFS=: read -r mr_iid source_branch; do
            if [[ -n "$mr_iid" ]]; then
                log_info "  Closing MR !$mr_iid ($source_branch → $target_branch)..."

                # Close the MR
                curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                    "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid" \
                    -d "state_event=close" >/dev/null 2>&1 || true

                # Delete the source branch ONLY if it's not an environment branch
                if [[ "$source_branch" != "dev" && "$source_branch" != "stage" && "$source_branch" != "prod" && "$source_branch" != "main" ]]; then
                    curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$source_branch" \
                        >/dev/null 2>&1 || true
                fi

                count=$((count + 1))
            fi
        done <<< "$all_mrs"

        log_info "  $target_branch: closed $count MRs"
    done
}

# =============================================================================
# Close MRs matching pattern (kept for backward compatibility)
# =============================================================================
close_mrs_matching() {
    local project_path="$1"
    local branch_pattern="$2"
    local target_branch="${3:-}"

    local encoded_project=$(echo "$project_path" | sed 's/\//%2F/g')

    # Build API URL
    local api_url="$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened"
    if [[ -n "$target_branch" ]]; then
        api_url="${api_url}&target_branch=$target_branch"
    fi

    # Get open MRs
    local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$api_url" 2>/dev/null)

    if [[ -z "$mrs" ]] || [[ "$mrs" == "[]" ]]; then
        log_info "No open MRs found"
        return 0
    fi

    # Find MRs matching the branch pattern
    local matching_mrs=$(echo "$mrs" | jq -r --arg pattern "$branch_pattern" \
        '.[] | select(.source_branch | test($pattern)) | "\(.iid):\(.source_branch)"')

    if [[ -z "$matching_mrs" ]]; then
        log_info "No MRs matching pattern: $branch_pattern"
        return 0
    fi

    local count=0
    while IFS=: read -r mr_iid source_branch; do
        if [[ -n "$mr_iid" ]]; then
            log_info "Closing MR !$mr_iid ($source_branch)..."

            # Close the MR
            curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid" \
                -d "state_event=close" >/dev/null 2>&1 || true

            # Delete the source branch
            curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$source_branch" \
                >/dev/null 2>&1 || true

            count=$((count + 1))
        fi
    done <<< "$matching_mrs"

    log_info "Closed $count MRs matching: $branch_pattern"
}

# =============================================================================
# Wait for Jenkins build to complete
# =============================================================================
wait_for_build() {
    local job_path="$1"  # e.g., "k8s-deployments/job/dev"
    local timeout_seconds="${2:-300}"
    local jenkins_auth="$JENKINS_USER:$JENKINS_TOKEN"
    local tmp_file="/tmp/jenkins_build_$$_$(echo "$job_path" | tr '/' '_').json"

    local start_time=$(date +%s)
    local last_build=""

    # Get current last build number (save to file to avoid jq pipe issues)
    curl -sk -u "$jenkins_auth" \
        "$JENKINS_URL/job/$job_path/lastBuild/api/json" > "$tmp_file" 2>/dev/null
    local initial_build=$(cat "$tmp_file" | jq -r '.number // empty' 2>/dev/null)

    log_info "  Waiting for new build on $job_path (current: #${initial_build:-none})..."

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -gt $timeout_seconds ]]; then
            log_warn "  Timeout waiting for build on $job_path"
            rm -f "$tmp_file"
            return 1
        fi

        # Check for new build (save to file to avoid jq pipe issues)
        curl -sk -u "$jenkins_auth" \
            "$JENKINS_URL/job/$job_path/lastBuild/api/json" > "$tmp_file" 2>/dev/null
        local build_num=$(cat "$tmp_file" | jq -r '.number // empty' 2>/dev/null)
        local building=$(cat "$tmp_file" | jq -r '.building // empty' 2>/dev/null)
        local result=$(cat "$tmp_file" | jq -r '.result // empty' 2>/dev/null)

        # If we have a new build that's finished
        if [[ -n "$build_num" ]] && [[ "$build_num" != "$initial_build" ]] && [[ "$building" == "false" ]]; then
            if [[ "$result" == "SUCCESS" ]]; then
                log_info "  Build #$build_num completed successfully"
                rm -f "$tmp_file"
                return 0
            else
                log_warn "  Build #$build_num failed with result: $result"
                rm -f "$tmp_file"
                return 1
            fi
        fi

        # If initial build is still running, wait for it
        if [[ -n "$build_num" ]] && [[ "$build_num" == "$initial_build" ]] && [[ "$building" == "false" ]]; then
            if [[ "$result" == "SUCCESS" ]]; then
                log_info "  Build #$build_num already completed successfully"
                rm -f "$tmp_file"
                return 0
            fi
        fi

        sleep 5
    done
}

# =============================================================================
# Merge a GitLab MR with retry logic for async mergeability (405 handling)
# =============================================================================
# GitLab's merge API can return 405 even when the merge succeeds due to
# async mergeability checking. This function handles that by checking the
# actual MR state after getting an error response.
merge_gitlab_mr() {
    local encoded_project="$1"
    local mr_iid="$2"
    local max_retries="${3:-3}"
    local retry_delay="${4:-2}"

    for ((i=1; i<=max_retries; i++)); do
        # Attempt the merge
        local merge_result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid/merge" 2>/dev/null)

        # Check if merge response indicates success
        if echo "$merge_result" | jq -e '.state == "merged"' > /dev/null 2>&1; then
            return 0
        fi

        # Got an error response - check actual MR state (might have merged despite 405)
        sleep 1
        local mr_state=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid" 2>/dev/null | \
            jq -r '.state // empty')

        if [[ "$mr_state" == "merged" ]]; then
            return 0
        fi

        # If still not merged and we have retries left, wait and try again
        if [[ $i -lt $max_retries ]]; then
            sleep "$retry_delay"
        fi
    done

    # Final check of MR state
    local final_state=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid" 2>/dev/null | \
        jq -r '.state // empty')

    if [[ "$final_state" == "merged" ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# Wait for promotion MR to appear and merge it
# =============================================================================
wait_and_merge_promotion_mr() {
    local target_branch="$1"  # stage or prod
    local timeout_seconds="${2:-180}"
    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    local start_time=$(date +%s)

    log_info "  Waiting for promotion MR to $target_branch..."

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -gt $timeout_seconds ]]; then
            log_warn "  Timeout waiting for promotion MR to $target_branch"
            return 1
        fi

        # Check for open MR targeting this branch from a promote-* branch
        local mr_info=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_branch" 2>/dev/null | \
            jq -r '.[] | select(.source_branch | startswith("promote-")) | "\(.iid):\(.source_branch)"' | head -1)

        if [[ -n "$mr_info" ]]; then
            local mr_iid=$(echo "$mr_info" | cut -d: -f1)
            local source_branch=$(echo "$mr_info" | cut -d: -f2)

            log_info "  Found MR !$mr_iid ($source_branch → $target_branch)"

            # Merge the MR (with retry logic for 405 handling)
            if merge_gitlab_mr "$encoded_project" "$mr_iid"; then
                log_info "  MR !$mr_iid merged successfully"
                return 0
            else
                log_warn "  Failed to merge MR !$mr_iid"
                return 1
            fi
        fi

        sleep 5
    done
}

# =============================================================================
# Sync files via proper promotion workflow (main → dev → stage → prod)
# =============================================================================
# Creates a feature branch from dev, updates shared files to match main,
# then lets the promotion workflow carry changes through stage and prod.
#
# Files synced (shared infrastructure):
#   - Jenkinsfile
#   - scripts/*
#   - services/core/app.cue, services/resources/deployment.cue
#
# Files NOT synced (environment-specific):
#   - env.cue (each env has its own images/config)
#   - manifests/* (generated per environment)
#
sync_via_promotion_workflow() {
    log_step "Syncing shared files via promotion workflow..."

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')
    local sync_branch="sync-main-$(date +%s)"

    # Create sync branch from dev (so it has dev's env.cue and manifests)
    log_info "Creating sync branch from dev: $sync_branch"

    # Create branch FROM DEV (so it has dev's env.cue and manifests)
    local create_result=$(curl -sk -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"branch\": \"$sync_branch\", \"ref\": \"dev\"}" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches" 2>/dev/null)

    if ! echo "$create_result" | jq -e '.name' > /dev/null 2>&1; then
        log_error "Failed to create sync branch"
        return 1
    fi

    # Files to sync from main (shared infrastructure, not env-specific)
    local files_to_sync=(
        "Jenkinsfile"
        "services/core/app.cue"
        "services/resources/deployment.cue"
    )

    # Also sync all scripts
    local script_files=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/tree?ref=main&path=scripts&recursive=true&per_page=100" 2>/dev/null | \
        jq -r '.[] | select(.type == "blob") | .path')

    # Update each file on the sync branch to match main
    log_info "Updating shared files to match main..."

    for file_path in "${files_to_sync[@]}" $script_files; do
        local encoded_file=$(echo "$file_path" | sed 's/\//%2F/g')

        # Get content from main
        local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

        if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
            continue
        fi

        local content_b64=$(echo "$main_content" | jq -r '.content')

        # Update file on sync branch
        local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"branch\": \"$sync_branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: sync $file_path from main\"}" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

        if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
            log_info "  $file_path: updated"
        fi
    done

    # Create MR from sync branch to dev
    log_info "Creating MR: $sync_branch → dev"
    local mr_result=$(curl -sk -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"source_branch\": \"$sync_branch\", \"target_branch\": \"dev\", \"title\": \"Sync shared files from main\", \"remove_source_branch\": true}" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests" 2>/dev/null)

    local mr_iid=$(echo "$mr_result" | jq -r '.iid // empty')
    if [[ -z "$mr_iid" ]]; then
        local error=$(echo "$mr_result" | jq -r '.message // "unknown error"' 2>/dev/null)
        # If no changes, that's fine
        if [[ "$error" == *"no commits"* ]] || [[ "$error" == *"no changes"* ]]; then
            log_info "No changes to sync - branches already match"
            curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$sync_branch" >/dev/null 2>&1
            return 0
        fi
        log_error "Failed to create MR to dev: $error"
        curl -sk -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/branches/$sync_branch" >/dev/null 2>&1
        return 1
    fi

    log_info "Created MR !$mr_iid"

    # Merge the MR to dev (with retry logic for 405 handling)
    log_info "Merging MR !$mr_iid to dev..."
    if ! merge_gitlab_mr "$encoded_project" "$mr_iid"; then
        log_error "Failed to merge MR !$mr_iid to dev"
        return 1
    fi

    log_info "MR merged to dev"

    # Wait for dev build to complete
    wait_for_build "k8s-deployments/job/dev" 300 || return 1

    # Wait for promotion MR to stage and merge it
    wait_and_merge_promotion_mr "stage" 180 || return 1

    # Wait for stage build to complete
    wait_for_build "k8s-deployments/job/stage" 300 || return 1

    # Wait for promotion MR to prod and merge it
    wait_and_merge_promotion_mr "prod" 180 || return 1

    # Wait for prod build to complete
    wait_for_build "k8s-deployments/job/prod" 300 || return 1

    log_info "Promotion workflow completed - all environments synced"
    return 0
}

# =============================================================================
# Remove demo labels from manifests on ALL environment branches
# =============================================================================
remove_demo_labels_from_manifests() {
    local label_pattern="$1"  # e.g., "cost-center"

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    # Manifest files to clean
    local manifest_files=(
        "manifests/exampleApp/exampleApp.yaml"
        "manifests/postgres/postgres.yaml"
    )

    # Clean all environment branches for full demo reset
    for branch in dev stage prod; do
        log_info "Cleaning manifests on $branch branch..."

        for manifest_path in "${manifest_files[@]}"; do
            local encoded_file=$(echo "$manifest_path" | sed 's/\//%2F/g')

            # Get current manifest
            local file_info=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=$branch" 2>/dev/null)

            if [[ -z "$file_info" ]] || ! echo "$file_info" | jq -e '.content' > /dev/null 2>&1; then
                continue
            fi

            local content=$(echo "$file_info" | jq -r '.content' | base64 -d)

            # Check if label exists in manifest
            if ! echo "$content" | grep -q "$label_pattern"; then
                continue
            fi

            # Remove lines containing the label pattern
            local cleaned_content=$(echo "$content" | grep -v "$label_pattern")
            local cleaned_b64=$(echo "$cleaned_content" | base64 -w0)

            # Update the manifest
            local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$cleaned_b64\", \"commit_message\": \"chore: remove $label_pattern labels for demo reset\"}" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

            if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
                log_info "  $branch/$manifest_path: cleaned"
            fi
        done
    done
}

# =============================================================================
# Sync Jenkinsfile from main to all environment branches
# =============================================================================
# This ensures all env branches have the latest pipeline logic, especially
# important for env-to-env MR support (dev→stage, stage→prod).
sync_jenkinsfile_to_env_branches() {
    log_step "Syncing Jenkinsfile to environment branches..."

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')
    local encoded_file="Jenkinsfile"

    # Get Jenkinsfile from main
    local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

    if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
        log_warn "Could not get Jenkinsfile from main branch"
        return 1
    fi

    local content_b64=$(echo "$main_content" | jq -r '.content')

    # Sync to each environment branch
    for branch in dev stage prod; do
        local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: sync Jenkinsfile from main\"}" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

        if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
            log_info "  $branch: synced"
        else
            local error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
            if [[ "$error" == *"already exists"* ]] || [[ "$error" == *"same content"* ]]; then
                log_info "  $branch: already up to date"
            else
                log_warn "  $branch: $error"
            fi
        fi
    done
}

# =============================================================================
# Sync scripts directory from main to all environment branches
# =============================================================================
# This ensures all env branches have the latest pipeline scripts, including
# promote-app-config.sh which handles platform layer promotion.
sync_scripts_to_env_branches() {
    log_step "Syncing scripts/ directory to environment branches..."

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    # List all files in scripts/ directory on main branch (recursive)
    local tree_url="$GITLAB_URL/api/v4/projects/$encoded_project/repository/tree?ref=main&path=scripts&recursive=true&per_page=100"
    local files=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$tree_url" 2>/dev/null | jq -r '.[] | select(.type == "blob") | .path')

    if [[ -z "$files" ]]; then
        log_warn "Could not list files in scripts/ directory"
        return 1
    fi

    # Sync each file to all environment branches
    for file_path in $files; do
        local encoded_file=$(echo "$file_path" | sed 's/\//%2F/g')

        # Get file content from main
        local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

        if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
            log_warn "Could not get $file_path from main branch"
            continue
        fi

        local content_b64=$(echo "$main_content" | jq -r '.content')

        log_info "Syncing $file_path..."
        for branch in dev stage prod; do
            # Try PUT first (update existing file)
            local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: sync $file_path from main\"}" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

            if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
                log_info "  $branch: synced"
            else
                local error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
                if [[ "$error" == *"doesn't exist"* ]] || [[ "$error" == *"does not exist"* ]]; then
                    # File doesn't exist - use POST to create it
                    result=$(curl -sk -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: add $file_path from main\"}" \
                        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

                    if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
                        log_info "  $branch: created"
                    else
                        local create_error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
                        log_warn "  $branch: failed to create - $create_error"
                    fi
                elif [[ "$error" == *"already exists"* ]] || [[ "$error" == *"same content"* ]]; then
                    log_info "  $branch: already up to date"
                else
                    log_warn "  $branch: $error"
                fi
            fi
        done
    done
}

# =============================================================================
# Reset CUE configuration on ALL environment branches
# =============================================================================
# This ensures a fully repeatable demo by resetting services/core/app.cue
# and other demo-modified files on dev, stage, and prod branches.
reset_cue_config() {
    log_step "Resetting CUE configuration on all environment branches..."

    local encoded_project=$(echo "$DEPLOYMENTS_REPO_PATH" | sed 's/\//%2F/g')

    # Files that demos might modify
    local cue_files=(
        "services/core/app.cue"
        "services/resources/deployment.cue"
    )

    for file_path in "${cue_files[@]}"; do
        local encoded_file=$(echo "$file_path" | sed 's/\//%2F/g')

        # Get file content from main branch
        local main_content=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file?ref=main" 2>/dev/null)

        if [[ -z "$main_content" ]] || ! echo "$main_content" | jq -e '.content' > /dev/null 2>&1; then
            log_warn "Could not get $file_path from main branch"
            continue
        fi

        local content_b64=$(echo "$main_content" | jq -r '.content')

        # Update all environment branches
        log_info "Syncing $file_path to environment branches..."
        for branch in dev stage prod; do
            local result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"branch\": \"$branch\", \"encoding\": \"base64\", \"content\": \"$content_b64\", \"commit_message\": \"chore: reset $file_path from main for demo\"}" \
                "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$encoded_file" 2>/dev/null)

            if echo "$result" | jq -e '.file_path' > /dev/null 2>&1; then
                log_info "  $branch: synced"
            else
                local error=$(echo "$result" | jq -r '.message // "unknown error"' 2>/dev/null)
                log_warn "  $branch: $error"
            fi
        done
    done

    # Remove demo-specific labels from manifests on all branches
    log_step "Removing demo labels from manifests..."
    remove_demo_labels_from_manifests "cost-center"
}

# =============================================================================
# Reset App Version
# =============================================================================
reset_app_version() {
    local target_version="${1:-1.0.0-SNAPSHOT}"
    local pom_file="$REPO_ROOT/example-app/pom.xml"

    log_step "Resetting app version to $target_version..."

    if [[ ! -f "$pom_file" ]]; then
        log_error "pom.xml not found at $pom_file"
        return 1
    fi

    # Get current version
    local current_version=$(grep -o '<version>[^<]*</version>' "$pom_file" | head -1 | sed 's/<[^>]*>//g')

    if [[ "$current_version" == "$target_version" ]]; then
        log_info "Version already at $target_version"
        return 0
    fi

    log_info "Current version: $current_version"
    log_info "Target version: $target_version"

    # Update the version (first occurrence only)
    sed -i "0,/<version>$current_version<\/version>/s/<version>$current_version<\/version>/<version>$target_version<\/version>/" "$pom_file"

    # Verify the change
    local new_version=$(grep -o '<version>[^<]*</version>' "$pom_file" | head -1 | sed 's/<[^>]*>//g')
    if [[ "$new_version" == "$target_version" ]]; then
        log_info "Version updated successfully"
    else
        log_error "Version update failed"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "=== Reset Demo State ==="
    echo ""
    echo "This script establishes a well-defined starting point for demos."
    echo ""
    echo "CLEAN STARTING POINT:"
    echo "  - Jenkins queue cleared (no stale running/queued jobs)"
    echo "  - No stale local demo branches"
    echo "  - No orphaned GitLab demo branches"
    echo "  - No open MRs targeting dev, stage, or prod branches"
    echo "  - Shared files synced via promotion workflow (main → dev → stage → prod)"
    echo "  - App version at 1.0.0-SNAPSHOT"
    echo ""

    get_credentials

    # CRITICAL: Clean up Jenkins first to prevent stale jobs from creating MRs
    # after we close existing ones
    cleanup_jenkins_queue

    # Clean up stale local demo branches
    cleanup_local_branches

    # Close ALL open MRs targeting environment branches
    # This handles all scenarios:
    # - Feature branch MRs (uc-c1-*, update-dev-*, etc.)
    # - Promotion MRs (promote-stage-*, promote-prod-*)
    # - GitOps promotion MRs (dev→stage, stage→prod)
    log_step "Closing ALL open MRs targeting environment branches..."
    close_all_env_mrs "$DEPLOYMENTS_REPO_PATH"

    # Clean up orphaned GitLab demo branches (those without MRs)
    cleanup_gitlab_orphan_branches "$DEPLOYMENTS_REPO_PATH"

    # Sync files via proper promotion workflow (main → dev → stage → prod)
    # This replaces direct syncs and respects the GitOps promotion flow
    sync_via_promotion_workflow

    # Reset app version
    reset_app_version "1.0.0-SNAPSHOT"

    echo ""
    echo "=== Reset Complete ==="
    echo ""
    log_info "Clean starting point established:"
    log_info "  - Jenkins queue cleared, agent pods deleted"
    log_info "  - Local demo branches cleaned up"
    log_info "  - All env-targeting MRs closed"
    log_info "  - Orphaned GitLab demo branches deleted"
    log_info "  - Shared files synced via promotion workflow (main → dev → stage → prod)"
    log_info "  - App version at 1.0.0-SNAPSHOT"
    echo ""
    log_info "Next steps:"
    log_info "  1. Commit any local changes: git add -A && git commit -m 'chore: reset demo state'"
    log_info "  2. Push to GitHub: git push origin main"
    log_info "  3. Run validation: ./scripts/test/validate-pipeline.sh"
    log_info "  4. Run demo: ./scripts/demo/demo-uc-c1-default-label.sh"
}

main "$@"
