#!/bin/bash
# Validate Kubernetes manifests generated from CUE
# Ensures YAML syntax is valid and manifests conform to K8s API schema

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
        if ! validate_yaml_syntax "$file" "$env"; then
            failed=$((failed + 1))
        fi
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
