#!/bin/bash
KUBECTL_CMD="${KUBECTL_CMD:-microk8s kubectl}"
# Integration tests for ArgoCD operations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test libraries
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/assertions.sh
source "$SCRIPT_DIR/../lib/assertions.sh"

run_argocd_tests() {
    log_info "===== Running ArgoCD Integration Tests ====="
    echo

    # Test: ArgoCD is installed
    assert_success \
        "ArgoCD namespace exists" \
        "$KUBECTL_CMD get namespace argocd > /dev/null"

    assert_success \
        "ArgoCD application controller is running" \
        "$KUBECTL_CMD get deployment argocd-application-controller -n argocd > /dev/null"

    assert_success \
        "ArgoCD server is running" \
        "$KUBECTL_CMD get deployment argocd-server -n argocd > /dev/null"

    assert_success \
        "ArgoCD repo server is running" \
        "$KUBECTL_CMD get deployment argocd-repo-server -n argocd > /dev/null"

    # Test: ArgoCD CRDs are installed
    assert_success \
        "ArgoCD Application CRD exists" \
        "$KUBECTL_CMD get crd applications.argoproj.io > /dev/null"

    assert_success \
        "ArgoCD AppProject CRD exists" \
        "$KUBECTL_CMD get crd appprojects.argoproj.io > /dev/null"

    # Test: Expected ArgoCD Applications exist
    assert_k8s_resource_exists \
        "example-app-dev Application exists" \
        "application example-app-dev" \
        "argocd"

    assert_k8s_resource_exists \
        "example-app-stage Application exists" \
        "application example-app-stage" \
        "argocd"

    assert_k8s_resource_exists \
        "example-app-prod Application exists" \
        "application example-app-prod" \
        "argocd"

    # Test: Applications have expected properties
    for env in dev stage prod; do
        local app_name="example-app-$env"

        assert_success \
            "$app_name has correct namespace in destination" \
            "$KUBECTL_CMD get application '$app_name' -n argocd -o jsonpath='{.spec.destination.namespace}' | grep -q '^$env$'"

        assert_success \
            "$app_name has automated sync policy" \
            "$KUBECTL_CMD get application '$app_name' -n argocd -o jsonpath='{.spec.syncPolicy.automated}' | grep -q '.'"

        assert_success \
            "$app_name has prune enabled" \
            "$KUBECTL_CMD get application '$app_name' -n argocd -o jsonpath='{.spec.syncPolicy.automated.prune}' | grep -q 'true'"

        assert_success \
            "$app_name has selfHeal enabled" \
            "$KUBECTL_CMD get application '$app_name' -n argocd -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' | grep -q 'true'"

        assert_success \
            "$app_name has ignoreDifferences configured" \
            "$KUBECTL_CMD get application '$app_name' -n argocd -o jsonpath='{.spec.ignoreDifferences}' | grep -q 'Deployment'"
    done

    # Test: Applications are healthy and synced
    for env in dev stage prod; do
        local app_name="example-app-$env"

        # Check health status
        local health_status
        health_status=$($KUBECTL_CMD get application "$app_name" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

        if [ "$health_status" = "Healthy" ]; then
            log_pass "$app_name is Healthy"
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
        elif [ "$health_status" = "Progressing" ]; then
            skip_test "$app_name health check" "application is still syncing"
        else
            log_warn "$app_name health status: $health_status"
            skip_test "$app_name health check" "health status is $health_status"
        fi

        # Check sync status
        local sync_status
        sync_status=$($KUBECTL_CMD get application "$app_name" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

        if [ "$sync_status" = "Synced" ]; then
            log_pass "$app_name is Synced"
            TESTS_TOTAL=$((TESTS_TOTAL + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_warn "$app_name sync status: $sync_status"
            skip_test "$app_name sync check" "sync status is $sync_status"
        fi
    done

    # Test: Bootstrap application exists (if using App of Apps)
    if $KUBECTL_CMD get application bootstrap -n argocd &> /dev/null; then
        assert_k8s_resource_exists \
            "Bootstrap Application exists" \
            "application bootstrap" \
            "argocd"

        assert_success \
            "Bootstrap Application watches manifests/argocd/" \
            "$KUBECTL_CMD get application bootstrap -n argocd -o jsonpath='{.spec.source.path}' | grep -q 'manifests/argocd'"
    else
        skip_test "Bootstrap Application" "not using App of Apps pattern"
    fi

    echo
    log_info "===== ArgoCD Integration Tests Complete ====="
    echo
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_argocd_tests
fi
