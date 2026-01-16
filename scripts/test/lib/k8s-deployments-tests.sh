#!/bin/bash
# Test case implementations for k8s-deployments pipeline validation
# Sourced by validate-k8s-deployments-pipeline.sh

# =============================================================================
# Test Helper Functions
# =============================================================================

# Verify a value exists in generated manifest (fetched from GitLab)
verify_manifest_value() {
    local branch="$1"
    local app="$2"
    local yq_path="$3"
    local expected="$4"

    log_step "Verifying manifest: ${app} on ${branch}, path: ${yq_path}"

    local manifest_url="${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/repository/files/manifests%2F${app}%2F${app}.yaml/raw?ref=${branch}"
    local actual
    actual=$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${manifest_url}" | yq eval "${yq_path}" -)

    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "Manifest value matches: ${actual}"
        return 0
    else
        log_fail "Manifest value mismatch: expected '${expected}', got '${actual}'"
        return 1
    fi
}

# Verify cluster state via kubectl
verify_cluster_state() {
    local namespace="$1"
    local resource_type="$2"
    local resource_name="$3"
    local jsonpath="$4"
    local expected="$5"

    log_step "Verifying cluster: ${resource_type}/${resource_name} in ${namespace}"

    local actual
    actual=$(kubectl get "${resource_type}" "${resource_name}" -n "${namespace}" -o jsonpath="${jsonpath}" 2>/dev/null)

    if [[ "${actual}" == "${expected}" ]]; then
        log_pass "Cluster state matches: ${actual}"
        return 0
    else
        log_fail "Cluster state mismatch: expected '${expected}', got '${actual}'"
        return 1
    fi
}

# Wait for Jenkins job to complete
wait_for_jenkins_validation() {
    local timeout="${1:-${K8S_DEPLOYMENTS_VALIDATION_TIMEOUT}}"
    local poll_interval=10
    local elapsed=0

    log_step "Waiting for Jenkins validation (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        # Check for recent successful build
        local result
        result=$(curl -sf -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${JENKINS_URL}/job/${K8S_DEPLOYMENTS_VALIDATION_JOB}/lastBuild/api/json" | jq -r '.result // "BUILDING"')

        case "${result}" in
            SUCCESS)
                log_pass "Jenkins validation passed"
                return 0
                ;;
            FAILURE|ABORTED)
                log_fail "Jenkins validation failed: ${result}"
                return 1
                ;;
            BUILDING|null)
                sleep "${poll_interval}"
                elapsed=$((elapsed + poll_interval))
                ;;
        esac
    done

    log_fail "Jenkins validation timed out after ${timeout}s"
    return 1
}

