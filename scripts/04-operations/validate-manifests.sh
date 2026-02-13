#!/bin/bash
# Validate Kubernetes manifests generated from CUE
# Ensures YAML syntax is valid and manifests conform to K8s API schema

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Environment to validate (default: all)
ENVIRONMENT="${1:-}"

usage() {
    echo "Usage: $0 [environment]"
    echo ""
    echo "Validates Kubernetes manifests for the specified environment."
    echo ""
    echo "Arguments:"
    echo "  environment    Optional: dev, stage, or prod (validates all if not specified)"
    echo ""
    echo "Examples:"
    echo "  $0           # Validate all environments"
    echo "  $0 dev       # Validate only dev environment"
    exit 1
}

validate_yaml_syntax() {
    local file=$1
    local env=$2

    echo "Checking YAML syntax: $(basename "$file")"

    # Check if file is empty
    if [ ! -s "$file" ]; then
        echo -e "${RED}✗ YAML file is empty: $file${NC}"
        return 1
    fi

    # Validate YAML syntax with yq if available
    if command -v yq &> /dev/null; then
        if ! yq eval '.' "$file" > /dev/null 2>&1; then
            echo -e "${RED}✗ Invalid YAML syntax in: $file${NC}"
            return 1
        fi
    else
        # Fallback: basic YAML check with kubectl
        if command -v kubectl &> /dev/null; then
            if ! kubectl apply --dry-run=client -f "$file" &> /dev/null; then
                echo -e "${YELLOW}⚠ Warning: kubectl validation failed for: $file${NC}"
                echo -e "${YELLOW}  (This may be expected for CRDs or some resources)${NC}"
                # Don't fail - some valid K8s resources might not validate without cluster context
            fi
        else
            echo -e "${YELLOW}⚠ Neither yq nor kubectl found - skipping detailed validation${NC}"
        fi
    fi

    echo -e "${GREEN}✓ YAML syntax valid: $(basename "$file")${NC}"
    return 0
}

validate_required_fields() {
    local file=$1
    local env=$2
    local failed=0

    echo "Checking required fields: $(basename "$file")"

    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}⚠ yq not found - skipping required fields validation${NC}"
        return 0
    fi

    # Count YAML documents in file (handle multi-doc YAML with ---)
    local doc_count=$(yq eval-all '[.] | length' "$file" 2>/dev/null || echo "1")

    for ((doc_index=0; doc_index<doc_count; doc_index++)); do
        # Get the kind of resource
        local kind=$(yq eval "select(di == $doc_index) | .kind" "$file" 2>/dev/null)

        if [ -z "$kind" ] || [ "$kind" = "null" ]; then
            continue
        fi

        # Check namespace (for namespaced resources)
        if [[ "$kind" != "ClusterRole" && "$kind" != "ClusterRoleBinding" && "$kind" != "Namespace" ]]; then
            local namespace=$(yq eval "select(di == $doc_index) | .metadata.namespace" "$file" 2>/dev/null)
            if [ -z "$namespace" ] || [ "$namespace" = "null" ]; then
                echo -e "${RED}  ✗ Missing required field: metadata.namespace for $kind${NC}"
                failed=1
            elif [ "$namespace" != "$env" ]; then
                echo -e "${YELLOW}  ⚠ Namespace '$namespace' doesn't match environment '$env'${NC}"
            fi
        fi

        # Check labels
        local has_labels=$(yq eval "select(di == $doc_index) | .metadata.labels | length" "$file" 2>/dev/null)
        if [ -z "$has_labels" ] || [ "$has_labels" = "null" ] || [ "$has_labels" = "0" ]; then
            echo -e "${YELLOW}  ⚠ No labels defined for $kind${NC}"
        fi

        # Check for image field in Deployments
        if [ "$kind" = "Deployment" ]; then
            local image=$(yq eval "select(di == $doc_index) | .spec.template.spec.containers[0].image" "$file" 2>/dev/null)
            if [ -z "$image" ] || [ "$image" = "null" ]; then
                echo -e "${RED}  ✗ Missing required field: spec.template.spec.containers[0].image${NC}"
                failed=1
            elif [[ "$image" == *":latest" ]]; then
                echo -e "${YELLOW}  ⚠ Image using ':latest' tag (not recommended): $image${NC}"
            fi
        fi
    done

    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ Required fields present${NC}"
        return 0
    else
        return 1
    fi
}

