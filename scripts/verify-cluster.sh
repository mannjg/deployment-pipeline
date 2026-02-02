#!/bin/bash
# Verify Cluster Health
# Checks all namespaces exist and pods are ready
#
# Usage: ./scripts/verify-cluster.sh <config-file>
#
# Checks performed:
# - All namespaces exist (infrastructure + environments)
# - Pod ready status in infrastructure namespaces
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed

set -euo pipefail

# =============================================================================
# Colors and Logging
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") <config-file>

Verify cluster health by checking namespaces and pod status.

Checks performed:
  - All namespaces exist (infrastructure + environments)
  - All pods are ready in infrastructure namespaces

Arguments:
  config-file  Path to cluster configuration file (e.g., config/clusters/alpha.env)

Exit codes:
  0  All checks passed
  1  One or more checks failed

Examples:
  $(basename "$0") config/clusters/alpha.env
  $(basename "$0") config/clusters/reference.env
EOF
    exit 1
}

# =============================================================================
# Configuration Validation
# =============================================================================

validate_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}[ERROR]${NC} Config file not found: $config_file" >&2
        exit 1
    fi

    # Source the config
    # shellcheck source=/dev/null
    source "$config_file"

    # Required variables for verification
    local required_vars=(
        "CLUSTER_NAME"
        "GITLAB_NAMESPACE"
        "JENKINS_NAMESPACE"
        "NEXUS_NAMESPACE"
        "ARGOCD_NAMESPACE"
        "DEV_NAMESPACE"
        "STAGE_NAMESPACE"
        "PROD_NAMESPACE"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}[ERROR]${NC} Config file missing required variables:" >&2
        for var in "${missing[@]}"; do
            echo -e "${RED}[ERROR]${NC}   - $var" >&2
        done
        exit 1
    fi
}

# =============================================================================
# Check Functions
# =============================================================================

# Counter for failures (global to accumulate across checks)
FAILURES=0

# Check a condition and print PASS/FAIL
# Arguments: description, command to run
# Always returns 0 to avoid triggering set -e; failures are tracked via FAILURES counter
check() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} $description"
    else
        echo -e "${RED}[FAIL]${NC} $description"
        ((FAILURES++)) || true
    fi
    return 0
}

# Check if a namespace exists
check_namespace() {
    local namespace="$1"
    check "Namespace $namespace exists" kubectl get namespace "$namespace"
    return 0
}

# Check pod ready status in a namespace
# Prints ready/total counts with PASS/FAIL/WARN status
# Always returns 0 to avoid triggering set -e; failures are tracked via FAILURES counter
check_pod_status() {
    local namespace="$1"
    local ready total ready_output

    # Get count of pods with Ready=True condition
    # Use subshell to handle grep exit code without affecting script
    ready_output=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ -n "$ready_output" ]]; then
        ready=$(echo "$ready_output" | tr ' ' '\n' | grep -c True 2>/dev/null | tr -d '\n' || echo 0)
    else
        ready=0
    fi
    # Ensure ready is a valid number
    ready=${ready:-0}
    [[ "$ready" =~ ^[0-9]+$ ]] || ready=0

    # Get total pod count (trim whitespace)
    total=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    # Ensure total is a number
    total=${total:-0}

    if [[ "$ready" -eq "$total" && "$total" -gt 0 ]]; then
        echo -e "${GREEN}[PASS]${NC} $namespace: $ready/$total pods ready"
    elif [[ "$total" -eq 0 ]]; then
        echo -e "${YELLOW}[WARN]${NC} $namespace: no pods found"
        ((FAILURES++)) || true
    else
        echo -e "${RED}[FAIL]${NC} $namespace: $ready/$total pods ready"
        ((FAILURES++)) || true
    fi
    return 0
}

# =============================================================================
# Verification Logic
# =============================================================================

verify_namespaces() {
    echo ""
    echo -e "${BLUE}=== Namespace Checks ===${NC}"
    echo ""

    # Infrastructure namespaces
    check_namespace "$GITLAB_NAMESPACE"
    check_namespace "$JENKINS_NAMESPACE"
    check_namespace "$NEXUS_NAMESPACE"
    check_namespace "$ARGOCD_NAMESPACE"

    # Environment namespaces
    check_namespace "$DEV_NAMESPACE"
    check_namespace "$STAGE_NAMESPACE"
    check_namespace "$PROD_NAMESPACE"
}

verify_pod_status() {
    echo ""
    echo -e "${BLUE}=== Pod Status ===${NC}"
    echo ""

    # Only check infrastructure namespaces (environments may be empty)
    check_pod_status "$GITLAB_NAMESPACE"
    check_pod_status "$JENKINS_NAMESPACE"
    check_pod_status "$NEXUS_NAMESPACE"
    check_pod_status "$ARGOCD_NAMESPACE"
}

print_summary() {
    echo ""
    echo -e "${BLUE}=== Summary ===${NC}"
    echo ""

    if [[ $FAILURES -eq 0 ]]; then
        echo -e "${GREEN}All checks passed${NC}"
        return 0
    else
        echo -e "${RED}$FAILURES check(s) failed${NC}"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        usage
    fi

    # Validate config file argument
    local config_file="${1:-}"
    if [[ -z "$config_file" ]]; then
        echo -e "${RED}[ERROR]${NC} Config file required" >&2
        echo ""
        usage
    fi

    # Validate and source config
    validate_config "$config_file"

    # Print header
    echo ""
    echo -e "${BLUE}Verifying cluster: $CLUSTER_NAME${NC}"
    echo -e "${BLUE}Config: $config_file${NC}"

    # Run checks
    verify_namespaces
    verify_pod_status

    # Print summary and exit with appropriate code
    print_summary
}

main "$@"
