# Use Case Verification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the verification framework for all 15 k8s-deployments use cases with full pipeline execution.

**Architecture:** Build reusable helper libraries (assertions.sh, pipeline-wait.sh) that encapsulate K8s verification and MR-gated promotion patterns. Each use case gets a thin demo script that uses these helpers. Status is tracked in USE_CASES.md.

**Tech Stack:** Bash (orchestration), Python (CUE editing), kubectl, GitLab API, Jenkins API, ArgoCD

---

## Task 1: Add Status Table to USE_CASES.md

**Files:**
- Modify: `docs/USE_CASES.md` (end of file)

**Step 1: Add the status tracking section**

Add this section at the end of USE_CASES.md, before "## Related Documentation":

```markdown
---

## Implementation Status

| ID | Use Case | CUE Support | Demo Script | Pipeline Verified | Branch | Notes |
|----|----------|-------------|-------------|-------------------|--------|-------|
| UC-A1 | Adjust replica count | 🔲 | 🔲 | 🔲 | — | |
| UC-A2 | Enable debug mode | 🔲 | 🔲 | 🔲 | — | |
| UC-A3 | Env-specific ConfigMap | ✅ | ✅ | 🔲 | — | Demo exists, needs pipeline verification |
| UC-B1 | Add app env var | 🔲 | 🔲 | 🔲 | — | |
| UC-B2 | Add app annotation | 🔲 | 🔲 | 🔲 | — | |
| UC-B3 | Add app ConfigMap entry | 🔲 | 🔲 | 🔲 | — | |
| UC-B4 | App ConfigMap with env override | ✅ | ✅ | 🔲 | — | Demo exists, needs pipeline verification |
| UC-B5 | App probe with env override | 🔲 | 🔲 | 🔲 | — | |
| UC-B6 | App env var with env override | 🔲 | 🔲 | 🔲 | — | |
| UC-C1 | Add default label | 🔲 | 🔲 | 🔲 | — | **Start here** |
| UC-C2 | Add security context | ⚠️ | 🔲 | 🔲 | — | Schema exists, disabled by default |
| UC-C3 | Change deployment strategy | 🔲 | 🔲 | 🔲 | — | |
| UC-C4 | Add standard pod annotation | 🔲 | 🔲 | 🔲 | — | |
| UC-C5 | Platform default + app override | 🔲 | 🔲 | 🔲 | — | Multi-app pivot (uses postgres) |
| UC-C6 | Platform default + env override | 🔲 | 🔲 | 🔲 | — | |

**Status Legend:**
- 🔲 Not started
- 🚧 In progress
- ⚠️ Partial / has known issues
- ✅ Verified complete
```

**Step 2: Verify the file renders correctly**

Run: `head -50 docs/USE_CASES.md && echo "..." && tail -30 docs/USE_CASES.md`

**Step 3: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: add implementation status table to USE_CASES.md"
```

---

## Task 2: Create assertions.sh Helper Library

**Files:**
- Create: `scripts/demo/lib/assertions.sh`

**Step 1: Create the assertions library**

```bash
#!/bin/bash
# assertions.sh - K8s verification functions for demo scripts
#
# Source this file: source "$(dirname "$0")/lib/assertions.sh"
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - demo-helpers.sh sourced (for demo_verify, demo_fail, etc.)

# ============================================================================
# CONFIGURATION
# ============================================================================

# Default timeouts (can be overridden)
ASSERT_TIMEOUT="${ASSERT_TIMEOUT:-30}"
ASSERT_POLL_INTERVAL="${ASSERT_POLL_INTERVAL:-5}"

# ============================================================================
# RESOURCE EXISTENCE
# ============================================================================

# Assert that a K8s resource exists
# Usage: assert_resource_exists <namespace> <kind> <name>
assert_resource_exists() {
    local namespace="$1"
    local kind="$2"
    local name="$3"

    if kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
        demo_verify "Resource exists: $kind/$name in $namespace"
        return 0
    else
        demo_fail "Resource not found: $kind/$name in $namespace"
        return 1
    fi
}

# Assert that a K8s resource does NOT exist
# Usage: assert_resource_absent <namespace> <kind> <name>
assert_resource_absent() {
    local namespace="$1"
    local kind="$2"
    local name="$3"

    if ! kubectl get "$kind" "$name" -n "$namespace" &>/dev/null; then
        demo_verify "Resource absent (expected): $kind/$name in $namespace"
        return 0
    else
        demo_fail "Resource exists but should not: $kind/$name in $namespace"
        return 1
    fi
}

# ============================================================================
# FIELD VALUE ASSERTIONS
# ============================================================================

