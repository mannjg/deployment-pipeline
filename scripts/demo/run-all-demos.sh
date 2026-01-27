#!/bin/bash
# run-all-demos.sh - Run all verification tests with reset between each
#
# This script validates the entire CI/CD pipeline as a reference implementation.
# It runs each test in isolation with a clean reset before each.
#
# Usage:
#   ./run-all-demos.sh              # Run all verifications
#   ./run-all-demos.sh --list       # List available tests
#   ./run-all-demos.sh --no-reset   # Skip reset between tests (faster, less isolated)
#   ./run-all-demos.sh UC-C1        # Run specific test
#   ./run-all-demos.sh validate     # Run validate-pipeline only
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Reset script
RESET_SCRIPT="$REPO_ROOT/scripts/03-pipelines/reset-demo-state.sh"

# Verification order: validate-pipeline first, then demos by category
# Only list tests that actually exist
DEMO_ORDER=(
    # Core: App code lifecycle (SNAPSHOT → RC → Release)
    "validate-pipeline:../test/validate-pipeline.sh:App code lifecycle across dev/stage/prod"
    # Category A: Environment-Specific
    "UC-A1:demo-uc-a1-replicas.sh:Adjust replica count (isolated)"
    "UC-A2:demo-uc-a2-debug-mode.sh:Enable debug mode (isolated)"
    "UC-A3:demo-uc-a3-env-configmap.sh:Environment-specific ConfigMap (isolated)"
    # Category B: App-Level Cross-Environment
    "UC-B1:demo-uc-b1-app-env-var.sh:App env var propagates to all environments"
    "UC-B4:demo-uc-b4-app-override.sh:App ConfigMap with environment override"
    # Category C: Platform-Wide
    "UC-C1:demo-uc-c1-default-label.sh:Platform-wide label propagation"
    "UC-C2:demo-uc-c2-security-context.sh:Platform-wide pod security context"
    "UC-C3:demo-uc-c3-deployment-strategy.sh:Platform-wide zero-downtime deployment strategy"
    "UC-C4:demo-uc-c4-prometheus-annotations.sh:Platform-wide pod annotations"
    "UC-C6:demo-uc-c6-platform-env-override.sh:Platform default with env override"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Results tracking
declare -A RESULTS
declare -A DURATIONS
TOTAL_START_TIME=0
SKIP_RESET=false

format_duration() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    if [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${remaining_seconds}s"
    else
        echo "${seconds}s"
    fi
}

list_demos() {
    echo ""
    echo "Available verifications:"
    echo ""
    printf "  %-20s %-45s %s\n" "ID" "Script" "Description"
    printf "  %-20s %-45s %s\n" "--" "------" "-----------"
    for entry in "${DEMO_ORDER[@]}"; do
        local id="${entry%%:*}"
        local rest="${entry#*:}"
        local script="${rest%%:*}"
        local desc="${rest#*:}"
        local full_path="$SCRIPT_DIR/$script"
        local status="✓"
        [[ ! -x "$full_path" ]] && status="○"
        printf "  %s %-18s %-45s %s\n" "$status" "$id" "$script" "$desc"
    done
    echo ""
    echo "Legend: ✓ = exists, ○ = not implemented"
    echo ""
}

run_reset() {
    local test_id="$1"

    if [[ "$SKIP_RESET" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  RESET: Preparing clean state for $test_id${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ ! -x "$RESET_SCRIPT" ]]; then
        echo -e "${RED}[ERROR]${NC} Reset script not found: $RESET_SCRIPT"
        return 1
    fi

    if ! "$RESET_SCRIPT"; then
        echo -e "${RED}[ERROR]${NC} Reset failed"
        return 1
    fi

    echo -e "${GREEN}[OK]${NC} Reset complete"
    return 0
}

run_demo() {
    local id="$1"
    local script="$2"
    local desc="$3"
    local full_path="$SCRIPT_DIR/$script"

    if [[ ! -x "$full_path" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} $id: not implemented"
        RESULTS[$id]="SKIP"
        DURATIONS[$id]=0
        return 2
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  TEST: $id${NC}"
    echo -e "${BLUE}  $desc${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local start_time=$(date +%s)

    if "$full_path"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        RESULTS[$id]="PASS"
        DURATIONS[$id]=$duration
        echo -e "${GREEN}[PASS]${NC} $id completed in $(format_duration $duration)"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        RESULTS[$id]="FAIL"
        DURATIONS[$id]=$duration
        echo -e "${RED}[FAIL]${NC} $id failed after $(format_duration $duration)"
        return 1
    fi
}

print_summary() {
    local total_end_time=$(date +%s)
    local total_duration=$((total_end_time - TOTAL_START_TIME))

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  VERIFICATION SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local passed=0
    local failed=0
    local skipped=0

    printf "  %-25s %-8s %s\n" "Test" "Result" "Duration"
    printf "  %-25s %-8s %s\n" "----" "------" "--------"

    for entry in "${DEMO_ORDER[@]}"; do
        local id="${entry%%:*}"
        if [[ -v "RESULTS[$id]" ]]; then
            local result="${RESULTS[$id]}"
            local duration="${DURATIONS[$id]}"
            local duration_str=$(format_duration $duration)

            case "$result" in
                PASS)
                    printf "  ${GREEN}%-25s %-8s %s${NC}\n" "$id" "PASS" "$duration_str"
                    ((++passed))
                    ;;
                FAIL)
                    printf "  ${RED}%-25s %-8s %s${NC}\n" "$id" "FAIL" "$duration_str"
                    ((++failed))
                    ;;
                SKIP)
                    printf "  ${YELLOW}%-25s %-8s %s${NC}\n" "$id" "SKIP" "-"
                    ((++skipped))
                    ;;
            esac
        fi
    done

    echo ""
    echo "  Total: $passed passed, $failed failed, $skipped skipped"
    echo "  Total time: $(format_duration $total_duration)"
    echo ""

    if [[ $failed -eq 0 && $skipped -eq 0 ]]; then
        echo -e "  ${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}  ALL VERIFICATIONS PASSED${NC}"
        echo -e "  ${GREEN}═══════════════════════════════════════════════════════════${NC}"
        return 0
    elif [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "  ${RED}  VERIFICATION FAILED: $failed test(s) failed${NC}"
        echo -e "  ${RED}═══════════════════════════════════════════════════════════${NC}"
        return 1
    else
        echo -e "  ${YELLOW}═══════════════════════════════════════════════════════════${NC}"
        echo -e "  ${YELLOW}  VERIFICATION INCOMPLETE: $skipped test(s) skipped${NC}"
        echo -e "  ${YELLOW}═══════════════════════════════════════════════════════════${NC}"
        return 1
    fi
}

main() {
    local filter=""
    local tests_to_run=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list|-l)
                list_demos
                exit 0
                ;;
            --no-reset)
                SKIP_RESET=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS] [TEST_ID...]"
                echo ""
                echo "Run verification tests for the CI/CD pipeline reference implementation."
                echo ""
                echo "Options:"
                echo "  --list, -l     List available tests"
                echo "  --no-reset     Skip reset between tests (faster, less isolated)"
                echo "  --help, -h     Show this help"
                echo ""
                echo "Examples:"
                echo "  $0                    # Run all verifications with reset between each"
                echo "  $0 --no-reset         # Run all without reset (faster)"
                echo "  $0 UC-C1              # Run specific test"
                echo "  $0 validate           # Run validate-pipeline only"
                exit 0
                ;;
            -*)
                echo -e "${RED}[ERROR]${NC} Unknown option: $1"
                exit 1
                ;;
            *)
                filter="$1"
                shift
                ;;
        esac
    done

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  PIPELINE VERIFICATION SUITE${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Reset between tests: $([[ "$SKIP_RESET" == "true" ]] && echo "no" || echo "yes")"
    echo ""

    TOTAL_START_TIME=$(date +%s)

    for entry in "${DEMO_ORDER[@]}"; do
        local id="${entry%%:*}"
        local rest="${entry#*:}"
        local script="${rest%%:*}"
        local desc="${rest#*:}"

        # Filter if specific ID requested (partial match)
        if [[ -n "$filter" && "$id" != *"$filter"* && "$filter" != *"$id"* ]]; then
            continue
        fi

        # Run reset before each test
        if ! run_reset "$id"; then
            RESULTS[$id]="SKIP"
            DURATIONS[$id]=0
            continue
        fi

        # Run the test
        run_demo "$id" "$script" "$desc"
    done

    # Print summary
    print_summary
    exit $?
}

main "$@"
