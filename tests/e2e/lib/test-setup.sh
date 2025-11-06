#!/bin/bash
# E2E Test Initialization and Cleanup
# Validates services, git state, and cleans up stale test artifacts

# Configuration defaults (can be overridden by environment variables)
E2E_MAX_BRANCH_AGE_HOURS=${E2E_MAX_BRANCH_AGE_HOURS:-24}
E2E_SKIP_CLEANUP=${E2E_SKIP_CLEANUP:-false}
E2E_SERVICE_TIMEOUT=${E2E_SERVICE_TIMEOUT:-10}

# Validate that all required services are accessible
validate_services() {
    log_info "Validating service connectivity..." >&2

    local failures=0

    # Check GitLab API
    if [ -n "${GITLAB_TOKEN:-}" ] && [ -n "${GITLAB_URL:-}" ]; then
        local gitlab_status
        gitlab_status=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "$E2E_SERVICE_TIMEOUT" \
            --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/user" 2>/dev/null)

        if [ "$gitlab_status" = "200" ]; then
            log_pass "GitLab API accessible" >&2
        else
            log_error "GitLab API not accessible (HTTP $gitlab_status)" >&2
            failures=$((failures + 1))
        fi
    else
        log_warn "GitLab credentials not configured (GITLAB_TOKEN/GITLAB_URL)" >&2
    fi

    # Check Jenkins API
    if [ -n "${JENKINS_URL:-}" ]; then
        local jenkins_status
        jenkins_status=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "$E2E_SERVICE_TIMEOUT" \
            "${JENKINS_URL}/api/json" 2>/dev/null)

        if [ "$jenkins_status" = "200" ] || [ "$jenkins_status" = "403" ]; then
            log_pass "Jenkins API accessible" >&2
        else
            log_error "Jenkins API not accessible (HTTP $jenkins_status)" >&2
            failures=$((failures + 1))
        fi
    else
        log_warn "Jenkins URL not configured (JENKINS_URL)" >&2
    fi

    # Check Kubernetes cluster
    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    if $kubectl_cmd cluster-info &> /dev/null; then
        log_pass "Kubernetes cluster accessible" >&2
    else
        log_error "Kubernetes cluster not accessible" >&2
        failures=$((failures + 1))
    fi

    # Check ArgoCD (if available)
    if command -v argocd &> /dev/null; then
        if argocd app list &> /dev/null; then
            log_pass "ArgoCD accessible" >&2
        else
            log_warn "ArgoCD not logged in (may require: argocd login)" >&2
        fi
    fi

    return $failures
}

# Validate git repository state
validate_git_state() {
    log_info "Validating git repository state..." >&2

    local failures=0

    # Check k8s-deployments repo
    if [ -d "/home/jmann/git/mannjg/deployment-pipeline/k8s-deployments" ]; then
        cd "/home/jmann/git/mannjg/deployment-pipeline/k8s-deployments" || return 1

        # Check for uncommitted changes
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            log_warn "k8s-deployments has uncommitted changes" >&2
            git status --short >&2
        else
            log_pass "k8s-deployments is clean" >&2
        fi

        # Fetch latest from remote
        git fetch --quiet origin 2>/dev/null
        log_pass "k8s-deployments fetched from remote" >&2
    fi

    # Check example-app repo
    if [ -d "/home/jmann/git/mannjg/deployment-pipeline/example-app" ]; then
        cd "/home/jmann/git/mannjg/deployment-pipeline/example-app" || return 1

        # Check for uncommitted changes
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            log_warn "example-app has uncommitted changes" >&2
            git status --short >&2
        else
            log_pass "example-app is clean" >&2
        fi

        # Fetch latest from remote
        git fetch --quiet origin 2>/dev/null
        log_pass "example-app fetched from remote" >&2
    fi

    return $failures
}

