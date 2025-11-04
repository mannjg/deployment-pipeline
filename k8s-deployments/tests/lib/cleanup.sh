#!/bin/bash
# Cleanup functions for test artifacts

# Cleanup test namespace
cleanup_test_namespace() {
    local namespace=$1

    if [ -z "$namespace" ] || [ "$namespace" = "default" ] || [ "$namespace" = "kube-system" ]; then
        log_warn "Refusing to delete protected namespace: $namespace"
        return 1
    fi

    if ! echo "$namespace" | grep -q "^pipeline-test-"; then
        log_warn "Refusing to delete non-test namespace: $namespace"
        return 1
    fi

    log_info "Cleaning up test namespace: $namespace"

    if kubectl get namespace "$namespace" &> /dev/null; then
        if kubectl delete namespace "$namespace" --timeout=60s; then
            log_pass "Test namespace deleted: $namespace"
        else
            log_warn "Failed to delete test namespace (may need manual cleanup): $namespace"
        fi
    else
        log_debug "Test namespace does not exist: $namespace"
    fi
}

# Cleanup test ArgoCD applications
cleanup_test_argocd_apps() {
    local app_prefix=${1:-pipeline-test}

    log_info "Cleaning up test ArgoCD applications..."

    local apps
    apps=$(kubectl get applications -n argocd -o jsonpath='{.items[?(@.metadata.name matches "^'"$app_prefix"'.*")].metadata.name}' 2>/dev/null)

    if [ -z "$apps" ]; then
        log_debug "No test ArgoCD applications found"
        return 0
    fi

    for app in $apps; do
        log_info "Deleting ArgoCD application: $app"
        if kubectl delete application "$app" -n argocd --timeout=60s; then
            log_pass "ArgoCD application deleted: $app"
        else
            log_warn "Failed to delete ArgoCD application: $app"
        fi
    done
}

# Cleanup test Git branches
cleanup_test_branches() {
    local repo_dir=$1
    local branch_prefix=${2:-test/}

    if [ ! -d "$repo_dir/.git" ]; then
        log_debug "Not a git repository: $repo_dir"
        return 0
    fi

    log_info "Cleaning up test branches in $repo_dir..."

    pushd "$repo_dir" > /dev/null || return 1

    local branches
    branches=$(git branch --list "${branch_prefix}*" 2>/dev/null | sed 's/^[* ]*//')

    if [ -z "$branches" ]; then
        log_debug "No test branches found"
        popd > /dev/null || true
        return 0
    fi

    for branch in $branches; do
        log_info "Deleting test branch: $branch"
        if git branch -D "$branch" &> /dev/null; then
            log_pass "Branch deleted: $branch"
        else
            log_warn "Failed to delete branch: $branch"
        fi
    done

    popd > /dev/null || true
}

# Cleanup temporary directories
cleanup_temp_dirs() {
    log_info "Cleaning up temporary directories..."

    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        log_debug "Removing temp directory: $TEST_TEMP_DIR"
        rm -rf "$TEST_TEMP_DIR"
        log_pass "Temporary directory removed"
    fi
}

# Cleanup all test artifacts
cleanup_all() {
    log_info "Starting comprehensive cleanup..."

    # Cleanup in reverse order of creation
    cleanup_test_argocd_apps
    cleanup_test_namespace "$TEST_NAMESPACE"
    cleanup_test_branches "$(pwd)"
    cleanup_temp_dirs

    log_pass "Cleanup complete"
}

# Emergency cleanup on interrupt
emergency_cleanup() {
    log_warn "Test interrupted! Performing emergency cleanup..."
    cleanup_all
}

# Setup cleanup trap
setup_cleanup_trap() {
    trap emergency_cleanup EXIT INT TERM
}

# Remove cleanup trap
remove_cleanup_trap() {
    trap - EXIT INT TERM
}

# Cleanup based on mode
conditional_cleanup() {
    local cleanup_mode=${CLEANUP_MODE:-always}
    local test_passed=$1

    case "$cleanup_mode" in
        never)
            log_info "Cleanup disabled (--no-cleanup)"
            ;;
        on-success)
            if [ "$test_passed" = "true" ]; then
                log_info "Tests passed, cleaning up..."
                cleanup_all
            else
                log_warn "Tests failed, keeping artifacts for debugging"
                log_info "Test namespace: $TEST_NAMESPACE"
            fi
            ;;
        always|*)
            cleanup_all
            ;;
    esac
}
