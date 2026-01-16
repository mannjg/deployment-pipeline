# K8s-Deployments Pipeline Validation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a validation framework for CUE-based Kubernetes configuration changes, with clean pipeline separation between example-app (L5/L6 edits) and k8s-deployments (validation, manifest generation, deployment).

**Architecture:** CUE configurations are organized in layers L1-L6. L1-L5 changes flow from main→dev→stage→prod via MRs. L6 changes originate in environment branches. example-app creates MRs with CUE edits; k8s-deployments CI validates, generates manifests, and commits them back to the MR branch. ArgoCD syncs on merge.

**Tech Stack:** Bash, CUE, Jenkins (Groovy), GitLab API, kubectl, yq, ArgoCD

---

## Background: CUE Layer Model

| Layer | Location | Changes Affect |
|-------|----------|----------------|
| L1 | `k8s/*.cue` | Raw K8s schemas - all apps, all envs |
| L2 | `services/base/*.cue` | Defaults - all apps using those defaults |
| L3 | `services/resources/*.cue` | Templates - how all apps generate resources |
| L4 | `services/core/app.cue` | Core app template - all apps |
| L5 | `services/apps/*.cue` | App definitions - that app across all envs |
| L6 | `env.cue` (per branch) | Environment config - that app in that env |

## Pipeline Separation

**example-app CI responsibilities:**
- Build app, run tests, push image to Nexus
- Create branch in k8s-deployments
- Sync `deployment/app.cue` → `services/apps/example-app.cue` (L5)
- Update image tag in `env.cue` (L6)
- Create MR to dev branch
- **Stop here** - no manifest generation

**k8s-deployments CI responsibilities (triggered by MR):**
- Validate CUE configuration
- Generate manifests
- Commit manifests back to MR branch
- On merge: ArgoCD syncs, create promotion MR

---

## Task 1: Remove Fallbacks from validate-manifests.sh

**Files:**
- Modify: `k8s-deployments/scripts/validate-manifests.sh:46-62`
- Modify: `k8s-deployments/scripts/lib/preflight.sh` (if yq check needed)

**Step 1: Add yq to preflight checks**

Add at the top of `validate-manifests.sh` after the existing setup:

```bash
# After line 14 (NC='\033[0m')
# Check required tools
if ! command -v yq &> /dev/null; then
    echo -e "${RED}✗ Required tool 'yq' not found${NC}"
    echo "  Install: https://github.com/mikefarah/yq"
    exit 1
fi
```

**Step 2: Remove fallback logic**

Replace lines 46-62 in `validate_yaml_syntax()`:

```bash
validate_yaml_syntax() {
    local file=$1
    local env=$2

    echo "Checking YAML syntax: $(basename "$file")"

    # Check if file is empty
    if [ ! -s "$file" ]; then
        echo -e "${RED}✗ YAML file is empty: $file${NC}"
        return 1
    fi

    # Validate YAML syntax with yq (required, no fallback)
    if ! yq eval '.' "$file" > /dev/null 2>&1; then
        echo -e "${RED}✗ Invalid YAML syntax in: $file${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ YAML syntax valid: $(basename "$file")${NC}"
    return 0
}
```

**Step 3: Run validation locally to verify**

```bash
cd k8s-deployments
./scripts/validate-manifests.sh dev
```

Expected: PASS (yq is installed in your environment)

**Step 4: Commit**

```bash
git add k8s-deployments/scripts/validate-manifests.sh
git commit -m "fix: remove yq fallback, require yq for manifest validation

BREAKING: yq is now required. Update Jenkins agent image if needed."
```

---

## Task 2: Update k8s-deployments-validation.Jenkinsfile to Commit Manifests

**Files:**
- Modify: `k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile:180-212`

**Step 1: Add new stage after 'Validate Manifests'**

Insert after the 'Validate Manifests' stage (around line 212):

