#!/bin/bash
set -euo pipefail

# Deployment Pipeline Regression Test Suite
# Comprehensive tests for validating all pipeline components

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test libraries
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/cleanup.sh
source "$SCRIPT_DIR/lib/cleanup.sh"
# shellcheck source=lib/reporting.sh
source "$SCRIPT_DIR/lib/reporting.sh"

# Default options
TEST_SCOPE="full"
CLEANUP_MODE="always"
VERBOSE=0
FAIL_FAST=false

# Test phase flags
RUN_PREFLIGHT=true
RUN_UNIT=true
RUN_INTEGRATION=true
RUN_E2E=true

# Output options
JUNIT_OUTPUT=""
HTML_OUTPUT=""
JSON_OUTPUT=""

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deployment Pipeline Regression Test Suite

OPTIONS:
    Test Scope:
        --quick             Run only unit tests (fastest)
        --integration       Run unit and integration tests
        --full              Run all tests including E2E (default)

    Test Selection:
        --only-cue          Run only CUE validation tests
        --only-k8s          Run only Kubernetes tests
        --only-argocd       Run only ArgoCD tests
        --skip-preflight    Skip pre-flight checks
        --skip-unit         Skip unit tests
        --skip-integration  Skip integration tests
        --skip-e2e          Skip end-to-end tests

    Cleanup:
        --no-cleanup        Don't cleanup test artifacts
        --cleanup-on-success Cleanup only if all tests pass
        --cleanup-always    Always cleanup (default)

    Output:
        -v, --verbose       Verbose output
        -vv, --debug        Debug output (very verbose)
        -q, --quiet         Quiet mode (errors only)
        --junit FILE        Generate JUnit XML report
        --html FILE         Generate HTML report
        --json FILE         Generate JSON report

    Behavior:
        --fail-fast         Stop on first failure
        --continue          Continue after failures (default)

    Help:
        -h, --help          Show this help message

EXAMPLES:
    # Quick validation (CUE tests only)
    $0 --quick

    # Full test suite with HTML report
    $0 --full --html test-report.html

    # Integration tests only, keep artifacts on failure
    $0 --integration --cleanup-on-success

    # Debug mode with verbose output
    $0 -vv --no-cleanup

EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                TEST_SCOPE="quick"
                RUN_INTEGRATION=false
                RUN_E2E=false
                shift
                ;;
            --integration)
                TEST_SCOPE="integration"
                RUN_E2E=false
                shift
                ;;
            --full)
                TEST_SCOPE="full"
                shift
                ;;
            --only-cue)
                RUN_PREFLIGHT=true
                RUN_UNIT=true
                RUN_INTEGRATION=false
                RUN_E2E=false
                shift
                ;;
            --only-k8s)
                RUN_PREFLIGHT=true
                RUN_UNIT=false
                RUN_INTEGRATION=true
                RUN_E2E=false
                shift
                ;;
            --only-argocd)
                RUN_PREFLIGHT=true
                RUN_UNIT=false
                RUN_INTEGRATION=true
                RUN_E2E=false
                shift
                ;;
            --skip-preflight)
                RUN_PREFLIGHT=false
                shift
                ;;
            --skip-unit)
                RUN_UNIT=false
                shift
                ;;
            --skip-integration)
                RUN_INTEGRATION=false
                shift
                ;;
            --skip-e2e)
                RUN_E2E=false
                shift
                ;;
            --no-cleanup)
                CLEANUP_MODE="never"
                shift
                ;;
            --cleanup-on-success)
                CLEANUP_MODE="on-success"
                shift
                ;;
            --cleanup-always)
                CLEANUP_MODE="always"
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -vv|--debug)
                VERBOSE=2
                shift
                ;;
            -q|--quiet)
                VERBOSE=0
                shift
                ;;
            --junit)
                JUNIT_OUTPUT="$2"
                shift 2
                ;;
            --html)
                HTML_OUTPUT="$2"
                shift 2
                ;;
            --json)
                JSON_OUTPUT="$2"
                shift 2
                ;;
            --fail-fast)
                FAIL_FAST=true
                shift
                ;;
            --continue)
                FAIL_FAST=false
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    export VERBOSE
    export CLEANUP_MODE
    export JUNIT_OUTPUT
    export HTML_OUTPUT
    export JSON_OUTPUT
}

