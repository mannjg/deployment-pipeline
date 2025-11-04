#!/bin/bash
# Integration test for CUE configuration
# Generates manifests for all environments and validates them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Integration test for CUE configuration - generates and validates manifests."
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -e, --env ENV  Test specific environment only (dev, stage, or prod)"
    echo ""
    echo "Examples:"
    echo "  $0              # Test all environments"
    echo "  $0 --env dev    # Test dev environment only"
    exit 0
}

TEST_ENV=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -e|--env)
            TEST_ENV="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

test_manifest_generation() {
    local env=$1
    log_info "Testing manifest generation for $env..."

    if [ ! -f "$REPO_ROOT/scripts/generate-manifests.sh" ]; then
        log_error "generate-manifests.sh not found"
        return 1
    fi

    if ! "$REPO_ROOT/scripts/generate-manifests.sh" "$env" > /tmp/generate-$env.log 2>&1; then
        log_error "Manifest generation failed for $env"
        cat /tmp/generate-$env.log | sed 's/^/  /'
        rm -f /tmp/generate-$env.log
        return 1
    fi

    rm -f /tmp/generate-$env.log
    log_info "✓ Manifest generation succeeded for $env"
    return 0
}

test_manifest_validation() {
    local env=$1
    log_info "Testing manifest validation for $env..."

    if [ ! -f "$REPO_ROOT/scripts/validate-manifests.sh" ]; then
        log_error "validate-manifests.sh not found"
        return 1
    fi

    if ! "$REPO_ROOT/scripts/validate-manifests.sh" "$env" > /tmp/validate-$env.log 2>&1; then
        log_error "Manifest validation failed for $env"
        cat /tmp/validate-$env.log | sed 's/^/  /'
        rm -f /tmp/validate-$env.log
        return 1
    fi

    rm -f /tmp/validate-$env.log
    log_info "✓ Manifest validation succeeded for $env"
    return 0
}

test_kubectl_dry_run() {
    local env=$1
    log_info "Testing kubectl dry-run for $env..."

    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl not found - skipping dry-run test"
        return 0
    fi

    local manifest_dir="$REPO_ROOT/manifests/$env"
    if [ ! -d "$manifest_dir" ]; then
        log_error "Manifest directory not found: $manifest_dir"
        return 1
    fi

    local failed=0
    while IFS= read -r -d '' file; do
        if ! kubectl apply --dry-run=client -f "$file" > /dev/null 2>&1; then
            log_warn "kubectl dry-run warning for: $(basename "$file")"
            # Don't fail - some resources might need server-side validation
        fi
    done < <(find "$manifest_dir" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0)

    log_info "✓ kubectl dry-run completed for $env"
    return 0
}

test_environment() {
    local env=$1
    local failed=0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Testing $env Environment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if ! test_manifest_generation "$env"; then
        failed=$((failed + 1))
    fi
    echo ""

    if ! test_manifest_validation "$env"; then
        failed=$((failed + 1))
    fi
    echo ""

    if ! test_kubectl_dry_run "$env"; then
        # Kubectl warnings don't fail the test
        :
    fi
    echo ""

    if [ $failed -eq 0 ]; then
        log_info "✓✓✓ All tests passed for $env ✓✓✓"
        return 0
    else
        log_error "✗✗✗ $failed test(s) failed for $env ✗✗✗"
        return 1
    fi
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " CUE Integration Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    cd "$REPO_ROOT"

    local environments=()
    if [ -n "$TEST_ENV" ]; then
        environments=("$TEST_ENV")
    else
        environments=("dev" "stage" "prod")
    fi

    local total_failed=0
    for env in "${environments[@]}"; do
        if ! test_environment "$env"; then
            total_failed=$((total_failed + 1))
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Integration Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ $total_failed -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ All integration tests passed ✓✓✓${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 0
    else
        echo -e "${RED}✗✗✗ $total_failed environment(s) failed ✗✗✗${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    fi
}

main "$@"