```groovy
stage('Commit Generated Manifests') {
    steps {
        container('validator') {
            script {
                echo "=== Committing Generated Manifests ==="

                withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                  usernameVariable: 'GIT_USERNAME',
                                                  passwordVariable: 'GIT_PASSWORD')]) {
                    sh '''
                        # Setup git credentials
                        git config user.name "Jenkins CI"
                        git config user.email "jenkins@local"
                        git config credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

                        # Stage generated manifests
                        git add manifests/

                        # Only commit if there are changes
                        if ! git diff --cached --quiet; then
                            git commit -m "chore: generate manifests for ${BRANCH_NAME}

Automated manifest generation by k8s-deployments CI.
Build: ${BUILD_URL}"

                            git push origin HEAD:${BRANCH_NAME}
                            echo "✓ Manifests committed and pushed"
                        else
                            echo "✓ No manifest changes to commit"
                        fi

                        # Cleanup credentials
                        git config --unset credential.helper || true
                    '''
                }
            }
        }
    }
}
```

**Step 2: Verify Jenkinsfile syntax**

```bash
# If you have Jenkins CLI or a linter
cd k8s-deployments
cat jenkins/k8s-deployments-validation.Jenkinsfile | head -50
```

**Step 3: Commit**

```bash
git add k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile
git commit -m "feat: add manifest commit stage to validation pipeline

Validation pipeline now commits generated manifests back to MR branch.
This enables k8s-deployments to own all manifest generation."
```

---

## Task 3: Simplify example-app Jenkinsfile (Remove Manifest Generation)

**Files:**
- Modify: `example-app/Jenkinsfile:97-141`

**Step 1: Remove manifest generation from deployToEnvironment()**

Replace lines 97-141 with simplified version:

```groovy
                    // Update environment configuration (L5 + L6 only, no manifest generation)
                    sh """
                        cd k8s-deployments

                        # L5: Sync app.cue from source repo (if exists)
                        if [ -f "\${WORKSPACE}/deployment/app.cue" ]; then
                            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            echo "Syncing deployment configuration (L5)..."
                            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            mkdir -p services/apps
                            cp \${WORKSPACE}/deployment/app.cue services/apps/\${APP_NAME}.cue
                            echo "✓ Synced services/apps/\${APP_NAME}.cue"
                        fi

                        # L6: Update image tag in env.cue
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        echo "Updating image tag (L6)..."
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        ./scripts/update-app-image.sh ${environment} ${APP_NAME} "${IMAGE_FOR_DEPLOY}"
                        echo "✓ Updated ${APP_NAME} image in env.cue"

                        # Stage CUE changes only - k8s-deployments CI will generate manifests
                        git add services/apps/ env.cue 2>/dev/null || git add env.cue

                        # Commit with metadata
                        git commit -m "${mrTitle}

L5/L6 update from application CI/CD pipeline.

Changes:
- Synced services/apps/\${APP_NAME}.cue (if changed)
- Updated ${environment} environment image to \${IMAGE_TAG}

Note: Manifests will be generated by k8s-deployments CI.

Build: \${BUILD_URL}
Git commit: \${GIT_SHORT_HASH}
Image: ${IMAGE_FOR_DEPLOY}" || echo "No changes to commit"
                    """
```

**Step 2: Verify the change preserves functionality**

Review the diff to ensure:
- L5 sync is preserved
- L6 image update is preserved
- Manifest generation is removed
- Commit message explains the change

**Step 3: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "refactor: remove manifest generation from example-app pipeline

example-app now only handles L5 (app.cue sync) and L6 (image tag update).
k8s-deployments CI generates manifests when MR is created.

This cleanly separates concerns:
- example-app: build, publish, create deployment MR
- k8s-deployments: validate, generate manifests, deploy"
```

---

## Task 4: Add k8s-deployments Config to infra.env

**Files:**
- Modify: `config/infra.env`

**Step 1: Add k8s-deployments specific config**

Append to `config/infra.env`:

```bash
# -----------------------------------------------------------------------------
# k8s-deployments Pipeline Configuration
# -----------------------------------------------------------------------------
K8S_DEPLOYMENTS_REPO_PATH="p2c/k8s-deployments"
K8S_DEPLOYMENTS_VALIDATION_JOB="k8s-deployments-validation"
K8S_DEPLOYMENTS_CI_JOB="k8s-deployments-ci"