# Wait for ArgoCD to sync
wait_for_argocd_sync() {
    local app_name="$1"
    local timeout="${2:-${ARGOCD_SYNC_TIMEOUT}}"
    local poll_interval=5
    local elapsed=0

    log_step "Waiting for ArgoCD sync: ${app_name} (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local sync_status health_status
        sync_status=$(kubectl get application "${app_name}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null)
        health_status=$(kubectl get application "${app_name}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.health.status}' 2>/dev/null)

        if [[ "${sync_status}" == "Synced" && "${health_status}" == "Healthy" ]]; then
            log_pass "ArgoCD synced and healthy: ${app_name}"
            return 0
        fi

        sleep "${poll_interval}"
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "ArgoCD sync timed out: ${app_name} (sync=${sync_status}, health=${health_status})"
    return 1
}

# Create MR via GitLab API
create_gitlab_mr() {
    local source_branch="$1"
    local target_branch="$2"
    local title="$3"
    local description="$4"

    log_step "Creating MR: ${source_branch} -> ${target_branch}"

    local response
    response=$(curl -sf -X POST \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"source_branch\": \"${source_branch}\",
            \"target_branch\": \"${target_branch}\",
            \"title\": \"${title}\",
            \"description\": \"${description}\",
            \"remove_source_branch\": true
        }" \
        "${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/merge_requests")

    local mr_iid
    mr_iid=$(echo "${response}" | jq -r '.iid')

    if [[ -n "${mr_iid}" && "${mr_iid}" != "null" ]]; then
        log_pass "Created MR !${mr_iid}"
        echo "${mr_iid}"
        return 0
    else
        log_fail "Failed to create MR: ${response}"
        return 1
    fi
}

# Merge MR via GitLab API
merge_gitlab_mr() {
    local mr_iid="$1"

    log_step "Merging MR !${mr_iid}"

    local response
    response=$(curl -sf -X PUT \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/merge_requests/${mr_iid}/merge")

    local state
    state=$(echo "${response}" | jq -r '.state')

    if [[ "${state}" == "merged" ]]; then
        log_pass "Merged MR !${mr_iid}"
        return 0
    else
        log_fail "Failed to merge MR !${mr_iid}: ${response}"
        return 1
    fi
}

# =============================================================================
# Test Case: L2 - Default Resource Limit
# =============================================================================
test_L2_default_resource_limit() {
    local test_name="T1: L2 Default Resource Limit"
    log_step "Starting ${test_name}"

    local original_value="256Mi"
    local test_value="384Mi"
    local file="services/base/defaults.cue"
    local branch="test-L2-resource-limit-$(date +%s)"

    # 1. Clone k8s-deployments, create branch from main
    local work_dir
    work_dir=$(mktemp -d)
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments" || { log_fail "Failed to clone repository"; return 1; }
    cd "${work_dir}/k8s-deployments" || { log_fail "Failed to change to repo directory"; return 1; }
    git checkout -b "${branch}"

    # 2. Modify defaults.cue
    sed -i "s/memory: \"${original_value}\"/memory: \"${test_value}\"/" "${file}"
    if ! grep -q "memory: \"${test_value}\"" "${file}"; then
        log_fail "sed replacement failed - expected value not found in ${file}"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 3. Commit and push
    git add "${file}"
    git commit -m "test: change default dev memory limit to ${test_value}"
    git push -u origin "${branch}"

    # 4. Create MR: branch -> dev (L2 changes go main->dev, but for test we go direct)
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L2 Resource Limit" "Automated test - will revert")

    # 5. Wait for Jenkins validation
    wait_for_jenkins_validation || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Verify manifest has new value
    verify_manifest_value "dev" "exampleApp" '.spec.template.spec.containers[0].resources.limits.memory' "${test_value}" \
        || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 7. Merge MR
    merge_gitlab_mr "${mr_iid}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 8. Wait for ArgoCD sync
    wait_for_argocd_sync "example-app-dev" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 9. Verify cluster state
    verify_cluster_state "dev" "deployment" "example-app" '{.spec.template.spec.containers[0].resources.limits.memory}' "${test_value}" \
        || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 10. Revert
    log_step "Reverting change..."
    git checkout dev || log_info "Failed to checkout dev for revert"
    git pull origin dev || log_info "Failed to pull dev for revert"
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}" || log_info "Failed to create revert branch"
    sed -i "s/memory: \"${test_value}\"/memory: \"${original_value}\"/" "${file}"
    if ! grep -q "memory: \"${original_value}\"" "${file}"; then
        log_info "Revert sed replacement may have failed"
    fi
    git add "${file}"
    git commit -m "revert: restore default dev memory limit to ${original_value}" || log_info "Failed to commit revert"
    git push -u origin "${revert_branch}" || log_info "Failed to push revert branch"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L2 Resource Limit" "Reverting test change")
    if [[ -n "${revert_mr_iid}" ]]; then
        wait_for_jenkins_validation || log_info "Jenkins validation failed for revert"
        merge_gitlab_mr "${revert_mr_iid}" || log_info "Failed to merge revert MR"
        wait_for_argocd_sync "example-app-dev" || log_info "ArgoCD sync failed for revert"
    else
        log_info "Failed to create revert MR"
    fi

    cleanup_test "${work_dir}" "${branch}"
    log_pass "${test_name} PASSED"
    return 0
}

# =============================================================================
# Test Case: L6 - Annotation (Single Environment)
# =============================================================================
test_L6_annotation() {
    local test_name="T3: L6 Annotation"
    log_step "Starting ${test_name}"

    local annotation_key="test/validation-run"
    local annotation_value="true"
    local branch="test-L6-annotation-$(date +%s)"

    # 1. Clone k8s-deployments, create branch from dev
    local work_dir
    work_dir=$(mktemp -d)
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments" || { log_fail "Failed to clone repository"; return 1; }
    cd "${work_dir}/k8s-deployments" || { log_fail "Failed to change to repo directory"; return 1; }
    git fetch origin dev
    git checkout dev
    git checkout -b "${branch}"

    # 2. Add annotation to env.cue for dev
    # Using yq to modify CUE is tricky; we'll use sed for this specific case
    # Add annotation in the deployment section
    sed -i '/deployment: {/a\            annotations: { "test/validation-run": "true" }' env.cue
    if ! grep -q '"test/validation-run": "true"' env.cue; then
        log_fail "sed replacement failed - annotation not found in env.cue"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 3. Commit and push
    git add env.cue
    git commit -m "test: add validation annotation to dev deployment"
    git push -u origin "${branch}"

    # 4. Create MR: branch -> dev
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L6 Annotation" "Automated test - will revert")

    # 5. Wait for Jenkins validation
    wait_for_jenkins_validation || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Merge MR
    merge_gitlab_mr "${mr_iid}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 7. Wait for ArgoCD sync
    wait_for_argocd_sync "example-app-dev" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 8. Verify cluster state - dev has annotation
    verify_cluster_state "dev" "deployment" "example-app" "{.metadata.annotations.test/validation-run}" "${annotation_value}" \
        || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 9. Verify stage does NOT have annotation (L6 = single env)
    local stage_annotation
    stage_annotation=$(kubectl get deployment example-app -n stage -o jsonpath='{.metadata.annotations.test/validation-run}' 2>/dev/null || echo "")
    if [[ -z "${stage_annotation}" ]]; then
        log_pass "Stage correctly does not have the annotation"
    else
        log_fail "Stage incorrectly has annotation: ${stage_annotation}"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 10. Revert (remove annotation)
    log_step "Reverting change..."
    git checkout dev || log_info "Failed to checkout dev for revert"
    git pull origin dev || log_info "Failed to pull dev for revert"
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}" || log_info "Failed to create revert branch"
    sed -i '/annotations: { "test\/validation-run": "true" }/d' env.cue
    if grep -q '"test/validation-run": "true"' env.cue; then
        log_info "Revert sed replacement may have failed - annotation still present"
    fi
    git add env.cue
    git commit -m "revert: remove validation annotation from dev" || log_info "Failed to commit revert"
    git push -u origin "${revert_branch}" || log_info "Failed to push revert branch"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L6 Annotation" "Reverting test change")
    if [[ -n "${revert_mr_iid}" ]]; then
        wait_for_jenkins_validation || log_info "Jenkins validation failed for revert"
        merge_gitlab_mr "${revert_mr_iid}" || log_info "Failed to merge revert MR"
        wait_for_argocd_sync "example-app-dev" || log_info "ArgoCD sync failed for revert"
    else
        log_info "Failed to create revert MR"
    fi

    cleanup_test "${work_dir}" "${branch}"
    log_pass "${test_name} PASSED"
    return 0
}

# =============================================================================
# Test Case: L6 - Replica Count with Promotion
# =============================================================================
test_L6_replica_promotion() {
    local test_name="T4: L6 Replica Promotion"
    log_step "Starting ${test_name}"

    local original_replicas="1"
    local test_replicas="2"
    local branch="test-L6-replicas-$(date +%s)"

    # 1. Clone k8s-deployments, create branch from dev
    local work_dir
    work_dir=$(mktemp -d)
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments" || { log_fail "Failed to clone repository"; return 1; }
    cd "${work_dir}/k8s-deployments" || { log_fail "Failed to change to repo directory"; return 1; }
    git fetch origin dev
    git checkout dev
    git checkout -b "${branch}"

    # 2. Change replicas in env.cue
    sed -i "s/replicas: ${original_replicas}/replicas: ${test_replicas}/" env.cue
    if ! grep -q "replicas: ${test_replicas}" env.cue; then
        log_fail "sed replacement failed - expected replicas value not found in env.cue"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 3. Commit and push
    git add env.cue
    git commit -m "test: increase replicas to ${test_replicas}"
    git push -u origin "${branch}"

    # 4. Create and merge MR to dev
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L6 Replicas" "Automated test - will revert")
    wait_for_jenkins_validation || { cleanup_test "${work_dir}" "${branch}"; return 1; }
    merge_gitlab_mr "${mr_iid}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }
    wait_for_argocd_sync "example-app-dev" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 5. Verify dev has new replica count
    verify_cluster_state "dev" "deployment" "example-app" '{.spec.replicas}' "${test_replicas}" \
        || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Find and merge promotion MR (dev -> stage)
    log_step "Looking for promotion MR..."
    sleep 10  # Give auto-promote time to create MR
    local promote_mr_iid
    promote_mr_iid=$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/merge_requests?state=opened&target_branch=stage" \
        | jq -r '.[0].iid // empty')

    if [[ -n "${promote_mr_iid}" ]]; then
        log_pass "Found promotion MR !${promote_mr_iid}"
        wait_for_jenkins_validation
        merge_gitlab_mr "${promote_mr_iid}"
        wait_for_argocd_sync "example-app-stage"

        # 7. Verify stage has new replica count
        verify_cluster_state "stage" "deployment" "example-app" '{.spec.replicas}' "${test_replicas}" \
            || { cleanup_test "${work_dir}" "${branch}"; return 1; }
    else
        log_info "No promotion MR found - auto-promote may be disabled"
    fi

    # 8. Revert all environments
    log_step "Reverting changes..."
    for env in dev stage; do
        git fetch origin "${env}" || { log_info "Failed to fetch ${env} for revert"; continue; }
        git checkout "${env}" || { log_info "Failed to checkout ${env} for revert"; continue; }
        git pull origin "${env}" || { log_info "Failed to pull ${env} for revert"; continue; }
        local revert_branch="revert-${branch}-${env}"
        git checkout -b "${revert_branch}" || { log_info "Failed to create revert branch for ${env}"; continue; }
        sed -i "s/replicas: ${test_replicas}/replicas: ${original_replicas}/" env.cue
        if ! grep -q "replicas: ${original_replicas}" env.cue; then
            log_info "Revert sed replacement may have failed for ${env}"
        fi
        git add env.cue
        git commit -m "revert: restore replicas to ${original_replicas} in ${env}" || { log_info "Failed to commit revert for ${env}"; continue; }
        git push -u origin "${revert_branch}" || { log_info "Failed to push revert branch for ${env}"; continue; }
        local revert_mr_iid
        revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "${env}" "[REVERT] Replicas in ${env}" "Reverting test")
        if [[ -n "${revert_mr_iid}" ]]; then
            wait_for_jenkins_validation || log_info "Jenkins validation failed for ${env} revert"
            merge_gitlab_mr "${revert_mr_iid}" || log_info "Failed to merge revert MR for ${env}"
            wait_for_argocd_sync "example-app-${env}" || log_info "ArgoCD sync failed for ${env} revert"
        else
            log_info "Failed to create revert MR for ${env}"
        fi
    done

    cleanup_test "${work_dir}" "${branch}"
    log_pass "${test_name} PASSED"
    return 0
}

# =============================================================================
# Cleanup Helper
# =============================================================================
cleanup_test() {
    local work_dir="$1"
    local branch="$2"

    log_step "Cleaning up test artifacts..."

    # Delete remote branch if it exists (must do BEFORE removing work_dir)
    # We need to be in the git repo context to push, or use the GitLab API
    if [[ -d "${work_dir}/k8s-deployments" ]]; then
        (cd "${work_dir}/k8s-deployments" && git push origin --delete "${branch}" 2>/dev/null) || true
    else
        # Fallback: use GitLab API to delete branch if work_dir already removed
        curl -sf -X DELETE \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/repository/branches/${branch}" 2>/dev/null || true
    fi

    # Remove work directory
    if [[ -d "${work_dir}" ]]; then
        rm -rf "${work_dir}"
    fi

    log_info "Cleanup complete"
}