# Assert that a field equals an expected value
# Usage: assert_field_equals <namespace> <kind> <name> <jsonpath> <expected>
assert_field_equals() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local jsonpath="$4"
    local expected="$5"

    local actual
    actual=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null)

    if [[ "$actual" == "$expected" ]]; then
        demo_verify "Field $jsonpath = '$expected'"
        return 0
    else
        demo_fail "Field $jsonpath: expected '$expected', got '$actual'"
        return 1
    fi
}

# Assert that a field contains a substring
# Usage: assert_field_contains <namespace> <kind> <name> <jsonpath> <substring>
assert_field_contains() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local jsonpath="$4"
    local substring="$5"

    local actual
    actual=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null)

    if [[ "$actual" == *"$substring"* ]]; then
        demo_verify "Field $jsonpath contains '$substring'"
        return 0
    else
        demo_fail "Field $jsonpath does not contain '$substring' (value: '$actual')"
        return 1
    fi
}

# Assert that a field does NOT exist or is empty
# Usage: assert_field_absent <namespace> <kind> <name> <jsonpath>
assert_field_absent() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local jsonpath="$4"

    local actual
    actual=$(kubectl get "$kind" "$name" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null)

    if [[ -z "$actual" ]]; then
        demo_verify "Field $jsonpath is absent/empty (expected)"
        return 0
    else
        demo_fail "Field $jsonpath exists but should not: '$actual'"
        return 1
    fi
}

# ============================================================================
# LABEL ASSERTIONS
# ============================================================================

# Assert that a resource has a specific label
# Usage: assert_label_equals <namespace> <kind> <name> <label_key> <expected_value>
assert_label_equals() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local label_key="$4"
    local expected_value="$5"

    assert_field_equals "$namespace" "$kind" "$name" "{.metadata.labels.$label_key}" "$expected_value"
}

# Assert that a resource does NOT have a specific label
# Usage: assert_label_absent <namespace> <kind> <name> <label_key>
assert_label_absent() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local label_key="$4"

    assert_field_absent "$namespace" "$kind" "$name" "{.metadata.labels.$label_key}"
}

# ============================================================================
# ANNOTATION ASSERTIONS
# ============================================================================

# Assert that a resource has a specific annotation
# Usage: assert_annotation_equals <namespace> <kind> <name> <annotation_key> <expected_value>
assert_annotation_equals() {
    local namespace="$1"
    local kind="$2"
    local name="$3"
    local annotation_key="$4"
    local expected_value="$5"

    # Annotations with dots need bracket notation
    local jsonpath="{.metadata.annotations['$annotation_key']}"
    assert_field_equals "$namespace" "$kind" "$name" "$jsonpath" "$expected_value"
}

# ============================================================================
# POD TEMPLATE ASSERTIONS (for Deployments)
# ============================================================================

# Assert a label on the pod template of a deployment
# Usage: assert_pod_label_equals <namespace> <deployment_name> <label_key> <expected_value>
assert_pod_label_equals() {
    local namespace="$1"
    local deployment="$2"
    local label_key="$3"
    local expected_value="$4"

    assert_field_equals "$namespace" "deployment" "$deployment" \
        "{.spec.template.metadata.labels.$label_key}" "$expected_value"
}

# Assert an annotation on the pod template of a deployment
# Usage: assert_pod_annotation_equals <namespace> <deployment_name> <annotation_key> <expected_value>
assert_pod_annotation_equals() {
    local namespace="$1"
    local deployment="$2"
    local annotation_key="$3"
    local expected_value="$4"

    local jsonpath="{.spec.template.metadata.annotations['$annotation_key']}"
    assert_field_equals "$namespace" "deployment" "$deployment" "$jsonpath" "$expected_value"
}

# ============================================================================
# CROSS-ENVIRONMENT ASSERTIONS
# ============================================================================

# Assert a value exists in one env but not in another (isolation test)
# Usage: assert_env_isolation <kind> <name> <jsonpath> <expected> <env_has> <env_lacks>
assert_env_isolation() {
    local kind="$1"
    local name="$2"
    local jsonpath="$3"
    local expected="$4"
    local env_has="$5"
    local env_lacks="$6"

    demo_info "Testing environment isolation..."

    # Verify value exists in env_has
    if ! assert_field_equals "$env_has" "$kind" "$name" "$jsonpath" "$expected"; then
        demo_fail "Isolation test: value should exist in $env_has"
        return 1
    fi

    # Verify value does NOT exist in env_lacks
    local actual
    actual=$(kubectl get "$kind" "$name" -n "$env_lacks" -o jsonpath="$jsonpath" 2>/dev/null)

    if [[ "$actual" != "$expected" ]]; then
        demo_verify "Isolation confirmed: $env_lacks does not have value '$expected'"
        return 0
    else
        demo_fail "Isolation violated: $env_lacks has value '$expected' (should not)"
        return 1
    fi
}

