#!/bin/bash
# Common test library functions
# Provides logging, utilities, and helper functions for test scripts

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ] || [ "${VERBOSE:-0}" = "1" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Get kubectl command (handles both direct kubectl and microk8s kubectl)
get_kubectl_cmd() {
    if command -v kubectl &> /dev/null; then
        echo "kubectl"
    elif command -v microk8s &> /dev/null; then
        echo "microk8s kubectl"
    else
        log_error "kubectl not found"
        return 1
    fi
}

# Utility to wait with timeout
wait_for_condition() {
    local description=$1
    local timeout=$2
    local check_command=$3

    local elapsed=0
    log_info "Waiting for: $description (timeout: ${timeout}s)"

    while [ $elapsed -lt $timeout ]; do
        if eval "$check_command" 2>/dev/null; then
            log_pass "$description (${elapsed}s)"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))

        if [ $((elapsed % 30)) -eq 0 ]; then
            log_debug "$description - still waiting (${elapsed}s elapsed)"
        fi
    done

    log_error "$description - timeout after ${timeout}s"
    return 1
}
