#!/bin/bash
# Git operations helper library for E2E pipeline testing

# Get the repository root directory
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Get current branch name
get_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Check if a branch exists locally
branch_exists_local() {
    local branch=$1
    git rev-parse --verify "$branch" &>/dev/null
}

# Check if a branch exists on remote
branch_exists_remote() {
    local branch=$1
    local remote=${2:-origin}
    git ls-remote --heads "$remote" "$branch" | grep -q "$branch"
}

# Create a new branch from current HEAD
# Usage: create_branch BRANCH_NAME
create_branch() {
    local branch=$1

    log_debug "Creating branch: $branch"

    if branch_exists_local "$branch"; then
        log_warn "Branch $branch already exists locally"
        git checkout "$branch"
        return 0
    fi

    git checkout -b "$branch"
    return $?
}

# Switch to an existing branch
# Usage: switch_branch BRANCH_NAME
switch_branch() {
    local branch=$1

    log_debug "Switching to branch: $branch"

    git checkout "$branch" 2>&1
    return $?
}

# Create a test commit with a benign change
# Usage: create_test_commit MESSAGE [FILE]
create_test_commit() {
    local message=$1
    local file=${2:-"TEST_COMMIT.txt"}

    log_debug "Creating test commit: $message"

    # Create or update a test file with timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "E2E Test Commit" > "$file"
    echo "Timestamp: $timestamp" >> "$file"
    echo "Message: $message" >> "$file"

    git add "$file"
    git commit -m "$message"

    return $?
}

# Create a test commit that modifies a version file (more realistic)
# Usage: create_version_bump_commit VERSION_FILE NEW_VERSION MESSAGE
create_version_bump_commit() {
    local version_file=$1
    local new_version=$2
    local message=$3

    log_debug "Bumping version in $version_file to $new_version"

    # Check if file exists
    if [ ! -f "$version_file" ]; then
        log_warn "Version file $version_file does not exist, creating it"
        echo "$new_version" > "$version_file"
    else
        # Update the version
        echo "$new_version" > "$version_file"
    fi

    git add "$version_file"
    git commit -m "$message"

    return $?
}

# Push branch to remote
# Usage: push_branch BRANCH_NAME [REMOTE]
push_branch() {
    local branch=$1
    local remote=${2:-origin}

    log_info "Pushing branch $branch to $remote"

    git push -u "$remote" "$branch" 2>&1
    local result=$?

    if [ $result -eq 0 ]; then
        log_pass "Branch $branch pushed to $remote"
    else
        log_error "Failed to push branch $branch"
    fi

    return $result
}

# Delete a local branch
# Usage: delete_local_branch BRANCH_NAME
delete_local_branch() {
    local branch=$1

    log_debug "Deleting local branch: $branch"

    # First ensure we're not on that branch
    local current_branch
    current_branch=$(get_current_branch)

    if [ "$current_branch" = "$branch" ]; then
        log_debug "Switching away from branch to delete"
        git checkout main 2>/dev/null || git checkout master 2>/dev/null
    fi

    git branch -D "$branch" 2>&1
    return $?
}

# Delete a remote branch
# Usage: delete_remote_branch BRANCH_NAME [REMOTE]
delete_remote_branch() {
    local branch=$1
    local remote=${2:-origin}

    log_debug "Deleting remote branch: $remote/$branch"

    git push "$remote" --delete "$branch" 2>&1
    return $?
}

# Get the last commit SHA
# Usage: get_last_commit_sha [BRANCH]
get_last_commit_sha() {
    local branch=${1:-HEAD}

    git rev-parse "$branch" 2>/dev/null
}

# Get the last commit message
# Usage: get_last_commit_message [BRANCH]
get_last_commit_message() {
    local branch=${1:-HEAD}

    git log -1 --pretty=%B "$branch" 2>/dev/null
}

# Fetch latest changes from remote
# Usage: fetch_remote [REMOTE]
fetch_remote() {
    local remote=${1:-origin}

    log_debug "Fetching from remote: $remote"

    git fetch "$remote" 2>&1
    return $?
}

