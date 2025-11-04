#!/bin/bash
# E2E Pipeline Stage 2: Verify Dev Deployment
# Verifies that the application deployed successfully to dev environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/../../../k8s-deployments/tests/lib/common.sh"
source "$SCRIPT_DIR/../../../k8s-deployments/tests/lib/assertions.sh"
source "$SCRIPT_DIR/../lib/git-operations.sh"

# Load E2E configuration
if [ -f "$SCRIPT_DIR/../config/e2e-config.sh" ]; then
    source "$SCRIPT_DIR/../config/e2e-config.sh"
else
    log_error "E2E configuration not found"
    exit 1
fi

stage_02_verify_dev() {
    log_info "======================================"
    log_info "  STAGE 2: Verify Dev Deployment"
    log_info "======================================"
    echo

    # Load state from previous stage
    if [ ! -f "${E2E_STATE_DIR}/dev_commit_sha.txt" ]; then
        log_error "No dev commit SHA found from previous stage"
        return 1
    fi

    local dev_commit_sha
    dev_commit_sha=$(cat "${E2E_STATE_DIR}/dev_commit_sha.txt")
    log_info "Verifying deployment for commit: $dev_commit_sha"

    # Get kubectl command
    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    # Wait for ArgoCD to detect and sync the changes
    log_info "Waiting for ArgoCD to detect changes..."
    sleep "${ARGOCD_SYNC_WAIT:-30}"

    # Check ArgoCD application status
    log_info "Checking ArgoCD application status..."
    assert_argocd_app_synced \
        "Dev application is synced" \
        "${ARGOCD_APP_PREFIX}-dev" \
        "${ARGOCD_SYNC_TIMEOUT:-300}"

    assert_argocd_app_healthy \
        "Dev application is healthy" \
        "${ARGOCD_APP_PREFIX}-dev" \
        "${ARGOCD_HEALTH_TIMEOUT:-300}"

    # Verify deployment exists
    log_info "Verifying Kubernetes deployment..."
    assert_k8s_resource_exists \
        "Dev deployment exists" \
        "deployment ${DEPLOYMENT_NAME}" \
        "dev"

    # Verify deployment is ready
    log_info "Waiting for deployment to be ready..."
    assert_pod_ready \
        "Dev pods are ready" \
        "app=${APP_SELECTOR}" \
        "dev" \
        "${POD_READY_TIMEOUT:-300}"

    # Verify service exists
    assert_k8s_resource_exists \
        "Dev service exists" \
        "service ${SERVICE_NAME}" \
        "dev"

    # Check deployment replicas
    local desired_replicas
    desired_replicas=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n dev -o jsonpath='{.spec.replicas}')

    local ready_replicas
    ready_replicas=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n dev -o jsonpath='{.status.readyReplicas}')

    if [ "$desired_replicas" = "$ready_replicas" ]; then
        log_pass "All $ready_replicas/$desired_replicas replicas are ready"
    else
        log_error "Only $ready_replicas/$desired_replicas replicas are ready"
        return 1
    fi

    # Verify the deployed version (if version is exposed)
    if [ -n "${VERSION_CHECK_COMMAND}" ]; then
        log_info "Checking deployed version..."

        local deployed_version
        deployed_version=$(eval "${VERSION_CHECK_COMMAND}")

        local expected_version
        expected_version=$(cat "${E2E_STATE_DIR}/version.txt" 2>/dev/null || echo "unknown")

        if [ "$deployed_version" = "$expected_version" ]; then
            log_pass "Deployed version matches: $deployed_version"
        else
            log_warn "Version mismatch - Expected: $expected_version, Got: $deployed_version"
        fi
    fi

    # Verify application responds to health check (if configured)
    if [ -n "${DEV_HEALTH_ENDPOINT}" ]; then
        log_info "Checking application health endpoint..."

        local health_status
        health_status=$(curl -s -o /dev/null -w "%{http_code}" "${DEV_HEALTH_ENDPOINT}" 2>/dev/null)

        if [ "$health_status" = "200" ]; then
            log_pass "Health endpoint returned 200 OK"
        else
            log_warn "Health endpoint returned: $health_status (may be expected for internal services)"
        fi
    fi

    # Log deployment details for debugging
    log_info "Deployment details:"
    $kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n dev -o wide

    log_info "Pod details:"
    $kubectl_cmd get pods -n dev -l "app=${APP_SELECTOR}" -o wide

    # Check recent events for any errors
    log_info "Checking recent events in dev namespace..."
    local error_events
    error_events=$($kubectl_cmd get events -n dev --field-selector type=Warning \
        --sort-by='.lastTimestamp' | tail -n 10)

    if [ -n "$error_events" ]; then
        log_warn "Recent warning events in dev namespace:"
        echo "$error_events"
    else
        log_pass "No warning events in dev namespace"
    fi

    # Save dev deployment status for later stages
    echo "VERIFIED" > "${E2E_STATE_DIR}/dev_status.txt"
    echo "$(date +%s)" > "${E2E_STATE_DIR}/dev_verified_timestamp.txt"

    echo
    log_info "======================================"
    log_pass "  STAGE 2: Complete"
    log_info "======================================"
    echo

    return 0
}

# Run stage if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    stage_02_verify_dev
fi
