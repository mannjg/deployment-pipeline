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