# Assert a value is the same across multiple environments (propagation test)
# Usage: assert_env_propagation <kind> <name> <jsonpath> <expected> <envs...>
assert_env_propagation() {
    local kind="$1"
    local name="$2"
    local jsonpath="$3"
    local expected="$4"
    shift 4
    local envs=("$@")

    demo_info "Testing environment propagation across: ${envs[*]}"

    local failed=0
    for env in "${envs[@]}"; do
        if ! assert_field_equals "$env" "$kind" "$name" "$jsonpath" "$expected"; then
            failed=1
        fi
    done

    if [[ $failed -eq 0 ]]; then
        demo_verify "Propagation confirmed: value '$expected' present in all environments"
        return 0
    else
        demo_fail "Propagation incomplete: not all environments have value '$expected'"
        return 1
    fi
}

# ============================================================================
# CONFIGMAP ASSERTIONS
# ============================================================================

# Assert a ConfigMap data entry equals expected value
# Usage: assert_configmap_entry <namespace> <configmap_name> <key> <expected_value>
assert_configmap_entry() {
    local namespace="$1"
    local configmap="$2"
    local key="$3"
    local expected="$4"

    local jsonpath="{.data['$key']}"
    assert_field_equals "$namespace" "configmap" "$configmap" "$jsonpath" "$expected"
}

# Assert a ConfigMap data entry does NOT exist
# Usage: assert_configmap_entry_absent <namespace> <configmap_name> <key>
assert_configmap_entry_absent() {
    local namespace="$1"
    local configmap="$2"
    local key="$3"

    local jsonpath="{.data['$key']}"
    assert_field_absent "$namespace" "configmap" "$configmap" "$jsonpath"
}

# ============================================================================
# DEPLOYMENT SPEC ASSERTIONS
# ============================================================================

# Assert deployment replica count
# Usage: assert_replicas <namespace> <deployment_name> <expected_count>
assert_replicas() {
    local namespace="$1"
    local deployment="$2"
    local expected="$3"

    assert_field_equals "$namespace" "deployment" "$deployment" "{.spec.replicas}" "$expected"
}

# Assert deployment image
# Usage: assert_image <namespace> <deployment_name> <expected_image>
assert_image() {
    local namespace="$1"
    local deployment="$2"
    local expected="$3"

    assert_field_equals "$namespace" "deployment" "$deployment" \
        "{.spec.template.spec.containers[0].image}" "$expected"
}

# Assert deployment image contains substring (for version checks)
# Usage: assert_image_contains <namespace> <deployment_name> <substring>
assert_image_contains() {
    local namespace="$1"
    local deployment="$2"
    local substring="$3"

    assert_field_contains "$namespace" "deployment" "$deployment" \
        "{.spec.template.spec.containers[0].image}" "$substring"
}
```

**Step 2: Make it executable and verify syntax**

Run: `chmod +x scripts/demo/lib/assertions.sh && bash -n scripts/demo/lib/assertions.sh && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add scripts/demo/lib/assertions.sh
git commit -m "feat(demo): add assertions.sh helper library for K8s verification"
```

---

## Task 3: Create pipeline-wait.sh Helper Library

**Files:**
- Create: `scripts/demo/lib/pipeline-wait.sh`

**Step 1: Create the pipeline wait library**

```bash
#!/bin/bash
# pipeline-wait.sh - MR, Jenkins, and ArgoCD helpers for demo scripts
#
# Source this file: source "$(dirname "$0")/lib/pipeline-wait.sh"
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - config/infra.env sourced
#   - demo-helpers.sh sourced (for demo_action, demo_verify, etc.)
#   - GITLAB_TOKEN, JENKINS_USER, JENKINS_TOKEN set (or loaded from secrets)

# ============================================================================
# CONFIGURATION
# ============================================================================

PIPELINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PIPELINE_LIB_DIR/../../.." && pwd)"

# Load infrastructure config if not already loaded
if [[ -z "${GITLAB_URL_EXTERNAL:-}" ]]; then
    if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
        source "$REPO_ROOT/config/infra.env"
    else
        echo "ERROR: config/infra.env not found and GITLAB_URL_EXTERNAL not set"
        exit 1
    fi
fi

# Default timeouts (can be overridden)
MR_CREATE_TIMEOUT="${MR_CREATE_TIMEOUT:-30}"
MR_PIPELINE_TIMEOUT="${MR_PIPELINE_TIMEOUT:-180}"
JENKINS_BUILD_START_TIMEOUT="${JENKINS_BUILD_START_TIMEOUT:-60}"
JENKINS_BUILD_TIMEOUT="${JENKINS_BUILD_TIMEOUT:-120}"
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-120}"

# ============================================================================
# CREDENTIAL LOADING
# ============================================================================