# Validation timeouts (seconds)
K8S_DEPLOYMENTS_VALIDATION_TIMEOUT="${K8S_DEPLOYMENTS_VALIDATION_TIMEOUT:-300}"
```

**Step 2: Commit**

```bash
git add config/infra.env
git commit -m "config: add k8s-deployments pipeline settings to infra.env"
```

---

## Task 5: Create Test Case Library

**Files:**
- Create: `scripts/test/lib/k8s-deployments-tests.sh`

**Step 1: Create the test library file**

```bash
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

    log_step "Creating MR: ${source_branch} → ${target_branch}"

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
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments"
    cd "${work_dir}/k8s-deployments"
    git checkout -b "${branch}"

    # 2. Modify defaults.cue
    sed -i "s/memory: \"${original_value}\"/memory: \"${test_value}\"/" "${file}"

    # 3. Commit and push
    git add "${file}"
    git commit -m "test: change default dev memory limit to ${test_value}"
    git push -u origin "${branch}"

    # 4. Create MR: branch → dev (L2 changes go main→dev, but for test we go direct)
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
    git checkout dev
    git pull origin dev
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}"
    sed -i "s/memory: \"${test_value}\"/memory: \"${original_value}\"/" "${file}"
    git add "${file}"
    git commit -m "revert: restore default dev memory limit to ${original_value}"
    git push -u origin "${revert_branch}"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L2 Resource Limit" "Reverting test change")
    wait_for_jenkins_validation
    merge_gitlab_mr "${revert_mr_iid}"
    wait_for_argocd_sync "example-app-dev"

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
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments"
    cd "${work_dir}/k8s-deployments"
    git fetch origin dev
    git checkout dev
    git checkout -b "${branch}"

    # 2. Add annotation to env.cue for dev
    # Using yq to modify CUE is tricky; we'll use sed for this specific case
    # Add annotation in the deployment section
    sed -i '/deployment: {/a\            annotations: { "test/validation-run": "true" }' env.cue

    # 3. Commit and push
    git add env.cue
    git commit -m "test: add validation annotation to dev deployment"
    git push -u origin "${branch}"

    # 4. Create MR: branch → dev
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
    git checkout dev
    git pull origin dev
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}"
    sed -i '/annotations: { "test\/validation-run": "true" }/d' env.cue
    git add env.cue
    git commit -m "revert: remove validation annotation from dev"
    git push -u origin "${revert_branch}"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L6 Annotation" "Reverting test change")
    wait_for_jenkins_validation
    merge_gitlab_mr "${revert_mr_iid}"
    wait_for_argocd_sync "example-app-dev"

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
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments"
    cd "${work_dir}/k8s-deployments"
    git fetch origin dev
    git checkout dev
    git checkout -b "${branch}"

    # 2. Change replicas in env.cue
    sed -i "s/replicas: ${original_replicas}/replicas: ${test_replicas}/" env.cue

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

    # 6. Find and merge promotion MR (dev → stage)
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
        git fetch origin "${env}"
        git checkout "${env}"
        git pull origin "${env}"
        local revert_branch="revert-${branch}-${env}"
        git checkout -b "${revert_branch}"
        sed -i "s/replicas: ${test_replicas}/replicas: ${original_replicas}/" env.cue
        git add env.cue
        git commit -m "revert: restore replicas to ${original_replicas} in ${env}"
        git push -u origin "${revert_branch}"
        local revert_mr_iid
        revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "${env}" "[REVERT] Replicas in ${env}" "Reverting test")
        wait_for_jenkins_validation
        merge_gitlab_mr "${revert_mr_iid}"
        wait_for_argocd_sync "example-app-${env}"
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

    # Remove work directory
    if [[ -d "${work_dir}" ]]; then
        rm -rf "${work_dir}"
    fi

    # Delete remote branch if it exists
    git push origin --delete "${branch}" 2>/dev/null || true

    log_info "Cleanup complete"
}
```

**Step 2: Make executable**

```bash
chmod +x scripts/test/lib/k8s-deployments-tests.sh
```

**Step 3: Commit**

```bash
git add scripts/test/lib/k8s-deployments-tests.sh
git commit -m "feat: add test case library for k8s-deployments validation"
```

---

## Task 6: Create Main Validation Script

**Files:**
- Create: `scripts/test/validate-k8s-deployments-pipeline.sh`

**Step 1: Create the main validation script**

```bash
#!/bin/bash
# K8s-Deployments Pipeline Validation Script
# Validates CUE configuration changes flow correctly through the pipeline
#
# Usage: ./validate-k8s-deployments-pipeline.sh [--test=<name>]
#
# Options:
#   --test=all    Run all tests (default)
#   --test=L2     Run L2 tests only (default changes)
#   --test=L5     Run L5 tests only (app definition changes)
#   --test=L6     Run L6 tests only (environment config changes)
#   --test=T1     Run specific test by ID
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - curl, jq, git, yq, cue installed
#   - config/infra.env with infrastructure URLs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Load infrastructure config
if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
    source "$REPO_ROOT/config/infra.env"