# Validate E2E configuration
validate_configuration() {
    log_info "Validating E2E configuration..." >&2

    local failures=0

    # Check required environment variables
    local required_vars=(
        "GITLAB_URL"
        "GITLAB_TOKEN"
        "JENKINS_URL"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            log_error "Required variable $var is not set" >&2
            failures=$((failures + 1))
        fi
    done

    # Configuration variables validated successfully

    if [ $failures -eq 0 ]; then
        log_pass "E2E configuration is valid" >&2
    fi

    return $failures
}

# Clean up old test branches (e2e-test-*)
cleanup_old_test_branches() {
    log_info "Cleaning up old test branches..." >&2

    if [ "$E2E_SKIP_CLEANUP" = "true" ]; then
        log_info "Cleanup skipped (E2E_SKIP_CLEANUP=true)" >&2
        return 0
    fi

    local cleaned_count=0
    local current_time
    current_time=$(date +%s)
    local age_seconds=$((E2E_MAX_BRANCH_AGE_HOURS * 3600))

    # Clean up in k8s-deployments repo
    if [ -d "/home/jmann/git/mannjg/deployment-pipeline/k8s-deployments" ]; then
        cd "/home/jmann/git/mannjg/deployment-pipeline/k8s-deployments" || return 1

        # Get all e2e-test-* branches with their commit dates
        while IFS='|' read -r branch_name commit_date; do
            if [ -z "$branch_name" ] || [ -z "$commit_date" ]; then
                continue
            fi

            local branch_age=$((current_time - commit_date))

            if [ $branch_age -gt $age_seconds ]; then
                log_info "Deleting old branch: $branch_name (age: $((branch_age / 3600))h)" >&2

                # Delete locally
                git branch -D "$branch_name" &> /dev/null || true

                # Delete remotely (if it exists)
                git push origin --delete "$branch_name" &> /dev/null || true

                cleaned_count=$((cleaned_count + 1))
            fi
        done < <(git for-each-ref --format='%(refname:short)|%(committerdate:unix)' refs/heads/e2e-test-* 2>/dev/null)

        # Also check remote branches
        while IFS='|' read -r branch_name commit_date; do
            if [ -z "$branch_name" ] || [ -z "$commit_date" ]; then
                continue
            fi

            # Strip origin/ prefix
            local short_name="${branch_name#origin/}"

            local branch_age=$((current_time - commit_date))

            if [ $branch_age -gt $age_seconds ]; then
                log_info "Deleting old remote branch: $short_name (age: $((branch_age / 3600))h)" >&2
                git push origin --delete "$short_name" &> /dev/null || true
                cleaned_count=$((cleaned_count + 1))
            fi
        done < <(git for-each-ref --format='%(refname:short)|%(committerdate:unix)' refs/remotes/origin/e2e-test-* 2>/dev/null)
    fi

    # Clean up in example-app repo
    if [ -d "/home/jmann/git/mannjg/deployment-pipeline/example-app" ]; then
        cd "/home/jmann/git/mannjg/deployment-pipeline/example-app" || return 1

        while IFS='|' read -r branch_name commit_date; do
            if [ -z "$branch_name" ] || [ -z "$commit_date" ]; then
                continue
            fi

            local branch_age=$((current_time - commit_date))

            if [ $branch_age -gt $age_seconds ]; then
                log_info "Deleting old branch: $branch_name (age: $((branch_age / 3600))h)" >&2
                git branch -D "$branch_name" &> /dev/null || true
                git push origin --delete "$branch_name" &> /dev/null || true
                cleaned_count=$((cleaned_count + 1))
            fi
        done < <(git for-each-ref --format='%(refname:short)|%(committerdate:unix)' refs/heads/e2e-test-* 2>/dev/null)
    fi

    if [ $cleaned_count -gt 0 ]; then
        log_pass "Cleaned up $cleaned_count old test branches" >&2
    else
        log_pass "No old test branches to clean up" >&2
    fi

    return 0
}

# Clean up old merge requests with "E2E test" in title
cleanup_old_merge_requests() {
    log_info "Cleaning up old test merge requests..." >&2

    if [ "$E2E_SKIP_CLEANUP" = "true" ]; then
        log_info "Cleanup skipped (E2E_SKIP_CLEANUP=true)" >&2
        return 0
    fi

    if [ -z "${GITLAB_TOKEN:-}" ] || [ -z "${K8S_DEPLOYMENTS_PROJECT_ID:-}" ]; then
        log_warn "Skipping MR cleanup (GitLab credentials not configured)" >&2
        return 0
    fi

    local api_url
    api_url=$(get_gitlab_api_url)

    local cleaned_count=0
    local current_time
    current_time=$(date +%s)
    local age_seconds=$((E2E_MAX_BRANCH_AGE_HOURS * 3600))

    # Get all open MRs with "E2E test" in the title
    local mrs
    mrs=$(curl -s \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${api_url}/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/merge_requests?state=opened&search=E2E" 2>/dev/null)

    if [ -z "$mrs" ] || [ "$mrs" = "[]" ]; then
        log_pass "No old test merge requests to clean up" >&2
        return 0
    fi

    # Parse and close old MRs
    local mr_count
    mr_count=$(echo "$mrs" | jq '. | length' 2>/dev/null || echo "0")

    for ((i=0; i<mr_count; i++)); do
        local mr_iid
        mr_iid=$(echo "$mrs" | jq -r ".[$i].iid" 2>/dev/null)

        local mr_title
        mr_title=$(echo "$mrs" | jq -r ".[$i].title" 2>/dev/null)

        local created_at
        created_at=$(echo "$mrs" | jq -r ".[$i].created_at" 2>/dev/null)

        # Convert created_at to epoch (format: 2025-01-05T14:50:16.000Z)
        local created_epoch
        created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "$current_time")

        local mr_age=$((current_time - created_epoch))

        if [ $mr_age -gt $age_seconds ]; then
            log_info "Closing old MR !${mr_iid}: $mr_title (age: $((mr_age / 3600))h)" >&2

            curl -s -X PUT \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --header "Content-Type: application/json" \
                --data '{"state_event": "close"}' \
                "${api_url}/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/merge_requests/${mr_iid}" \
                > /dev/null 2>&1

            cleaned_count=$((cleaned_count + 1))
        fi
    done

    if [ $cleaned_count -gt 0 ]; then
        log_pass "Closed $cleaned_count old test merge requests" >&2
    else
        log_pass "No old test merge requests to clean up" >&2
    fi

    return 0
}

# Main initialization function
run_test_initialization() {
    echo ""  >&2
    log_info "==========================================" >&2
    log_info "  E2E TEST INITIALIZATION" >&2
    log_info "==========================================" >&2
    echo "" >&2

    local total_checks=0
    local failed_checks=0

    # Run validation checks
    log_info "Running pre-flight checks..." >&2
    echo "" >&2

    if ! validate_services; then
        failed_checks=$((failed_checks + 1))
    fi
    total_checks=$((total_checks + 1))

    if ! validate_configuration; then
        failed_checks=$((failed_checks + 1))
    fi
    total_checks=$((total_checks + 1))

    if ! validate_git_state; then
        failed_checks=$((failed_checks + 1))
    fi
    total_checks=$((total_checks + 1))

    # Run cleanup operations
    if [ "$failed_checks" -eq 0 ]; then
        echo "" >&2
        log_info "Running cleanup operations..." >&2
        echo "" >&2

        cleanup_old_test_branches
        cleanup_old_merge_requests
    fi

    # Print summary
    echo "" >&2
    log_info "==========================================" >&2
    if [ "$failed_checks" -eq 0 ]; then
        log_pass "  INITIALIZATION COMPLETE" >&2
        log_info "  Pre-flight checks: $total_checks/$total_checks passed" >&2
    else
        log_error "  INITIALIZATION FAILED" >&2
        log_info "  Pre-flight checks: $((total_checks - failed_checks))/$total_checks passed" >&2
    fi
    log_info "==========================================" >&2
    echo "" >&2

    return $failed_checks
}