# Load credentials from K8s secrets if not already set
load_pipeline_credentials() {
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${JENKINS_USER:-}" ]]; then
        JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    # Verify credentials loaded
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        demo_fail "GITLAB_TOKEN not available"
        return 1
    fi
    if [[ -z "${JENKINS_USER:-}" ]] || [[ -z "${JENKINS_TOKEN:-}" ]]; then
        demo_fail "Jenkins credentials not available"
        return 1
    fi

    return 0
}

# ============================================================================
# GITLAB MR OPERATIONS
# ============================================================================

# URL-encode a project path
_encode_project() {
    echo "$1" | sed 's/\//%2F/g'
}

# Create a merge request and return the MR IID
# Usage: create_mr <source_branch> <target_branch> <title> [description]
# Returns: MR IID on stdout, or exits on failure
create_mr() {
    local source_branch="$1"
    local target_branch="$2"
    local title="$3"
    local description="${4:-Automated MR from demo script}"

    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    demo_action "Creating MR: $source_branch → $target_branch"

    local response
    response=$(curl -sk -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"source_branch\":\"$source_branch\",\"target_branch\":\"$target_branch\",\"title\":\"$title\",\"description\":\"$description\"}" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests" 2>/dev/null)

    local mr_iid
    mr_iid=$(echo "$response" | jq -r '.iid // empty')

    if [[ -n "$mr_iid" ]]; then
        demo_verify "Created MR !$mr_iid"
        echo "$mr_iid"
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.message // .error // "Unknown error"')
        demo_fail "Failed to create MR: $error"
        return 1
    fi
}

# Get MR details
# Usage: get_mr <mr_iid>
get_mr() {
    local mr_iid="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests/$mr_iid" 2>/dev/null
}

# Wait for MR pipeline to complete
# Usage: wait_for_mr_pipeline <mr_iid> [timeout]
# Returns: 0 if passed, 1 if failed
wait_for_mr_pipeline() {
    local mr_iid="$1"
    local timeout="${2:-$MR_PIPELINE_TIMEOUT}"

    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    demo_action "Waiting for MR !$mr_iid pipeline (timeout ${timeout}s)..."

    local poll_interval=10
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local mr_info
        mr_info=$(get_mr "$mr_iid")

        local pipeline_status
        pipeline_status=$(echo "$mr_info" | jq -r '.head_pipeline.status // "pending"')

        case "$pipeline_status" in
            success)
                demo_verify "MR pipeline passed"
                return 0
                ;;
            failed|canceled)
                demo_fail "MR pipeline $pipeline_status"
                return 1
                ;;
            *)
                demo_info "Pipeline status: $pipeline_status (${elapsed}s elapsed)"
                ;;
        esac

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    demo_fail "Timeout waiting for MR pipeline (${timeout}s)"
    return 1
}

# Accept/merge an MR
# Usage: accept_mr <mr_iid>
accept_mr() {
    local mr_iid="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    demo_action "Merging MR !$mr_iid..."

    local response
    response=$(curl -sk -X PUT \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests/$mr_iid/merge" 2>/dev/null)

    local state
    state=$(echo "$response" | jq -r '.state // .message // "unknown"')

    if [[ "$state" == "merged" ]]; then
        demo_verify "MR !$mr_iid merged"
        return 0
    else
        demo_fail "Failed to merge MR: $state"
        return 1
    fi
}

# Get MR diff to verify contents
# Usage: get_mr_diff <mr_iid>
get_mr_diff() {
    local mr_iid="$1"
    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/merge_requests/$mr_iid/changes" 2>/dev/null
}

# Assert MR diff contains expected content
# Usage: assert_mr_contains_diff <mr_iid> <file_pattern> <expected_content>
assert_mr_contains_diff() {
    local mr_iid="$1"
    local file_pattern="$2"
    local expected_content="$3"

    demo_action "Verifying MR !$mr_iid contains expected changes..."

    local changes
    changes=$(get_mr_diff "$mr_iid")

    # Check if any file matching pattern has the expected content in diff
    local matching_diff
    matching_diff=$(echo "$changes" | jq -r --arg pattern "$file_pattern" \
        '.changes[] | select(.new_path | test($pattern)) | .diff' 2>/dev/null)

    if [[ "$matching_diff" == *"$expected_content"* ]]; then
        demo_verify "MR diff contains '$expected_content' in files matching '$file_pattern'"
        return 0
    else
        demo_fail "MR diff does not contain '$expected_content' in files matching '$file_pattern'"
        return 1
    fi
}

# ============================================================================
# JENKINS OPERATIONS
# ============================================================================

# Trigger MultiBranch Pipeline scan
trigger_jenkins_scan() {
    local job_name="${1:-k8s-deployments}"

    demo_action "Triggering Jenkins branch scan for $job_name..."

    # Get CSRF crumb
    local cookie_jar=$(mktemp)
    local crumb_file=$(mktemp)

    curl -sk -c "$cookie_jar" -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL_EXTERNAL}/crumbIssuer/api/json" > "$crumb_file" 2>/dev/null || true

    local crumb_header=""
    if jq empty "$crumb_file" 2>/dev/null; then
        local crumb_field=$(jq -r '.crumbRequestField // empty' "$crumb_file")
        local crumb_value=$(jq -r '.crumb // empty' "$crumb_file")
        if [[ -n "$crumb_field" && -n "$crumb_value" ]]; then
            crumb_header="-H ${crumb_field}:${crumb_value}"
        fi
    fi

    # Trigger scan
    curl -sk -w "%{http_code}" -o /dev/null -X POST \
        -b "$cookie_jar" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        $crumb_header \
        "${JENKINS_URL_EXTERNAL}/job/${job_name}/build?delay=0sec" 2>/dev/null || true

    rm -f "$cookie_jar" "$crumb_file"

    sleep 3  # Give Jenkins time to start scanning
}