else
    echo "[✗] Infrastructure config not found: config/infra.env"
    exit 1
fi

# Load test library
if [[ -f "$SCRIPT_DIR/lib/k8s-deployments-tests.sh" ]]; then
    source "$SCRIPT_DIR/lib/k8s-deployments-tests.sh"
else
    echo "[✗] Test library not found: lib/k8s-deployments-tests.sh"
    exit 1
fi

# Map infra.env to script variables
GITLAB_URL="${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set}"
JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"
K8S_DEPLOYMENTS_REPO_URL="${GITLAB_URL}/${K8S_DEPLOYMENTS_REPO_PATH:?K8S_DEPLOYMENTS_REPO_PATH not set}.git"

# Timeouts
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-300}"
K8S_DEPLOYMENTS_VALIDATION_TIMEOUT="${K8S_DEPLOYMENTS_VALIDATION_TIMEOUT:-300}"

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
preflight_checks() {
    echo "=== K8s-Deployments Pipeline Validation ==="
    echo ""
    log_step "Running pre-flight checks..."

    local failed=0

    # Check required tools
    for tool in kubectl curl jq git yq cue; do
        if command -v "${tool}" &>/dev/null; then
            log_info "${tool}: $(command -v ${tool})"
        else
            log_fail "${tool}: not found"
            failed=1
        fi
    done

    # Check kubectl access
    if kubectl cluster-info &>/dev/null; then
        log_info "kubectl: connected to cluster"
    else
        log_fail "kubectl: cannot connect to cluster"
        failed=1
    fi

    # Load credentials from K8s secrets
    log_info "Loading credentials..."
    load_credentials_from_secrets

    # Check GitLab access
    if [[ -n "${GITLAB_TOKEN:-}" ]]; then
        local gitlab_user
        gitlab_user=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/user" | jq -r '.username // empty')
        if [[ -n "$gitlab_user" ]]; then
            log_info "GitLab: authenticated as '$gitlab_user'"
            # Get project ID for API calls
            K8S_DEPLOYMENTS_PROJECT_ID=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "$GITLAB_URL/api/v4/projects/$(echo ${K8S_DEPLOYMENTS_REPO_PATH} | sed 's/\//%2F/g')" | jq -r '.id')
            log_info "GitLab project ID: ${K8S_DEPLOYMENTS_PROJECT_ID}"
        else
            log_fail "GitLab: authentication failed"
            failed=1
        fi
    else
        log_fail "GitLab: GITLAB_TOKEN not set"
        failed=1
    fi

    # Check Jenkins access
    if [[ -n "${JENKINS_TOKEN:-}" ]]; then
        local jenkins_mode
        jenkins_mode=$(curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/api/json" | jq -r '.mode // empty')
        if [[ -n "$jenkins_mode" ]]; then
            log_info "Jenkins: authenticated as '$JENKINS_USER'"
        else
            log_fail "Jenkins: authentication failed"
            failed=1
        fi
    else
        log_fail "Jenkins: JENKINS_TOKEN not set"
        failed=1
    fi

    # Check ArgoCD applications
    for env in dev stage prod; do
        local app_name="example-app-${env}"
        if kubectl get application "${app_name}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
            log_info "ArgoCD: ${app_name} exists"
        else
            log_fail "ArgoCD: ${app_name} not found"
            failed=1
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_fail "Pre-flight checks failed"
        return 1
    fi

    log_pass "Pre-flight checks passed"
    echo ""
    return 0
}

# Load credentials from K8s secrets (same as validate-pipeline.sh)
load_credentials_from_secrets() {
    if [[ -z "${JENKINS_USER:-}" ]]; then
        JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi
}

