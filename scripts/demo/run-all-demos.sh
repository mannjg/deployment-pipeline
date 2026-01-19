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
    echo -e "  Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$skipped skipped${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
