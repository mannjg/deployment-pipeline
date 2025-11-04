#!/bin/bash
KUBECTL_CMD="${KUBECTL_CMD:-microk8s kubectl}"
# Integration tests for Kubernetes operations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test libraries
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/assertions.sh
source "$SCRIPT_DIR/../lib/assertions.sh"

run_kubernetes_tests() {
    log_info "===== Running Kubernetes Integration Tests ====="
    echo

    # Test: Cluster connectivity
    assert_success \
        "Kubernetes cluster is accessible" \
        "$KUBECTL_CMD cluster-info > /dev/null"

    assert_success \
        "Kubectl can list nodes" \
        "$KUBECTL_CMD get nodes > /dev/null"

    # Test: Expected namespaces exist
    assert_success \
        "Default namespace exists" \
        "$KUBECTL_CMD get namespace default > /dev/null"

    assert_success \
        "Dev namespace exists" \
        "$KUBECTL_CMD get namespace dev > /dev/null"

    assert_success \
        "Stage namespace exists" \
        "$KUBECTL_CMD get namespace stage > /dev/null"

    assert_success \
        "Prod namespace exists" \
        "$KUBECTL_CMD get namespace prod > /dev/null"

    assert_success \
        "ArgoCD namespace exists" \
        "$KUBECTL_CMD get namespace argocd > /dev/null"

    # Test: Can create test namespace
    local test_ns="pipeline-test-k8s-$(date +%s)"

    assert_success \
        "Can create test namespace" \
        "$KUBECTL_CMD create namespace '$test_ns'"

    assert_k8s_resource_exists \
        "Test namespace was created" \
        "namespace $test_ns"

    # Test: Can create resources in test namespace
    assert_success \
        "Can create ConfigMap in test namespace" \
        "$KUBECTL_CMD create configmap test-config --from-literal=key=value -n '$test_ns'"

    assert_k8s_resource_exists \
        "ConfigMap was created" \
        "configmap test-config" \
        "$test_ns"

    assert_success \
        "Can create Service in test namespace" \
        "$KUBECTL_CMD create service clusterip test-svc --tcp=80:8080 -n '$test_ns'"

    assert_k8s_resource_exists \
        "Service was created" \
        "service test-svc" \
        "$test_ns"

    # Test: Can delete resources
    assert_success \
        "Can delete ConfigMap" \
        "$KUBECTL_CMD delete configmap test-config -n '$test_ns'"

    assert_success \
        "Can delete Service" \
        "$KUBECTL_CMD delete service test-svc -n '$test_ns'"

    # Test: Can delete test namespace
    assert_success \
        "Can delete test namespace" \
        "$KUBECTL_CMD delete namespace '$test_ns' --timeout=30s"

    # Test: RBAC (basic checks)
    assert_success \
        "Can list deployments in dev namespace" \
        "$KUBECTL_CMD get deployments -n dev > /dev/null"

    assert_success \
        "Can list services in stage namespace" \
        "$KUBECTL_CMD get services -n stage > /dev/null"

    assert_success \
        "Can list pods in prod namespace" \
        "$KUBECTL_CMD get pods -n prod > /dev/null"

    echo
    log_info "===== Kubernetes Integration Tests Complete ====="
    echo
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_kubernetes_tests
fi