# Get current build number for a branch
# Usage: get_jenkins_build_number <branch>
get_jenkins_build_number() {
    local branch="$1"
    local job_name="${2:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    local response
    response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL_EXTERNAL}/${job_path}/lastBuild/api/json" 2>/dev/null) || true

    if echo "$response" | jq empty 2>/dev/null; then
        echo "$response" | jq -r '.number // 0'
    else
        echo "0"
    fi
}

# Wait for a new Jenkins build to complete
# Usage: wait_for_jenkins_build <branch> [baseline_build] [timeout]
wait_for_jenkins_build() {
    local branch="$1"
    local baseline="${2:-}"
    local timeout="${3:-$JENKINS_BUILD_TIMEOUT}"

    local job_name="${DEPLOYMENTS_REPO_NAME:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    # Trigger scan to ensure Jenkins sees the branch
    trigger_jenkins_scan "$job_name"

    # Get baseline if not provided
    if [[ -z "$baseline" ]]; then
        baseline=$(get_jenkins_build_number "$branch")
    fi

    demo_action "Waiting for Jenkins build on $branch (baseline #$baseline, timeout ${timeout}s)..."

    local poll_interval=10
    local elapsed=0
    local build_number=""
    local build_url=""

    # Wait for new build to start
    local start_timeout="${JENKINS_BUILD_START_TIMEOUT:-60}"
    while [[ $elapsed -lt $start_timeout ]]; do
        local current=$(get_jenkins_build_number "$branch")

        if [[ "$current" -gt "$baseline" ]]; then
            build_number="$current"
            build_url="${JENKINS_URL_EXTERNAL}/${job_path}/$build_number"
            demo_info "Build #$build_number started"
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        demo_fail "Timeout waiting for build to start (${start_timeout}s)"
        return 1
    fi

    # Wait for build to complete
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local build_info
        build_info=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" "$build_url/api/json" 2>/dev/null)

        local building=$(echo "$build_info" | jq -r '.building')
        local result=$(echo "$build_info" | jq -r '.result // "null"')

        if [[ "$building" == "false" ]]; then
            if [[ "$result" == "SUCCESS" ]]; then
                demo_verify "Build #$build_number completed successfully"
                return 0
            else
                demo_fail "Build #$build_number $result"
                return 1
            fi
        fi

        demo_info "Build #$build_number running... (${elapsed}s elapsed)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    demo_fail "Timeout waiting for build to complete (${timeout}s)"
    return 1
}

# ============================================================================
# ARGOCD OPERATIONS
# ============================================================================

# Get current ArgoCD sync revision
# Usage: get_argocd_revision <app_name>
get_argocd_revision() {
    local app_name="$1"
    local namespace="${ARGOCD_NAMESPACE:-argocd}"

    kubectl get application "$app_name" -n "$namespace" \
        -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo ""
}

# Trigger ArgoCD refresh
# Usage: trigger_argocd_refresh <app_name>
trigger_argocd_refresh() {
    local app_name="$1"
    local namespace="${ARGOCD_NAMESPACE:-argocd}"

    kubectl annotate application "$app_name" -n "$namespace" \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
}

