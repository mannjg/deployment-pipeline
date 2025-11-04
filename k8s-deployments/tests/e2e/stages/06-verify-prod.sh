#!/bin/bash
# E2E Pipeline Stage 6: Verify Production Deployment
# Verifies that the application deployed successfully to production environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/../../lib/common.sh"
source "$SCRIPT_DIR/../../lib/assertions.sh"
source "$SCRIPT_DIR/../lib/git-operations.sh"

# Load E2E configuration
if [ -f "$SCRIPT_DIR/../config/e2e-config.sh" ]; then
    source "$SCRIPT_DIR/../config/e2e-config.sh"
else
    log_error "E2E configuration not found"
    exit 1
fi

stage_06_verify_prod() {
    log_info "======================================"
    log_info "  STAGE 6: Verify Production Deployment"
    log_info "======================================"
    echo

    # Load state from previous stage
    if [ ! -f "${E2E_STATE_DIR}/prod_commit_sha.txt" ]; then
        log_error "No prod commit SHA found from previous stage"
        return 1
    fi

    local prod_commit_sha
    prod_commit_sha=$(cat "${E2E_STATE_DIR}/prod_commit_sha.txt")
    log_info "Verifying deployment for commit: $prod_commit_sha"

    # Get kubectl command
    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    # Wait for ArgoCD to detect and sync the changes
    log_info "Waiting for ArgoCD to detect changes..."
    sleep "${ARGOCD_SYNC_WAIT:-30}"

    # Check ArgoCD application status
    log_info "Checking ArgoCD application status..."
    assert_argocd_app_synced \
        "Production application is synced" \
        "${ARGOCD_APP_PREFIX}-prod" \
        "${ARGOCD_SYNC_TIMEOUT:-300}"

    assert_argocd_app_healthy \
        "Production application is healthy" \
        "${ARGOCD_APP_PREFIX}-prod" \
        "${ARGOCD_HEALTH_TIMEOUT:-300}"

    # Verify deployment exists
    log_info "Verifying Kubernetes deployment..."
    assert_k8s_resource_exists \
        "Production deployment exists" \
        "deployment ${DEPLOYMENT_NAME}" \
        "prod"

    # Verify deployment is ready
    log_info "Waiting for deployment to be ready..."
    assert_pod_ready \
        "Production pods are ready" \
        "app=${APP_SELECTOR}" \
        "prod" \
        "${POD_READY_TIMEOUT:-300}"

    # Verify service exists
    assert_k8s_resource_exists \
        "Production service exists" \
        "service ${SERVICE_NAME}" \
        "prod"

    # Check deployment replicas
    local desired_replicas
    desired_replicas=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n prod -o jsonpath='{.spec.replicas}')

    local ready_replicas
    ready_replicas=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n prod -o jsonpath='{.status.readyReplicas}')

    if [ "$desired_replicas" = "$ready_replicas" ]; then
        log_pass "All $ready_replicas/$desired_replicas replicas are ready"
    else
        log_error "Only $ready_replicas/$ready_replicas replicas are ready"
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
    if [ -n "${PROD_HEALTH_ENDPOINT}" ]; then
        log_info "Checking application health endpoint..."

        local health_status
        health_status=$(curl -s -o /dev/null -w "%{http_code}" "${PROD_HEALTH_ENDPOINT}" 2>/dev/null)

        if [ "$health_status" = "200" ]; then
            log_pass "Health endpoint returned 200 OK"
        else
            log_warn "Health endpoint returned: $health_status (may be expected for internal services)"
        fi
    fi

    # Verify prod has same version as stage
    log_info "Verifying prod matches stage deployment..."

    local stage_image
    stage_image=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n stage -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

    local prod_image
    prod_image=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n prod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

    if [ "$stage_image" = "$prod_image" ]; then
        log_pass "Production image matches stage: $prod_image"
    else
        log_error "Image mismatch - Stage: $stage_image, Prod: $prod_image"
        return 1
    fi

    # Verify consistency across all environments
    log_info "Verifying consistency across all environments..."

    local dev_image
    dev_image=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n dev -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

    if [ "$dev_image" = "$stage_image" ] && [ "$stage_image" = "$prod_image" ]; then
        log_pass "All environments running same image: $prod_image"
    else
        log_warn "Environment images differ - Dev: $dev_image, Stage: $stage_image, Prod: $prod_image"
    fi

    # Log deployment details for debugging
    log_info "Deployment details:"
    $kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n prod -o wide

    log_info "Pod details:"
    $kubectl_cmd get pods -n prod -l "app=${APP_SELECTOR}" -o wide

    # Check recent events for any errors
    log_info "Checking recent events in prod namespace..."
    local error_events
    error_events=$($kubectl_cmd get events -n prod --field-selector type=Warning \
        --sort-by='.lastTimestamp' | tail -n 10)

    if [ -n "$error_events" ]; then
        log_warn "Recent warning events in prod namespace:"
        echo "$error_events"
    else
        log_pass "No warning events in prod namespace"
    fi

    # Additional production validation
    log_info "Running production-specific validations..."

    # Check that prod has appropriate resources (CPU/memory)
    local prod_cpu_request
    prod_cpu_request=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n prod \
        -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)

    local prod_memory_request
    prod_memory_request=$($kubectl_cmd get deployment "${DEPLOYMENT_NAME}" -n prod \
        -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null)

    log_info "Production resource requests - CPU: ${prod_cpu_request:-none}, Memory: ${prod_memory_request:-none}"

    # Save production deployment status
    echo "VERIFIED" > "${E2E_STATE_DIR}/prod_status.txt"
    echo "$(date +%s)" > "${E2E_STATE_DIR}/prod_verified_timestamp.txt"

    # Calculate total time for pipeline
    local start_time
    start_time=$(cat "${E2E_STATE_DIR}/test_start_timestamp.txt" 2>/dev/null || echo "0")

    local end_time
    end_time=$(date +%s)

    local total_time=$((end_time - start_time))

    echo "$total_time" > "${E2E_STATE_DIR}/total_duration.txt"

    log_info "Total pipeline duration: $(seconds_to_human $total_time)"

    echo
    log_info "======================================"
    log_pass "  STAGE 6: Complete"
    log_info "======================================"
    echo

    return 0
}

# Run stage if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    stage_06_verify_prod
fi
