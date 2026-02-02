#!/bin/bash
# run-all-demos.sh - Run all verification tests with reset between each
#
# This script validates the entire CI/CD pipeline as a reference implementation.
# It runs each test in isolation with a clean reset before each.
#
# Usage:
#   ./run-all-demos.sh <config-file>              # Run all verifications
#   ./run-all-demos.sh <config-file> --list       # List available tests
#   ./run-all-demos.sh <config-file> --no-reset   # Skip reset between tests (faster, less isolated)
#   ./run-all-demos.sh <config-file> UC-C1        # Run specific test
#
# Arguments:
#   config-file    Path to cluster configuration file (e.g., config/clusters/alpha.env)
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# Configuration File (Required)
# =============================================================================

CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" ]]; then
    echo "Error: Config file required as first argument"
    echo ""
    echo "Usage: $0 <config-file> [options]"
    echo "Example: $0 config/clusters/alpha.env"
    echo "         $0 config/clusters/alpha.env --list"
    echo "         $0 config/clusters/alpha.env UC-C1"
    exit 1
fi

# Resolve relative paths
if [[ ! "$CONFIG_FILE" = /* ]]; then
    CONFIG_FILE="$REPO_ROOT/$CONFIG_FILE"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

shift  # Remove config file from args

# Export for child processes (demo scripts)
export CLUSTER_CONFIG="$CONFIG_FILE"
source "$CONFIG_FILE"

# Reset script
RESET_SCRIPT="$REPO_ROOT/scripts/03-pipelines/reset-demo-state.sh"

# Verification order: UC-E1 (app lifecycle) first, then demos by category
# Format: "ID:script:description:branches"
DEMO_ORDER=(
    # Category E: App code lifecycle (SNAPSHOT → RC → Release)
    "UC-E1:demo-uc-e1-app-deployment.sh:App version deployment (full promotion):dev,stage,prod"
    "UC-E2:demo-uc-e2-code-plus-config.sh:App code + config change together:dev,stage,prod"
    "UC-E4:demo-uc-e4-app-rollback.sh:App-level rollback (surgical image tag):dev,stage,prod"
    # Category A: Environment-Specific (dev only)
    "UC-A1:demo-uc-a1-replicas.sh:Adjust replica count (isolated):dev"
    "UC-A2:demo-uc-a2-debug-mode.sh:Enable debug mode (isolated):dev"
    "UC-A3:demo-uc-a3-env-configmap.sh:Environment-specific ConfigMap (isolated):dev"
    # Category B: App-Level Cross-Environment (full promotion)
    "UC-B1:demo-uc-b1-app-env-var.sh:App env var propagates to all environments:dev,stage,prod"
    "UC-B2:demo-uc-b2-app-annotation.sh:App annotation propagates to all environments:dev,stage,prod"
    "UC-B3:demo-uc-b3-app-configmap.sh:App ConfigMap entry propagates to all environments:dev,stage,prod"
    "UC-B4:demo-uc-b4-app-override.sh:App ConfigMap with environment override:dev,stage,prod"
    "UC-B5:demo-uc-b5-probe-override.sh:App probe with environment override:dev,stage,prod"
    "UC-B6:demo-uc-b6-env-var-override.sh:App env var with environment override:dev,stage,prod"
    # Category C: Platform-Wide (full promotion)
    "UC-C1:demo-uc-c1-default-label.sh:Platform-wide label propagation:dev,stage,prod"
    "UC-C2:demo-uc-c2-security-context.sh:Platform-wide pod security context:dev,stage,prod"
    "UC-C3:demo-uc-c3-deployment-strategy.sh:Platform-wide zero-downtime deployment strategy:dev,stage,prod"
    "UC-C4:demo-uc-c4-prometheus-annotations.sh:Platform-wide pod annotations:dev,stage,prod"
    "UC-C5:demo-uc-c5-app-override.sh:Platform default with app override:dev,stage,prod"
    "UC-C6:demo-uc-c6-platform-env-override.sh:Platform default with env override:dev,stage,prod"
    # Category D: Operational Scenarios
    "UC-D1:demo-uc-d1-hotfix.sh:Emergency hotfix to production:prod"
    "UC-D2:demo-uc-d2-cherry-pick.sh:Cherry-pick promotion (selective apps):dev,stage"
    "UC-D3:demo-uc-d3-rollback.sh:Environment rollback (GitOps revert):stage"
    "UC-D4:demo-uc-d4-3rd-party-upgrade.sh:3rd party dependency upgrade (postgres):dev,stage,prod"
    "UC-D5:demo-uc-d5-skip-env.sh:Skip environment (dev→prod direct):dev,prod"
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
    printf "  %-20s %-40s %-20s %s\n" "ID" "Script" "Branches" "Description"
    printf "  %-20s %-40s %-20s %s\n" "--" "------" "--------" "-----------"
    for entry in "${DEMO_ORDER[@]}"; do
        IFS=':' read -r id script desc branches <<< "$entry"
        branches="${branches:-dev,stage,prod}"
        local full_path="$SCRIPT_DIR/$script"
        local status="✓"
        [[ ! -x "$full_path" ]] && status="○"
        printf "  %s %-18s %-40s %-20s %s\n" "$status" "$id" "$script" "$branches" "$desc"
    done
    echo ""
    echo "Legend: ✓ = exists, ○ = not implemented"
    echo ""
}

run_reset() {
    local test_id="$1"
    local branches="${2:-dev,stage,prod}"
    local reset_example_app="${3:-false}"

    if [[ "$SKIP_RESET" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  RESET: Preparing clean state for $test_id${NC}"
    echo -e "${BLUE}  Branches: $branches${NC}"
    if [[ "$reset_example_app" == "true" ]]; then
        echo -e "${BLUE}  Example-app cleanup: enabled${NC}"
    fi
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ ! -x "$RESET_SCRIPT" ]]; then
        echo -e "${RED}[ERROR]${NC} Reset script not found: $RESET_SCRIPT"
        return 1
    fi

    local reset_args=(--branches "$branches")
    if [[ "$reset_example_app" == "true" ]]; then
        reset_args+=(--reset-example-app)
    fi

    if ! "$RESET_SCRIPT" "${reset_args[@]}"; then
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
                echo "Usage: $0 <config-file> [OPTIONS] [TEST_ID...]"
                echo ""
                echo "Run verification tests for the CI/CD pipeline reference implementation."
                echo ""
                echo "Arguments:"
                echo "  config-file    Path to cluster configuration file (required)"
                echo ""
                echo "Options:"
                echo "  --list, -l     List available tests"
                echo "  --no-reset     Skip reset between tests (faster, less isolated)"
                echo "  --help, -h     Show this help"
                echo ""
                echo "Examples:"
                echo "  $0 config/clusters/alpha.env                    # Run all verifications"
                echo "  $0 config/clusters/alpha.env --no-reset         # Run all without reset"
                echo "  $0 config/clusters/alpha.env UC-C1              # Run specific test"
                echo "  $0 config/clusters/alpha.env --list             # List available tests"
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

    # Track whether to reset example-app on next reset
    # First reset always cleans example-app to ensure clean slate
    local reset_example_app_next="true"

    for entry in "${DEMO_ORDER[@]}"; do
        IFS=':' read -r id script desc branches <<< "$entry"
        branches="${branches:-dev,stage,prod}"  # Default if missing

        # Filter if specific ID requested (partial match)
        if [[ -n "$filter" && "$id" != *"$filter"* && "$filter" != *"$id"* ]]; then
            continue
        fi

        # Run reset before each test with appropriate branches
        # Include example-app cleanup if flagged (first run or after UC-E2)
        if ! run_reset "$id" "$branches" "$reset_example_app_next"; then
            RESULTS[$id]="SKIP"
            DURATIONS[$id]=0
            continue
        fi

        # Reset the example-app flag (only first reset and after UC-E2 need it)
        reset_example_app_next="false"

        # Run the test
        run_demo "$id" "$script" "$desc"

        # UC-E2 modifies example-app, so the next reset needs to clean it
        if [[ "$id" == "UC-E2" ]]; then
            reset_example_app_next="true"
        fi
    done

    # Print summary
    print_summary
    exit $?
}

main "$@"
