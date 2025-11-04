#!/bin/bash
# Test assertion functions

# Assert command succeeds
assert_success() {
    local description=$1
    local command="${@:2}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if eval "$command" &> /dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        if [[ "${VERBOSE:-0}" -ge 1 ]]; then
            log_error "Command: $command"
            eval "$command" 2>&1 | sed 's/^/  | /'
        fi
        return 1
    fi
}

# Assert command fails
assert_failure() {
    local description=$1
    local command="${@:2}"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if ! eval "$command" &> /dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description (expected failure, got success)"
        return 1
    fi
}

# Assert equals
assert_equals() {
    local description=$1
    local expected=$2
    local actual=$3

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        log_error "Expected: $expected"
        log_error "Actual:   $actual"
        return 1
    fi
}

# Assert not equals
assert_not_equals() {
    local description=$1
    local not_expected=$2
    local actual=$3

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if [ "$not_expected" != "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description (values should not be equal)"
        return 1
    fi
}

# Assert contains
assert_contains() {
    local description=$1
    local haystack=$2
    local needle=$3

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if echo "$haystack" | grep -q "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        log_error "Expected to find: $needle"
        log_error "In: $haystack"
        return 1
    fi
}

# Assert file exists
assert_file_exists() {
    local description=$1
    local file=$2

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if [ -f "$file" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        log_error "File not found: $file"
        return 1
    fi
}

# Assert directory exists
assert_dir_exists() {
    local description=$1
    local dir=$2

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if [ -d "$dir" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        log_error "Directory not found: $dir"
        return 1
    fi
}

# Assert K8s resource exists
assert_k8s_resource_exists() {
    local description=$1
    local resource=$2
    local namespace=${3:-}

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    local cmd="kubectl get $resource"
    if [ -n "$namespace" ]; then
        cmd="$cmd -n $namespace"
    fi

    if eval "$cmd" &> /dev/null; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        log_error "Resource not found: $resource"
        return 1
    fi
}

# Assert pod is ready
assert_pod_ready() {
    local description=$1
    local pod_selector=$2
    local namespace=$3
    local timeout=${4:-60}

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    local condition="kubectl get pods -l \"$pod_selector\" -n \"$namespace\" -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

    if wait_for_condition "$condition" "$timeout"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description (timeout after ${timeout}s)"
        if [[ "${VERBOSE:-0}" -ge 1 ]]; then
            kubectl get pods -l "$pod_selector" -n "$namespace"
            kubectl describe pods -l "$pod_selector" -n "$namespace"
        fi
        return 1
    fi
}

# Assert ArgoCD app is healthy
assert_argocd_app_healthy() {
    local description=$1
    local app_name=$2
    local timeout=${3:-120}

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    local condition="kubectl get application \"$app_name\" -n argocd -o jsonpath='{.status.health.status}' | grep -q Healthy"

    if wait_for_condition "$condition" "$timeout"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description (timeout after ${timeout}s)"
        if [[ "${VERBOSE:-0}" -ge 1 ]]; then
            kubectl get application "$app_name" -n argocd -o yaml
        fi
        return 1
    fi
}

# Assert ArgoCD app is synced
assert_argocd_app_synced() {
    local description=$1
    local app_name=$2
    local timeout=${3:-120}

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    local condition="kubectl get application \"$app_name\" -n argocd -o jsonpath='{.status.sync.status}' | grep -q Synced"

    if wait_for_condition "$condition" "$timeout"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description (timeout after ${timeout}s)"
        if [[ "${VERBOSE:-0}" -ge 1 ]]; then
            kubectl get application "$app_name" -n argocd -o yaml
        fi
        return 1
    fi
}

# Skip test
skip_test() {
    local description=$1
    local reason=$2

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    log_skip "$description${reason:+ ($reason)}"
}