# Wait for ArgoCD to sync
# Usage: wait_for_argocd_sync <app_name> [baseline_revision] [timeout]
wait_for_argocd_sync() {
    local app_name="$1"
    local baseline="${2:-}"
    local timeout="${3:-$ARGOCD_SYNC_TIMEOUT}"
    local namespace="${ARGOCD_NAMESPACE:-argocd}"

    # Get baseline if not provided
    if [[ -z "$baseline" ]]; then
        baseline=$(get_argocd_revision "$app_name")
    fi

    demo_action "Waiting for ArgoCD sync: $app_name (timeout ${timeout}s)..."

    # Trigger refresh
    trigger_argocd_refresh "$app_name"

    local poll_interval=10
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local app_status
        app_status=$(kubectl get application "$app_name" -n "$namespace" -o json 2>/dev/null)

        local sync_status=$(echo "$app_status" | jq -r '.status.sync.status // "Unknown"')
        local health_status=$(echo "$app_status" | jq -r '.status.health.status // "Unknown"')
        local current_revision=$(echo "$app_status" | jq -r '.status.sync.revision // ""')

        # Wait for revision to change AND status to be Synced+Healthy
        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$current_revision" != "$baseline" ]]; then
            demo_verify "$app_name synced and healthy"
            return 0
        fi

        demo_info "Status: sync=$sync_status health=$health_status rev=${current_revision:0:7} (${elapsed}s)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    demo_fail "Timeout waiting for ArgoCD sync (${timeout}s)"
    return 1
}

# ============================================================================
# COMBINED FLOWS
# ============================================================================

# Complete MR-gated promotion flow for one environment
# Usage: promote_via_mr <source_branch> <target_env> <title> [timeout]
promote_via_mr() {
    local source_branch="$1"
    local target_env="$2"
    local title="$3"
    local timeout="${4:-$MR_PIPELINE_TIMEOUT}"

    demo_info "Starting MR-gated promotion: $source_branch → $target_env"

    # Create MR
    local mr_iid
    mr_iid=$(create_mr "$source_branch" "$target_env" "$title") || return 1

    # Wait for pipeline
    wait_for_mr_pipeline "$mr_iid" "$timeout" || return 1

    # Merge
    accept_mr "$mr_iid" || return 1

    # Wait for ArgoCD
    local app_name="${APP_REPO_NAME:-example-app}-${target_env}"
    wait_for_argocd_sync "$app_name" || return 1

    demo_verify "Promotion to $target_env complete"
    return 0
}
```

**Step 2: Make it executable and verify syntax**

Run: `chmod +x scripts/demo/lib/pipeline-wait.sh && bash -n scripts/demo/lib/pipeline-wait.sh && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add scripts/demo/lib/pipeline-wait.sh
git commit -m "feat(demo): add pipeline-wait.sh helper library for MR/Jenkins/ArgoCD operations"
```

---

## Task 4: Create UC-C1 Demo Script (Add Default Label)

**Files:**
- Create: `scripts/demo/demo-uc-c1-default-label.sh`
- Modify: `k8s-deployments/services/core/app.cue` (may need CUE changes)

**Step 1: Assess current CUE support**

First, check if `defaultLabels` in `services/core/app.cue` can be extended:

Run: `grep -A10 "defaultLabels" k8s-deployments/services/core/app.cue`

The current structure allows adding labels. We need to add `cost-center: "platform-shared"` to `defaultLabels`.

**Step 2: Create the demo script**

```bash
#!/bin/bash
# Demo: Add Default Label to All Deployments (UC-C1)
#
# This demo showcases how platform-wide changes propagate to all apps
# in all environments through the CUE layering system.
#
# Use Case UC-C1:
# "As a platform team, we need all deployments to have a cost-center label
# for chargeback reporting"
#
# What This Demonstrates:
# - Changes to services/core/ propagate to ALL apps in ALL environments
# - The MR shows both CUE change AND generated manifest changes
# - Pipeline generates manifests (not the human)
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_LABEL_KEY="cost-center"
DEMO_LABEL_VALUE="platform-shared"
DEMO_APP="example-app"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C1: Add Default Label to All Deployments"

# Load credentials
load_pipeline_credentials || exit 1

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# Step 1: Verify Prerequisites
# ---------------------------------------------------------------------------

demo_step 1 "Verify Prerequisites"

demo_action "Checking kubectl connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    demo_fail "Cannot connect to Kubernetes cluster"
    exit 1
fi
demo_verify "Connected to Kubernetes cluster"

demo_action "Checking ArgoCD applications..."
for env in "${ENVIRONMENTS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Make CUE Change (Platform Layer)
# ---------------------------------------------------------------------------

demo_step 2 "Add Default Label to Platform Layer"

demo_info "Adding '$DEMO_LABEL_KEY: $DEMO_LABEL_VALUE' to services/core/app.cue"

# Check if label already exists
if grep -q "$DEMO_LABEL_KEY" services/core/app.cue; then
    demo_warn "Label '$DEMO_LABEL_KEY' already exists in app.cue"
    demo_info "Updating value to '$DEMO_LABEL_VALUE'"
fi

# Add/update the label in defaultLabels
# Using sed to add after the existing labels
if ! grep -q "$DEMO_LABEL_KEY" services/core/app.cue; then
    # Add new label after "deployment: appName"
    sed -i "/deployment: appName/a\\		\"$DEMO_LABEL_KEY\": \"$DEMO_LABEL_VALUE\"" services/core/app.cue
    demo_verify "Added label to services/core/app.cue"