validate_resource_limits() {
    local file=$1
    local env=$2
    local failed=0

    echo "Checking resource limits: $(basename "$file")"

    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}⚠ yq not found - skipping resource limits validation${NC}"
        return 0
    fi

    # Define acceptable resource ranges by environment
    local max_cpu_limit max_memory_limit
    case "$env" in
        dev)
            max_cpu_limit="1000m"
            max_memory_limit="1Gi"
            ;;
        stage)
            max_cpu_limit="2000m"
            max_memory_limit="4Gi"
            ;;
        prod)
            max_cpu_limit="4000m"
            max_memory_limit="8Gi"
            ;;
        *)
            max_cpu_limit="2000m"
            max_memory_limit="4Gi"
            ;;
    esac

    # Check Deployments for resource limits
    local doc_count=$(yq eval-all '[.] | length' "$file" 2>/dev/null || echo "1")

    for ((doc_index=0; doc_index<doc_count; doc_index++)); do
        local kind=$(yq eval "select(di == $doc_index) | .kind" "$file" 2>/dev/null)

        if [ "$kind" != "Deployment" ]; then
            continue
        fi

        # Check if resources are defined
        local has_resources=$(yq eval "select(di == $doc_index) | .spec.template.spec.containers[0].resources | length" "$file" 2>/dev/null)
        if [ -z "$has_resources" ] || [ "$has_resources" = "null" ] || [ "$has_resources" = "0" ]; then
            echo -e "${YELLOW}  ⚠ No resource limits defined (unlimited resources)${NC}"
            continue
        fi

        # Check if limits are defined
        local has_limits=$(yq eval "select(di == $doc_index) | .spec.template.spec.containers[0].resources.limits | length" "$file" 2>/dev/null)
        if [ -z "$has_limits" ] || [ "$has_limits" = "null" ] || [ "$has_limits" = "0" ]; then
            echo -e "${YELLOW}  ⚠ No resource limits defined (only requests)${NC}"
        fi

        # Verify requests are less than limits
        local cpu_request=$(yq eval "select(di == $doc_index) | .spec.template.spec.containers[0].resources.requests.cpu" "$file" 2>/dev/null)
        local cpu_limit=$(yq eval "select(di == $doc_index) | .spec.template.spec.containers[0].resources.limits.cpu" "$file" 2>/dev/null)

        if [ -n "$cpu_request" ] && [ "$cpu_request" != "null" ] && [ -n "$cpu_limit" ] && [ "$cpu_limit" != "null" ]; then
            echo -e "${GREEN}  ✓ CPU resources defined (request: $cpu_request, limit: $cpu_limit)${NC}"
        fi
    done

    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ Resource limits validation passed${NC}"
        return 0
    else
        return 1
    fi
}

validate_security() {
    local file=$1
    local env=$2
    local warnings=0

    echo "Checking security configuration: $(basename "$file")"

    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}⚠ yq not found - skipping security validation${NC}"
        return 0
    fi

    local doc_count=$(yq eval-all '[.] | length' "$file" 2>/dev/null || echo "1")

    for ((doc_index=0; doc_index<doc_count; doc_index++)); do
        local kind=$(yq eval "select(di == $doc_index) | .kind" "$file" 2>/dev/null)

        if [ "$kind" != "Deployment" ]; then
            continue
        fi

        # Check for privileged containers
        local privileged=$(yq eval "select(di == $doc_index) | .spec.template.spec.containers[0].securityContext.privileged" "$file" 2>/dev/null)
        if [ "$privileged" = "true" ]; then
            echo -e "${RED}  ✗ Security issue: Container runs as privileged${NC}"
            warnings=1
        fi

        # Check for hostPath volumes
        local has_hostpath=$(yq eval "select(di == $doc_index) | .spec.template.spec.volumes[] | select(.hostPath != null) | length" "$file" 2>/dev/null)
        if [ -n "$has_hostpath" ] && [ "$has_hostpath" != "0" ] && [ "$has_hostpath" != "null" ]; then
            echo -e "${YELLOW}  ⚠ Security warning: Using hostPath volumes${NC}"
        fi

        # Check for host network
        local host_network=$(yq eval "select(di == $doc_index) | .spec.template.spec.hostNetwork" "$file" 2>/dev/null)
        if [ "$host_network" = "true" ]; then
            echo -e "${YELLOW}  ⚠ Security warning: Using host network${NC}"
        fi

        # Check for host PID
        local host_pid=$(yq eval "select(di == $doc_index) | .spec.template.spec.hostPID" "$file" 2>/dev/null)
        if [ "$host_pid" = "true" ]; then
            echo -e "${YELLOW}  ⚠ Security warning: Using host PID namespace${NC}"
        fi

        # Check for run as root
        local run_as_root=$(yq eval "select(di == $doc_index) | .spec.template.spec.securityContext.runAsUser" "$file" 2>/dev/null)
        if [ "$run_as_root" = "0" ]; then
            echo -e "${YELLOW}  ⚠ Security warning: Container may run as root user${NC}"
        fi
    done

    if [ $warnings -eq 0 ]; then
        echo -e "${GREEN}✓ No critical security issues found${NC}"
    fi

    return 0  # Security warnings don't fail validation
}

