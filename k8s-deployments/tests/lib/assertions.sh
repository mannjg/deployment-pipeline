#!/bin/bash
# Test assertions library
# Provides assertion functions for validating Kubernetes and ArgoCD resources

# Source common functions
ASSERTIONS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ASSERTIONS_LIB_DIR/common.sh"

# Assert ArgoCD application is synced
# Usage: assert_argocd_app_synced "description" "app-name" [timeout]
assert_argocd_app_synced() {
    local description=$1
    local app_name=$2
    local timeout=${3:-300}

    log_info "Checking: $description"

    local check_cmd="argocd app get $app_name --refresh 2>/dev/null | grep -q 'Sync Status:.*Synced'"

    if wait_for_condition "$description" "$timeout" "$check_cmd"; then
        return 0
    else
        log_fail "$description"
        argocd app get "$app_name" 2>&1 || true
        return 1
    fi
}

# Assert ArgoCD application is healthy
# Usage: assert_argocd_app_healthy "description" "app-name" [timeout]
assert_argocd_app_healthy() {
    local description=$1
    local app_name=$2
    local timeout=${3:-300}

    log_info "Checking: $description"

    local check_cmd="argocd app get $app_name 2>/dev/null | grep -q 'Health Status:.*Healthy'"

    if wait_for_condition "$description" "$timeout" "$check_cmd"; then
        return 0
    else
        log_fail "$description"
        argocd app get "$app_name" 2>&1 || true
        return 1
    fi
}

# Assert Kubernetes resource exists
# Usage: assert_k8s_resource_exists "description" "resource-type resource-name" "namespace"
assert_k8s_resource_exists() {
    local description=$1
    local resource=$2
    local namespace=$3

    log_info "Checking: $description"

    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    if $kubectl_cmd get $resource -n "$namespace" &> /dev/null; then
        log_pass "$description"
        return 0
    else
        log_fail "$description"
        return 1
    fi
}

# Assert pods are ready
# Usage: assert_pod_ready "description" "label-selector" "namespace" [timeout]
assert_pod_ready() {
    local description=$1
    local selector=$2
    local namespace=$3
    local timeout=${4:-300}

    log_info "Checking: $description"

    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    local check_cmd="
        pods=\$($kubectl_cmd get pods -n $namespace -l '$selector' -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)
        [ -n \"\$pods\" ] && ! echo \"\$pods\" | grep -q False
    "

    if wait_for_condition "$description" "$timeout" "$check_cmd"; then
        return 0
    else
        log_fail "$description"
        $kubectl_cmd get pods -n "$namespace" -l "$selector" 2>&1 || true
        return 1
    fi
}