# Pull latest changes for current branch
# Usage: pull_current_branch
pull_current_branch() {
    local branch
    branch=$(get_current_branch)

    log_debug "Pulling latest changes for branch: $branch"

    git pull origin "$branch" 2>&1
    return $?
}

# Create a feature branch for E2E testing
# Usage: create_e2e_feature_branch BASE_BRANCH
create_e2e_feature_branch() {
    local base_branch=$1
    local timestamp
    timestamp=$(date +%s)
    local feature_branch="e2e-test-${timestamp}"

    log_info "Creating E2E feature branch: $feature_branch from $base_branch"

    # Ensure we have latest base branch
    fetch_remote origin

    # Switch to base branch and pull latest
    switch_branch "$base_branch" || return 1
    pull_current_branch || return 1

    # Create feature branch
    create_branch "$feature_branch" || return 1

    echo "$feature_branch"
    return 0
}

# Cleanup E2E test branches (both local and remote)
# Usage: cleanup_e2e_branches [MAX_AGE_DAYS]
cleanup_e2e_branches() {
    local max_age_days=${1:-1}

    log_info "Cleaning up E2E test branches older than $max_age_days days"

    # Find and delete old E2E branches
    local branches
    branches=$(git branch -a | grep -E 'e2e-test-[0-9]+' | sed 's/remotes\/origin\///')

    for branch in $branches; do
        local branch_clean
        branch_clean=$(echo "$branch" | xargs)

        # Extract timestamp from branch name
        local branch_timestamp
        branch_timestamp=$(echo "$branch_clean" | grep -oE '[0-9]+$')

        if [ -n "$branch_timestamp" ]; then
            local current_timestamp
            current_timestamp=$(date +%s)
            local age_seconds=$((current_timestamp - branch_timestamp))
            local age_days=$((age_seconds / 86400))

            if [ "$age_days" -gt "$max_age_days" ]; then
                log_debug "Deleting old branch: $branch_clean (age: $age_days days)"

                # Delete local if exists
                if branch_exists_local "$branch_clean"; then
                    delete_local_branch "$branch_clean" 2>/dev/null
                fi

                # Delete remote if exists
                if branch_exists_remote "$branch_clean"; then
                    delete_remote_branch "$branch_clean" 2>/dev/null
                fi
            fi
        fi
    done

    return 0
}

# Verify repository is in clean state
# Usage: verify_clean_state
verify_clean_state() {
    log_debug "Verifying repository is in clean state"

    local status
    status=$(git status --porcelain)

    if [ -n "$status" ]; then
        log_warn "Repository has uncommitted changes:"
        echo "$status"
        return 1
    fi

    log_debug "Repository is clean"
    return 0
}

# Get the remote URL
# Usage: get_remote_url [REMOTE]
get_remote_url() {
    local remote=${1:-origin}

    git remote get-url "$remote" 2>/dev/null
}

# Extract GitLab project ID from remote URL
# Usage: get_gitlab_project_id [REMOTE]
get_gitlab_project_id() {
    local remote=${1:-origin}

    local url
    url=$(get_remote_url "$remote")

    # Extract project path from URL
    # Examples:
    #   https://gitlab.example.com/group/project.git -> group/project
    #   git@gitlab.example.com:group/project.git -> group/project
    local project_path
    project_path=$(echo "$url" | sed -E 's|.*[:/]([^/]+/[^/]+)\.git|\1|')

    if [ -n "$project_path" ]; then
        # URL encode the project path for API calls
        echo "$project_path" | sed 's|/|%2F|g'
    else
        log_error "Could not extract project path from remote URL: $url"
        return 1
    fi
}

# Stash current changes
# Usage: stash_changes [MESSAGE]
stash_changes() {
    local message=${1:-"E2E test stash"}

    log_debug "Stashing changes: $message"

    git stash push -m "$message"
    return $?
}

# Pop stashed changes
# Usage: pop_stash
pop_stash() {
    log_debug "Popping stashed changes"

    git stash pop
    return $?
}