else
    # Update existing label
    sed -i "s/\"$DEMO_LABEL_KEY\": \"[^\"]*\"/\"$DEMO_LABEL_KEY\": \"$DEMO_LABEL_VALUE\"/" services/core/app.cue
    demo_verify "Updated label in services/core/app.cue"
fi

# Verify CUE is valid
demo_action "Validating CUE configuration..."
if cue vet ./...; then
    demo_verify "CUE validation passed"
else
    demo_fail "CUE validation failed"
    exit 1
fi

demo_action "Changed section in services/core/app.cue:"
grep -A5 "defaultLabels" services/core/app.cue | head -10 | sed 's/^/    /'

# ---------------------------------------------------------------------------
# Step 3: Commit and Push CUE Change
# ---------------------------------------------------------------------------

demo_step 3 "Commit and Push CUE Change"

demo_action "Creating feature branch..."
FEATURE_BRANCH="uc-c1-add-${DEMO_LABEL_KEY}-$(date +%s)"
git checkout -b "$FEATURE_BRANCH"

demo_action "Committing CUE change only (manifests generated by pipeline)..."
git add services/core/app.cue
git commit -m "feat: add $DEMO_LABEL_KEY label to all deployments (UC-C1)"

demo_action "Pushing feature branch to GitLab..."
git push origin "$FEATURE_BRANCH"
demo_verify "Feature branch pushed"

# ---------------------------------------------------------------------------
# Step 4: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 4 "MR-Gated Promotion Through Environments"

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    local jenkins_baseline=$(get_jenkins_build_number "$env")
    local argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    # Create MR
    local mr_iid
    mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C1: Add $DEMO_LABEL_KEY label to $env")

    # Wait for MR pipeline (generates manifests)
    demo_action "Waiting for pipeline to generate manifests..."
    wait_for_mr_pipeline "$mr_iid" || exit 1

    # Verify MR contains expected changes
    demo_action "Verifying MR contains CUE and manifest changes..."
    assert_mr_contains_diff "$mr_iid" "services/core/app.cue" "$DEMO_LABEL_KEY" || exit 1
    assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_LABEL_KEY" || exit 1

    # Merge MR
    accept_mr "$mr_iid" || exit 1

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state
    demo_action "Verifying label in K8s deployment..."
    assert_pod_label_equals "$env" "$DEMO_APP" "$DEMO_LABEL_KEY" "$DEMO_LABEL_VALUE" || exit 1

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 5: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 5 "Cross-Environment Verification"

demo_info "Verifying label propagated to ALL environments..."

assert_env_propagation "deployment" "$DEMO_APP" \
    "{.spec.template.metadata.labels.$DEMO_LABEL_KEY}" \
    "$DEMO_LABEL_VALUE" \
    "${ENVIRONMENTS[@]}" || exit 1

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------

demo_step 6 "Summary"

cat << EOF

  This demo validated UC-C1: Add Default Label to All Deployments

  What happened:
  1. Added '$DEMO_LABEL_KEY: $DEMO_LABEL_VALUE' to services/core/app.cue
  2. Pushed CUE change only (no manual manifest generation)
  3. For each environment (dev, stage, prod):
     - Created MR targeting environment branch
     - Pipeline generated manifests (visible in MR diff)
     - Merged MR after pipeline passed
     - ArgoCD synced the change
     - Verified label appears in K8s deployment

  Key Observations:
  - Human only changed CUE (the intent)
  - Pipeline generated YAML (the implementation)
  - MR showed both changes for review
  - Label propagated to ALL environments

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 7 "Cleanup"

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "To delete: git branch -D $FEATURE_BRANCH && git push origin --delete $FEATURE_BRANCH"

demo_complete
```

**Step 3: Make it executable and verify syntax**

Run: `chmod +x scripts/demo/demo-uc-c1-default-label.sh && bash -n scripts/demo/demo-uc-c1-default-label.sh && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add scripts/demo/demo-uc-c1-default-label.sh
git commit -m "feat(demo): add UC-C1 demo script for default label verification"
```

---

## Task 5: Update USE_CASES.md Status for UC-C1

**Files:**
- Modify: `docs/USE_CASES.md`

**Step 1: Update UC-C1 status row**

Change the UC-C1 row from:
```
| UC-C1 | Add default label | 🔲 | 🔲 | 🔲 | — | **Start here** |
```

To:
```
| UC-C1 | Add default label | ✅ | ✅ | 🔲 | `uc-c1-default-label` | Ready for pipeline verification |
```

**Step 2: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: update UC-C1 status - CUE support and demo script ready"
```

---

## Task 6: Create run-all-demos.sh Runner Script

**Files:**
- Create: `scripts/demo/run-all-demos.sh`

