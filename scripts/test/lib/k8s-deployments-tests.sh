#!/bin/bash
# Test case implementations for k8s-deployments pipeline validation
# Sourced by validate-k8s-deployments-pipeline.sh

# Skip SSL verification for git (self-signed certs in local infrastructure)
export GIT_SSL_NO_VERIFY=1

# =============================================================================
# Git Credential Setup (for GitLab access)
# =============================================================================

# Setup git credentials for GitLab access using the API token
setup_git_credentials() {
    # Use 'oauth2' as username with PAT as password (GitLab convention)
    git config --global credential.helper "!f() { echo username=oauth2; echo password=${GITLAB_TOKEN}; }; f"
    git config --global user.name "Test Automation"
    git config --global user.email "test@local"
}

# Cleanup git credentials
cleanup_git_credentials() {
    git config --global --unset credential.helper 2>/dev/null || true
}

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
    actual=$(curl -sfk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${manifest_url}" | yq eval "${yq_path}" -)

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

# Wait for k8s-deployments branch build to complete
# The simplified pipeline is a MultiBranch Pipeline - we query the branch job directly
wait_for_branch_build() {
    local branch="$1"
    local timeout="${2:-${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-300}}"
    local start_timeout="${K8S_DEPLOYMENTS_BUILD_START_TIMEOUT:-120}"
    local poll_interval=10
    local elapsed=0
    local build_number=""

    # MultiBranch Pipeline job path: job/k8s-deployments/job/{branch}
    local job_name="${K8S_DEPLOYMENTS_JOB:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    log_step "Waiting for k8s-deployments CI build on branch '${branch}' (start timeout: ${start_timeout}s, build timeout: ${timeout}s)..."

    # Get the last build number before we started (if job branch exists)
    # Handle case where job doesn't exist yet (API returns HTML 404 instead of JSON)
    local last_build=0
    local response
    response=$(curl -sfk -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
        "${JENKINS_URL}/${job_path}/lastBuild/api/json" 2>/dev/null) || true
    if echo "$response" | jq empty 2>/dev/null; then
        last_build=$(echo "$response" | jq -r '.number // 0')
    fi

    log_info "Last build was #${last_build}"

    # Wait for a new build to start
    while [[ $elapsed -lt $start_timeout ]]; do
        local current_build=0
        response=$(curl -sfk -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${JENKINS_URL}/${job_path}/lastBuild/api/json" 2>/dev/null) || true
        if echo "$response" | jq empty 2>/dev/null; then
            current_build=$(echo "$response" | jq -r '.number // 0')
        fi

        if [[ "$current_build" -gt "$last_build" ]]; then
            build_number="$current_build"
            log_info "Build #${build_number} started (after ${elapsed}s)"
            break
        fi

        sleep "${poll_interval}"
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        log_fail "Timeout waiting for build to start (${start_timeout}s)"
        log_info "Job URL: ${JENKINS_URL}/${job_path}"
        return 1
    fi

    # Wait for build to complete
    local build_url="${JENKINS_URL}/${job_path}/${build_number}"
    elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local build_info
        build_info=$(curl -sfk -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
            "${build_url}/api/json" 2>/dev/null)

        local building result
        building=$(echo "${build_info}" | jq -r '.building')
        result=$(echo "${build_info}" | jq -r '.result // "BUILDING"')

        if [[ "${building}" == "false" ]]; then
            local duration duration_sec
            duration=$(echo "${build_info}" | jq -r '.duration')
            duration_sec=$((duration / 1000))

            case "${result}" in
                SUCCESS)
                    log_pass "Build #${build_number} completed successfully (${duration_sec}s)"
                    return 0
                    ;;
                FAILURE|ABORTED)
                    log_fail "Build #${build_number} ${result}"
                    log_info "Build URL: ${build_url}"
                    return 1
                    ;;
            esac
        fi

        sleep "${poll_interval}"
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for build #${build_number} to complete (${timeout}s)"
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
    response=$(curl -sfk -X POST \
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
    response=$(curl -sfk -X PUT \
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

    # 5. Wait for Jenkins branch build
    wait_for_branch_build "${branch}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

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
        wait_for_branch_build "${revert_branch}" || log_info "Jenkins build failed for revert"
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

    # 5. Wait for Jenkins branch build
    wait_for_branch_build "${branch}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

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
        wait_for_branch_build "${revert_branch}" || log_info "Jenkins build failed for revert"
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
    wait_for_branch_build "${branch}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }
    merge_gitlab_mr "${mr_iid}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }
    wait_for_argocd_sync "example-app-dev" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 5. Verify dev has new replica count
    verify_cluster_state "dev" "deployment" "example-app" '{.spec.replicas}' "${test_replicas}" \
        || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Find and merge promotion MR (dev -> stage)
    # Note: With simplified pipeline, promotion MR is auto-created after successful dev deployment
    log_step "Looking for auto-created promotion MR..."
    sleep 30  # Give k8s-deployments CI time to deploy and create promotion MR
    local promote_mr_iid
    promote_mr_iid=$(curl -sfk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/merge_requests?state=opened&target_branch=stage" \
        | jq -r 'first(.[] | select(.source_branch | startswith("promote-stage-"))) | .iid // empty')

    if [[ -n "${promote_mr_iid}" ]]; then
        log_pass "Found promotion MR !${promote_mr_iid}"
        merge_gitlab_mr "${promote_mr_iid}"
        wait_for_argocd_sync "example-app-stage"

        # 7. Verify stage has new replica count
        verify_cluster_state "stage" "deployment" "example-app" '{.spec.replicas}' "${test_replicas}" \
            || { cleanup_test "${work_dir}" "${branch}"; return 1; }
    else
        log_info "No promotion MR found - auto-promote may be disabled or still running"
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
            wait_for_branch_build "${revert_branch}" || log_info "Jenkins build failed for ${env} revert"
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
# Test Case: L5 - App Environment Variable
# =============================================================================
test_L5_app_env_var() {
    local test_name="T2: L5 App Environment Variable"
    log_step "Starting ${test_name}"

    local env_var_name="TEST_VALIDATION_VAR"
    local env_var_value="validation-test-value"
    local branch="test-L5-envvar-$(date +%s)"

    # 1. Clone k8s-deployments, create branch from main
    local work_dir
    work_dir=$(mktemp -d)
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments" || { log_fail "Failed to clone repository"; return 1; }
    cd "${work_dir}/k8s-deployments" || { log_fail "Failed to change to repo directory"; return 1; }
    git checkout -b "${branch}"

    # 2. Add env var to services/apps/example-app.cue
    # Insert after the last env var in appEnvVars
    sed -i '/QUARKUS_DATASOURCE_PASSWORD/a\        {\n            name: "'"${env_var_name}"'"\n            value: "'"${env_var_value}"'"\n        },' services/apps/example-app.cue
    if ! grep -q "${env_var_name}" services/apps/example-app.cue; then
        log_fail "sed replacement failed - env var not found in example-app.cue"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 3. Commit and push
    git add services/apps/example-app.cue
    git commit -m "test: add ${env_var_name} to example-app"
    git push -u origin "${branch}"

    # 4. Create MR: branch -> dev
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L5 Env Var" "Automated test - will revert")

    # 5. Wait for Jenkins branch build
    wait_for_branch_build "${branch}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Verify manifest has the env var
    local manifest_url="${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/repository/files/manifests%2FexampleApp%2FexampleApp.yaml/raw?ref=${branch}"
    local has_env_var
    has_env_var=$(curl -sfk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${manifest_url}" | yq eval ".spec.template.spec.containers[0].env[] | select(.name == \"${env_var_name}\") | .value" -)

    if [[ "${has_env_var}" == "${env_var_value}" ]]; then
        log_pass "Manifest contains env var: ${env_var_name}=${env_var_value}"
    else
        log_fail "Manifest missing env var"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 7. Merge MR
    merge_gitlab_mr "${mr_iid}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 8. Wait for ArgoCD sync
    wait_for_argocd_sync "example-app-dev" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 9. Verify cluster state
    local cluster_env_var
    cluster_env_var=$(kubectl get deployment example-app -n dev -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name=='${env_var_name}')].value}")

    if [[ "${cluster_env_var}" == "${env_var_value}" ]]; then
        log_pass "Cluster has env var: ${env_var_name}=${env_var_value}"
    else
        log_fail "Cluster missing env var"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 10. Revert
    log_step "Reverting change..."
    git checkout main || log_info "Failed to checkout main for revert"
    git pull origin main || log_info "Failed to pull main for revert"
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}" || log_info "Failed to create revert branch"
    sed -i "/${env_var_name}/,+3d" services/apps/example-app.cue
    if grep -q "${env_var_name}" services/apps/example-app.cue; then
        log_info "Revert sed replacement may have failed - env var still present"
    fi
    git add services/apps/example-app.cue
    git commit -m "revert: remove ${env_var_name} from example-app" || log_info "Failed to commit revert"
    git push -u origin "${revert_branch}" || log_info "Failed to push revert branch"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L5 Env Var" "Reverting test")
    if [[ -n "${revert_mr_iid}" ]]; then
        wait_for_branch_build "${revert_branch}" || log_info "Jenkins build failed for revert"
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
# Test Case: L6 - ConfigMap Value
# =============================================================================
test_L6_configmap_value() {
    local test_name="T5: L6 ConfigMap Value"
    log_step "Starting ${test_name}"

    local key="test-validation-key"
    local value="test-validation-value"
    local branch="test-L6-configmap-$(date +%s)"

    # 1. Clone k8s-deployments, create branch from dev
    local work_dir
    work_dir=$(mktemp -d)
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments" || { log_fail "Failed to clone repository"; return 1; }
    cd "${work_dir}/k8s-deployments" || { log_fail "Failed to change to repo directory"; return 1; }
    git fetch origin dev
    git checkout dev
    git checkout -b "${branch}"

    # 2. Add key to configMap in env.cue
    sed -i '/configMap: {/,/}/ s/data: {/data: {\n                "'"${key}"'": "'"${value}"'"/' env.cue
    if ! grep -q "${key}" env.cue; then
        log_fail "sed replacement failed - key not found in env.cue"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 3. Commit and push
    git add env.cue
    git commit -m "test: add ${key} to dev configMap"
    git push -u origin "${branch}"

    # 4. Create MR: branch -> dev
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L6 ConfigMap" "Automated test - will revert")

    # 5. Wait for Jenkins branch build
    wait_for_branch_build "${branch}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Merge MR
    merge_gitlab_mr "${mr_iid}" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 7. Wait for ArgoCD sync
    wait_for_argocd_sync "example-app-dev" || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 8. Verify ConfigMap in cluster
    local cm_value
    cm_value=$(kubectl get configmap example-app -n dev -o jsonpath="{.data.${key}}" 2>/dev/null)

    if [[ "${cm_value}" == "${value}" ]]; then
        log_pass "ConfigMap has key: ${key}=${value}"
    else
        log_fail "ConfigMap missing key or wrong value: got '${cm_value}'"
        cleanup_test "${work_dir}" "${branch}"
        return 1
    fi

    # 9. Revert
    log_step "Reverting change..."
    git checkout dev || log_info "Failed to checkout dev for revert"
    git pull origin dev || log_info "Failed to pull dev for revert"
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}" || log_info "Failed to create revert branch"
    sed -i "/${key}/d" env.cue
    if grep -q "${key}" env.cue; then
        log_info "Revert sed replacement may have failed - key still present"
    fi
    git add env.cue
    git commit -m "revert: remove ${key} from dev configMap" || log_info "Failed to commit revert"
    git push -u origin "${revert_branch}" || log_info "Failed to push revert branch"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L6 ConfigMap" "Reverting test")
    if [[ -n "${revert_mr_iid}" ]]; then
        wait_for_branch_build "${revert_branch}" || log_info "Jenkins build failed for revert"
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
        curl -sfk -X DELETE \
            -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/repository/branches/${branch}" 2>/dev/null || true
    fi

    # Remove work directory
    if [[ -d "${work_dir}" ]]; then
        rm -rf "${work_dir}"
    fi

    log_info "Cleanup complete"
}