# Pre-flight checks
run_preflight_checks() {
    if [ "$RUN_PREFLIGHT" = false ]; then
        log_info "Skipping pre-flight checks"
        return 0
    fi

    log_info "===== Pre-Flight Checks ====="
    echo

    check_required_tools || return 1
    check_cluster_connectivity || return 1
    check_argocd_installed || return 1
    check_gitlab_accessible || true  # Non-critical

    echo
    log_pass "Pre-flight checks passed"
    echo
}

# Run unit tests
run_unit_tests() {
    if [ "$RUN_UNIT" = false ]; then
        log_info "Skipping unit tests"
        return 0
    fi

    log_info "===== PHASE: Unit Tests ====="
    echo

    # Source and run unit test scripts
    # shellcheck source=unit/test-cue-validation.sh
    source "$SCRIPT_DIR/unit/test-cue-validation.sh"
    run_cue_validation_tests

    if [ "$FAIL_FAST" = true ] && [ "$TESTS_FAILED" -gt 0 ]; then
        log_error "Tests failed in unit test phase (fail-fast enabled)"
        return 1
    fi
}

# Run integration tests
run_integration_tests() {
    if [ "$RUN_INTEGRATION" = false ]; then
        log_info "Skipping integration tests"
        return 0
    fi

    log_info "===== PHASE: Integration Tests ====="
    echo

    # Source and run integration test scripts
    # shellcheck source=integration/test-kubernetes.sh
    source "$SCRIPT_DIR/integration/test-kubernetes.sh"
    run_kubernetes_tests

    # shellcheck source=integration/test-argocd.sh
    source "$SCRIPT_DIR/integration/test-argocd.sh"
    run_argocd_tests

    if [ "$FAIL_FAST" = true ] && [ "$TESTS_FAILED" -gt 0 ]; then
        log_error "Tests failed in integration test phase (fail-fast enabled)"
        return 1
    fi
}

# Run end-to-end tests
run_e2e_tests() {
    if [ "$RUN_E2E" = false ]; then
        log_info "Skipping end-to-end tests"
        return 0
    fi

    log_info "===== PHASE: End-to-End Tests ====="
    echo
    log_warn "E2E tests not yet implemented"
    echo
}

# Main test execution
main() {
    # Parse arguments
    parse_args "$@"

    # Print banner
    echo
    echo "========================================"
    echo "  DEPLOYMENT PIPELINE REGRESSION TESTS"
    echo "========================================"
    echo
    echo "Test Scope:    $TEST_SCOPE"
    echo "Cleanup Mode:  $CLEANUP_MODE"
    echo "Verbose Level: $VERBOSE"
    echo
    echo "========================================"
    echo

    # Initialize test metadata
    export TEST_START_TIME=$(date +%s)
    export TEST_TIMESTAMP=$(generate_test_timestamp)
    export TEST_NAMESPACE=$(generate_test_namespace)

    # Initialize results directory
    init_results_dir

    # Setup cleanup trap
    setup_cleanup_trap

    # Change to project root
    cd "$PROJECT_ROOT" || exit 1

    # Run test phases
    local phase_failed=false

    run_preflight_checks || phase_failed=true
    [ "$phase_failed" = false ] && run_unit_tests || phase_failed=true
    [ "$phase_failed" = false ] && run_integration_tests || phase_failed=true
    [ "$phase_failed" = false ] && run_e2e_tests || phase_failed=true

    # Calculate duration
    local end_time duration duration_human
    end_time=$(date +%s)
    duration=$((end_time - TEST_START_TIME))
    duration_human=$(seconds_to_human $duration)

    # Generate reports
    generate_reports "$duration_human"

    # Print summary
    local test_passed=false
    if print_test_summary "$duration_human"; then
        test_passed=true
    fi

    # Remove cleanup trap
    remove_cleanup_trap

    # Conditional cleanup
    conditional_cleanup "$test_passed"

    # Exit with appropriate code
    if [ "$test_passed" = true ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