**Step 1: Create the runner script**

```bash
#!/bin/bash
# run-all-demos.sh - Run all use case demo scripts in sequence
#
# Usage:
#   ./run-all-demos.sh           # Run all demos
#   ./run-all-demos.sh UC-C1     # Run specific demo
#   ./run-all-demos.sh --list    # List available demos
#
# This script runs demos in the recommended order (Category C → B → A)
# and reports overall status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Demo execution order (matches design doc)
DEMO_ORDER=(
    # Category C: Platform-Wide (run first)
    "UC-C1:demo-uc-c1-default-label.sh"
    "UC-C4:demo-uc-c4-pod-annotation.sh"
    "UC-C3:demo-uc-c3-deploy-strategy.sh"
    "UC-C6:demo-uc-c6-platform-env-override.sh"
    "UC-C2:demo-uc-c2-security-context.sh"
    "UC-C5:demo-uc-c5-platform-app-override.sh"
    # Category B: App-Level
    "UC-B1:demo-uc-b1-app-env-var.sh"
    "UC-B2:demo-uc-b2-app-annotation.sh"
    "UC-B3:demo-uc-b3-app-configmap.sh"
    "UC-B4:demo-app-override.sh"
    "UC-B5:demo-uc-b5-app-probe-override.sh"
    "UC-B6:demo-uc-b6-app-env-var-override.sh"
    # Category A: Environment-Specific
    "UC-A1:demo-uc-a1-replica-count.sh"
    "UC-A2:demo-uc-a2-debug-mode.sh"
    "UC-A3:demo-env-configmap.sh"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

list_demos() {
    echo "Available demos:"
    echo ""
    for entry in "${DEMO_ORDER[@]}"; do
        local id="${entry%%:*}"
        local script="${entry#*:}"
        if [[ -f "$SCRIPT_DIR/$script" ]]; then
            echo -e "  ${GREEN}✓${NC} $id: $script"
        else
            echo -e "  ${YELLOW}○${NC} $id: $script (not implemented)"
        fi
    done
}

run_demo() {
    local id="$1"
    local script="$2"

    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} $id: $script (not implemented)"
        return 2
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Running: $id${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if "$SCRIPT_DIR/$script"; then
        echo -e "${GREEN}[PASS]${NC} $id"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $id"
        return 1
    fi
}

main() {
    local filter="${1:-}"

    if [[ "$filter" == "--list" || "$filter" == "-l" ]]; then
        list_demos
        exit 0
    fi

    if [[ "$filter" == "--help" || "$filter" == "-h" ]]; then
        echo "Usage: $0 [UC-ID | --list | --help]"
        echo ""
        echo "Options:"
        echo "  UC-ID    Run specific demo (e.g., UC-C1)"
        echo "  --list   List available demos"
        echo "  --help   Show this help"
        exit 0
    fi

    local passed=0
    local failed=0
    local skipped=0

    for entry in "${DEMO_ORDER[@]}"; do
        local id="${entry%%:*}"
        local script="${entry#*:}"

        # Filter if specific ID requested
        if [[ -n "$filter" && "$id" != "$filter" ]]; then
            continue
        fi

        run_demo "$id" "$script"
        local result=$?

        case $result in
            0) ((passed++)) ;;
            1) ((failed++)) ;;
            2) ((skipped++)) ;;
        esac

        # Stop on first failure unless running all
        if [[ $result -eq 1 && -n "$filter" ]]; then
            exit 1
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$skipped skipped${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
```

**Step 2: Make it executable and verify syntax**

Run: `chmod +x scripts/demo/run-all-demos.sh && bash -n scripts/demo/run-all-demos.sh && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add scripts/demo/run-all-demos.sh
git commit -m "feat(demo): add run-all-demos.sh runner script"
```

---

## Task 7: Final Commit - Framework Complete

**Step 1: Verify all files are committed**

Run: `git status`

Expected: Clean working tree

**Step 2: Tag the framework milestone**

```bash
git tag -a "demo-framework-v1" -m "Use case verification framework complete

Includes:
- assertions.sh: K8s verification helpers
- pipeline-wait.sh: MR/Jenkins/ArgoCD helpers
- demo-uc-c1-default-label.sh: First use case demo
- run-all-demos.sh: Demo runner
- USE_CASES.md: Status tracking table"
```

---

## Next Steps (Not Part of This Plan)

After completing this plan:

1. **Run UC-C1 demo** to verify the framework works end-to-end
2. **Create remaining Category C demos** (UC-C2 through UC-C6)
3. **Create Category B demos** (UC-B1 through UC-B6)
4. **Create Category A demos** (UC-A1, UC-A2 - UC-A3 exists)
5. **Run full verification** with `run-all-demos.sh`

Each subsequent use case follows the same pattern established in Task 4.