# -----------------------------------------------------------------------------
# Test Runner
# -----------------------------------------------------------------------------
run_tests() {
    local test_filter="${1:-all}"
    local passed=0
    local failed=0
    local skipped=0

    echo "=== Running Tests (filter: ${test_filter}) ==="
    echo ""

    # Define test matrix
    declare -A tests=(
        ["T1"]="test_L2_default_resource_limit:L2:Default resource limit"
        ["T3"]="test_L6_annotation:L6:Deployment annotation"
        ["T4"]="test_L6_replica_promotion:L6:Replica count with promotion"
    )

    for test_id in "${!tests[@]}"; do
        IFS=':' read -r func layer desc <<< "${tests[$test_id]}"

        # Check filter
        case "${test_filter}" in
            all)
                ;;
            L2|L5|L6)
                if [[ "${layer}" != "${test_filter}" ]]; then
                    log_info "Skipping ${test_id} (layer ${layer})"
                    ((skipped++))
                    continue
                fi
                ;;
            T*)
                if [[ "${test_id}" != "${test_filter}" ]]; then
                    log_info "Skipping ${test_id}"
                    ((skipped++))
                    continue
                fi
                ;;
        esac

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "${test_id}: ${desc} (${layer})"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if ${func}; then
            ((passed++))
        else
            ((failed++))
        fi

        echo ""
    done

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Passed:  ${passed}"
    echo "  Failed:  ${failed}"
    echo "  Skipped: ${skipped}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ ${failed} -gt 0 ]]; then
        log_fail "Some tests failed"
        return 1
    fi

    log_pass "All tests passed"
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local test_filter="all"

    # Parse arguments
    for arg in "$@"; do
        case "${arg}" in
            --test=*)
                test_filter="${arg#*=}"
                ;;
            -h|--help)
                echo "Usage: $0 [--test=<filter>]"
                echo ""
                echo "Filters: all, L2, L5, L6, T1, T3, T4"
                exit 0
                ;;
            *)
                echo "Unknown argument: ${arg}"
                exit 1
                ;;
        esac
    done

    # Run pre-flight checks
    if ! preflight_checks; then
        exit 1
    fi

    # Run tests
    if ! run_tests "${test_filter}"; then
        exit 1
    fi

    exit 0
}

main "$@"
```

**Step 2: Make executable**

```bash
chmod +x scripts/test/validate-k8s-deployments-pipeline.sh
```

**Step 3: Commit**

```bash
git add scripts/test/validate-k8s-deployments-pipeline.sh
git commit -m "feat: add k8s-deployments pipeline validation script

Validates CUE configuration changes flow through the pipeline:
- L2: Default changes (from main)
- L6: Environment config changes (in env branches)
- Promotion: dev → stage → prod

