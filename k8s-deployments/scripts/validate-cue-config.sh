#!/bin/bash
# Validate CUE configuration files
# Ensures CUE syntax is valid, schemas are satisfied, and no circular dependencies exist

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Validates CUE configuration files in the repository."
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -v, --verbose  Enable verbose output"
    echo ""
    echo "Examples:"
    echo "  $0              # Validate all CUE files"
    echo "  $0 --verbose    # Validate with detailed output"
    exit 0
}

VERBOSE=false
if [[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

validate_cue_installed() {
    if ! command -v cue &> /dev/null; then
        log_error "CUE command not found. Please install CUE: https://cuelang.org/docs/install/"
        exit 1
    fi

    local cue_version=$(cue version 2>&1 | head -n1 || echo "unknown")
    log_verbose "CUE version: $cue_version"
}

validate_module_structure() {
    log_info "Checking CUE module structure..."

    if [ ! -f "$REPO_ROOT/cue.mod/module.cue" ]; then
        log_error "Missing cue.mod/module.cue - not a valid CUE module"
        return 1
    fi

    local module_name=$(grep '^module:' "$REPO_ROOT/cue.mod/module.cue" | awk '{print $2}' | tr -d '"')
    if [ -z "$module_name" ]; then
        log_error "Module name not defined in cue.mod/module.cue"
        return 1
    fi

    log_verbose "Module name: $module_name"
    log_info "✓ CUE module structure valid"
    return 0
}

validate_cue_syntax() {
    log_info "Validating CUE syntax across all files..."

    local failed=0
    local checked=0

    # Find all .cue files
    while IFS= read -r -d '' file; do
        local rel_path="${file#$REPO_ROOT/}"
        log_verbose "Checking: $rel_path"

        checked=$((checked + 1))

        # For schema/template files, allow incomplete instances
        # For application and environment files, check more strictly
        local check_opts="-c=false"  # Allow incomplete by default

        if [[ "$rel_path" == envs/*.cue ]]; then
            # Environment files should be complete
            check_opts=""
        fi

        # Run cue vet on individual file with appropriate options
        if ! cue vet $check_opts "$file" &> /dev/null; then
            log_error "Syntax error in: $rel_path"
            # Show detailed error
            cue vet $check_opts "$file" 2>&1 | sed 's/^/  /'
            failed=$((failed + 1))
        fi
    done < <(find "$REPO_ROOT" -name "*.cue" -type f -not -path "*/cue.mod/pkg/*" -print0)

    if [ $failed -eq 0 ]; then
        log_info "✓ All $checked CUE files have valid syntax"
        return 0
    else
        log_error "✗ $failed of $checked CUE files have syntax errors"
        return 1
    fi
}

validate_schema_compliance() {
    log_info "Validating schema compliance..."

    # Run cue vet on the entire module (allow incomplete for schemas/templates)
    cd "$REPO_ROOT"

    if ! cue vet -c=false ./... 2>&1 | tee /tmp/cue-vet-output.txt; then
        log_error "Schema validation failed:"
        cat /tmp/cue-vet-output.txt | sed 's/^/  /'
        rm -f /tmp/cue-vet-output.txt
        return 1
    fi

    rm -f /tmp/cue-vet-output.txt
    log_info "✓ Schema compliance validated"
    return 0
}

validate_environment_configs() {
    log_info "Validating environment configurations..."

    local failed=0
    local environments=("dev" "stage" "prod")

    for env in "${environments[@]}"; do
        log_verbose "Checking $env environment..."

        if [ ! -f "$REPO_ROOT/envs/${env}.cue" ]; then
            log_warn "Environment file not found: envs/${env}.cue"
            continue
        fi

        # Try to export the environment configuration
        if ! cue export "./envs/${env}.cue" --path "$env" > /dev/null 2>&1; then
            log_error "Failed to export $env environment configuration"
            cue export "./envs/${env}.cue" --path "$env" 2>&1 | sed 's/^/  /'
            failed=$((failed + 1))
        else
            log_verbose "✓ $env environment config is valid"
        fi
    done

    if [ $failed -eq 0 ]; then
        log_info "✓ All environment configurations are valid"
        return 0
    else
        log_error "✗ $failed environment(s) failed validation"
        return 1
    fi
}

validate_application_configs() {
    log_info "Validating application configurations..."

    local failed=0
    local checked=0

    # Find all application CUE files
    if [ ! -d "$REPO_ROOT/services/apps" ]; then
        log_warn "No services/apps directory found - skipping application validation"
        return 0
    fi

    while IFS= read -r -d '' file; do
        local app_name=$(basename "$file" .cue)
        checked=$((checked + 1))

        log_verbose "Checking application: $app_name"

        # Validate the application syntax (allow incomplete - apps are partial until merged with envs)
        if ! cue vet -c=false "$file" > /dev/null 2>&1; then
            log_error "Failed to validate application: $app_name"
            cue vet -c=false "$file" 2>&1 | sed 's/^/  /'
            failed=$((failed + 1))
        fi
    done < <(find "$REPO_ROOT/services/apps" -name "*.cue" -type f -print0)

    if [ $checked -eq 0 ]; then
        log_warn "No application configurations found"
        return 0
    fi

    if [ $failed -eq 0 ]; then
        log_info "✓ All $checked application(s) validated successfully"
        return 0
    else
        log_error "✗ $failed of $checked application(s) failed validation"
        return 1
    fi
}

check_required_fields() {
    log_info "Checking for required fields in configurations..."

    local failed=0

    # Check that environments define required fields
    for env in dev stage prod; do
        if [ ! -f "$REPO_ROOT/envs/${env}.cue" ]; then
            continue
        fi

        log_verbose "Checking required fields in $env environment..."

        # Check for example-app configuration (if it exists)
        if grep -q "exampleApp:" "$REPO_ROOT/envs/${env}.cue"; then
            # Verify image field is present
            if ! cue export "./envs/${env}.cue" -e "${env}.exampleApp.appConfig.deployment.image" > /dev/null 2>&1; then
                log_error "Missing required field: image in $env.exampleApp"
                failed=$((failed + 1))
            fi

            # Verify replicas field is present
            if ! cue export "./envs/${env}.cue" -e "${env}.exampleApp.appConfig.deployment.replicas" > /dev/null 2>&1; then
                log_error "Missing required field: replicas in $env.exampleApp"
                failed=$((failed + 1))
            fi
        fi
    done

    if [ $failed -eq 0 ]; then
        log_info "✓ All required fields present"
        return 0
    else
        log_error "✗ $failed required field(s) missing"
        return 1
    fi
}

run_integration_checks() {
    log_info "Running integration checks..."

    # Check that apps are properly imported in environments
    local failed=0

    for env in dev stage prod; do
        if [ ! -f "$REPO_ROOT/envs/${env}.cue" ]; then
            continue
        fi

        log_verbose "Checking imports in $env environment..."

        # Verify apps package is imported
        if ! grep -q 'import.*"deployments.local/k8s-deployments/services/apps"' "$REPO_ROOT/envs/${env}.cue"; then
            log_warn "$env environment doesn't import services/apps package"
        fi
    done

    log_info "✓ Integration checks completed"
    return 0
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " CUE Configuration Validator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    cd "$REPO_ROOT"

    local total_failed=0

    # Run all validation steps
    validate_cue_installed

    if ! validate_module_structure; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    if ! validate_cue_syntax; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    if ! validate_schema_compliance; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    if ! validate_environment_configs; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    if ! validate_application_configs; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    if ! check_required_fields; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    if ! run_integration_checks; then
        total_failed=$((total_failed + 1))
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ $total_failed -eq 0 ]; then
        echo -e "${GREEN}✓✓✓ All CUE validations passed ✓✓✓${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 0
    else
        echo -e "${RED}✗✗✗ $total_failed validation step(s) failed ✗✗✗${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    fi
}

main "$@"
