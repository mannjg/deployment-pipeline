#!/bin/bash
# Test cleanup library
# Provides cleanup functions for test artifacts and resources

# Source common functions
CLEANUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLEANUP_LIB_DIR/common.sh"

# Cleanup test branches
cleanup_test_branches() {
    local repo_path=${1:-.}
    local max_age_hours=${2:-24}

    log_info "Cleaning up test branches older than ${max_age_hours} hours..."

    cd "$repo_path" || return 1

    local cutoff_time
    cutoff_time=$(date -d "${max_age_hours} hours ago" +%s 2>/dev/null || date -v-${max_age_hours}H +%s 2>/dev/null)

    local cleaned=0

    # Find branches matching e2e-test-* pattern
    for branch in $(git branch -r | grep "origin/e2e-test-" | sed 's/origin\///'); do
        local branch_time
        branch_time=$(git log -1 --format=%ct "origin/$branch" 2>/dev/null)

        if [ -n "$branch_time" ] && [ "$branch_time" -lt "$cutoff_time" ]; then
            log_info "Deleting old test branch: $branch"
            git push origin --delete "$branch" 2>&1 || log_warn "Failed to delete branch: $branch"
            cleaned=$((cleaned + 1))
        fi
    done

    log_info "Cleaned up $cleaned test branch(es)"
    return 0
}

# Cleanup test artifacts
cleanup_test_artifacts() {
    local artifacts_dir=${1:-/tmp}

    log_info "Cleaning up test artifacts in $artifacts_dir..."

    local cleaned=0

    # Clean up temp files matching e2e-state-* pattern
    for dir in "$artifacts_dir"/e2e-state-*; do
        if [ -d "$dir" ]; then
            log_debug "Removing: $dir"
            rm -rf "$dir" 2>&1 || log_warn "Failed to remove: $dir"
            cleaned=$((cleaned + 1))
        fi
    done

    log_info "Cleaned up $cleaned artifact director(ies)"
    return 0
}