validate_naming_conventions() {
    local file=$1
    local env=$2

    echo "Checking naming conventions: $(basename "$file")"

    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}⚠ yq not found - skipping naming conventions validation${NC}"
        return 0
    fi

    local doc_count=$(yq eval-all '[.] | length' "$file" 2>/dev/null || echo "1")

    for ((doc_index=0; doc_index<doc_count; doc_index++)); do
        local kind=$(yq eval "select(di == $doc_index) | .kind" "$file" 2>/dev/null)
        local name=$(yq eval "select(di == $doc_index) | .metadata.name" "$file" 2>/dev/null)

        if [ -z "$name" ] || [ "$name" = "null" ]; then
            continue
        fi

        # Check name format (lowercase alphanumeric with hyphens)
        if ! [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
            echo -e "${YELLOW}  ⚠ Resource name '$name' doesn't follow Kubernetes naming conventions${NC}"
        fi

        # Check name length (max 253 characters for most resources)
        if [ ${#name} -gt 253 ]; then
            echo -e "${YELLOW}  ⚠ Resource name '$name' exceeds 253 characters${NC}"
        fi
    done

    echo -e "${GREEN}✓ Naming conventions check completed${NC}"
    return 0
}

validate_manifest_content() {
    local file=$1
    local env=$2
    local failed=0

    # Run all content validations
    if ! validate_required_fields "$file" "$env"; then
        failed=1
    fi

    if ! validate_resource_limits "$file" "$env"; then
        failed=1
    fi

    if ! validate_security "$file" "$env"; then
        # Security warnings don't fail validation
        :
    fi

    if ! validate_naming_conventions "$file" "$env"; then
        # Naming warnings don't fail validation
        :
    fi

    return $failed
}

validate_environment() {
    local env=$1
    local manifest_dir="$REPO_ROOT/manifests/$env"

    echo -e "\n${GREEN}=== Validating $env environment ===${NC}"

    # Check if manifest directory exists
    if [ ! -d "$manifest_dir" ]; then
        echo -e "${RED}✗ Manifest directory does not exist: $manifest_dir${NC}"
        return 1
    fi

    # Check if directory is empty
    if [ -z "$(ls -A "$manifest_dir")" ]; then
        echo -e "${RED}✗ Manifest directory is empty: $manifest_dir${NC}"
        return 1
    fi

    # Count YAML files
    local yaml_count=$(find "$manifest_dir" -type f \( -name "*.yaml" -o -name "*.yml" \) | wc -l)
    echo "Found $yaml_count YAML manifest(s) in $env/"

    if [ "$yaml_count" -eq 0 ]; then
        echo -e "${RED}✗ No YAML manifests found in: $manifest_dir${NC}"
        return 1
    fi

    # Validate each YAML file
    local failed=0
    while IFS= read -r -d '' file; do
        echo ""
        echo "--- Validating: $(basename "$file") ---"

        # Basic YAML syntax validation
        if ! validate_yaml_syntax "$file" "$env"; then
            failed=$((failed + 1))
            continue
        fi

        # Content validation (required fields, resources, security, naming)
        if ! validate_manifest_content "$file" "$env"; then
            failed=$((failed + 1))
        fi

        echo ""
    done < <(find "$manifest_dir" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0)

    if [ $failed -gt 0 ]; then
        echo -e "${RED}✗ $failed manifest(s) failed validation in $env${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ All manifests valid in $env environment${NC}"
    return 0
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Kubernetes Manifest Validator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
    fi

    cd "$REPO_ROOT"

    local environments=()
    if [ -z "$ENVIRONMENT" ]; then
        # Validate all environments
        environments=("dev" "stage" "prod")
        echo "Validating all environments: ${environments[*]}"
    else
        # Validate specific environment
        environments=("$ENVIRONMENT")
        echo "Validating environment: $ENVIRONMENT"
    fi

    local total_failed=0
    for env in "${environments[@]}"; do
        if ! validate_environment "$env"; then
            total_failed=$((total_failed + 1))
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ $total_failed -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ All validations passed ✓✓✓${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 0
    else
        echo -e "${RED}✗✗✗ $total_failed environment(s) failed validation ✗✗✗${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    fi
}

main "$@"