Usage: ./scripts/test/validate-k8s-deployments-pipeline.sh --test=all"
```

---

## Task 7: Add T2 and T5 Test Cases

**Files:**
- Modify: `scripts/test/lib/k8s-deployments-tests.sh`

**Step 1: Add T2 test (L5 - App env var)**

Append to the test library:

```bash
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
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments"
    cd "${work_dir}/k8s-deployments"
    git checkout -b "${branch}"

    # 2. Add env var to services/apps/example-app.cue
    # Insert after the last env var in appEnvVars
    sed -i '/QUARKUS_DATASOURCE_PASSWORD/a\        {\n            name: "'"${env_var_name}"'"\n            value: "'"${env_var_value}"'"\n        },' services/apps/example-app.cue

    # 3. Commit and push
    git add services/apps/example-app.cue
    git commit -m "test: add ${env_var_name} to example-app"
    git push -u origin "${branch}"

    # 4. Create MR: branch → dev
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L5 Env Var" "Automated test - will revert")

    # 5. Wait for Jenkins validation
    wait_for_jenkins_validation || { cleanup_test "${work_dir}" "${branch}"; return 1; }

    # 6. Verify manifest has the env var
    local manifest_url="${GITLAB_URL}/api/v4/projects/${K8S_DEPLOYMENTS_PROJECT_ID}/repository/files/manifests%2FexampleApp%2FexampleApp.yaml/raw?ref=${branch}"
    local has_env_var
    has_env_var=$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${manifest_url}" | yq eval ".spec.template.spec.containers[0].env[] | select(.name == \"${env_var_name}\") | .value" -)

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
    git checkout main
    git pull origin main
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}"
    sed -i "/${env_var_name}/,+3d" services/apps/example-app.cue
    git add services/apps/example-app.cue
    git commit -m "revert: remove ${env_var_name} from example-app"
    git push -u origin "${revert_branch}"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L5 Env Var" "Reverting test")
    wait_for_jenkins_validation
    merge_gitlab_mr "${revert_mr_iid}"
    wait_for_argocd_sync "example-app-dev"

    cleanup_test "${work_dir}" "${branch}"
    log_pass "${test_name} PASSED"
    return 0
}
```

**Step 2: Add T5 test (L6 - ConfigMap value)**

Append to the test library:

```bash
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
    git clone "${K8S_DEPLOYMENTS_REPO_URL}" "${work_dir}/k8s-deployments"
    cd "${work_dir}/k8s-deployments"
    git fetch origin dev
    git checkout dev
    git checkout -b "${branch}"

    # 2. Add key to configMap in env.cue
    sed -i '/configMap: {/,/}/ s/data: {/data: {\n                "'"${key}"'": "'"${value}"'"/' env.cue

    # 3. Commit and push
    git add env.cue
    git commit -m "test: add ${key} to dev configMap"
    git push -u origin "${branch}"

    # 4. Create MR: branch → dev
    local mr_iid
    mr_iid=$(create_gitlab_mr "${branch}" "dev" "[TEST] L6 ConfigMap" "Automated test - will revert")

    # 5. Wait for Jenkins validation
    wait_for_jenkins_validation || { cleanup_test "${work_dir}" "${branch}"; return 1; }

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
    git checkout dev
    git pull origin dev
    local revert_branch="revert-${branch}"
    git checkout -b "${revert_branch}"
    sed -i "/${key}/d" env.cue
    git add env.cue
    git commit -m "revert: remove ${key} from dev configMap"
    git push -u origin "${revert_branch}"
    local revert_mr_iid
    revert_mr_iid=$(create_gitlab_mr "${revert_branch}" "dev" "[REVERT] L6 ConfigMap" "Reverting test")
    wait_for_jenkins_validation
    merge_gitlab_mr "${revert_mr_iid}"
    wait_for_argocd_sync "example-app-dev"

    cleanup_test "${work_dir}" "${branch}"
    log_pass "${test_name} PASSED"
    return 0
}
```

**Step 3: Update test matrix in main script**

In `validate-k8s-deployments-pipeline.sh`, update the tests array:

```bash
    declare -A tests=(
        ["T1"]="test_L2_default_resource_limit:L2:Default resource limit"
        ["T2"]="test_L5_app_env_var:L5:App environment variable"
        ["T3"]="test_L6_annotation:L6:Deployment annotation"
        ["T4"]="test_L6_replica_promotion:L6:Replica count with promotion"
        ["T5"]="test_L6_configmap_value:L6:ConfigMap value"
    )
```

**Step 4: Commit**

```bash
git add scripts/test/lib/k8s-deployments-tests.sh scripts/test/validate-k8s-deployments-pipeline.sh
git commit -m "feat: add T2 (L5 env var) and T5 (L6 configmap) test cases"
```

---

## Task 8: Final Integration Test

**Step 1: Run the validation script locally (dry-run preflight only)**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
./scripts/test/validate-k8s-deployments-pipeline.sh --help
```

Expected output:
```
Usage: ./scripts/test/validate-k8s-deployments-pipeline.sh [--test=<filter>]

Filters: all, L2, L5, L6, T1, T3, T4
```

**Step 2: Run preflight checks**

```bash
./scripts/test/validate-k8s-deployments-pipeline.sh --test=none 2>&1 | head -30
```

This will run preflight without any tests.

**Step 3: Commit final state**

```bash
git add -A
git commit -m "docs: add k8s-deployments validation implementation plan

Complete plan for:
- Pipeline separation (example-app does L5/L6, k8s-deployments generates manifests)
- Validation script with L2, L5, L6 test cases
- Jenkins pipeline updates
- Removal of fallback patterns"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Remove yq fallbacks | `k8s-deployments/scripts/validate-manifests.sh` |
| 2 | Add manifest commit to validation | `k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile` |
| 3 | Simplify example-app pipeline | `example-app/Jenkinsfile` |
| 4 | Add config to infra.env | `config/infra.env` |
| 5 | Create test library | `scripts/test/lib/k8s-deployments-tests.sh` |
| 6 | Create main validation script | `scripts/test/validate-k8s-deployments-pipeline.sh` |
| 7 | Add remaining test cases | Test library updates |
| 8 | Integration test | Verify everything works |
