#!/bin/bash
# Common utilities for regression tests

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export MAGENTA='\033[0;35m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# Test counters
export TESTS_TOTAL=0
export TESTS_PASSED=0
export TESTS_FAILED=0
export TESTS_SKIPPED=0

# Test metadata
export TEST_START_TIME=""
export TEST_NAMESPACE=""
export TEST_TIMESTAMP=""

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "${VERBOSE:-0}" -ge 1 ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

# Progress spinner
spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %10 ))
        printf "\r${CYAN}${spin:$i:1}${NC} %s" "$message"
        sleep 0.1
    done
    printf "\r"
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check required tools
check_required_tools() {
    local missing=()

    local tools=(
        "cue"
        "git"
        "curl"
        "jq"
        "yq"
    )

    # Check for kubectl (either standalone or microk8s)
    if ! command_exists "kubectl" && ! command_exists "microk8s"; then
        missing+=("kubectl or microk8s")
    fi

    for tool in "${tools[@]}"; do
        if ! command_exists "$tool"; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install missing tools and try again"
        return 1
    fi

    log_pass "All required tools are available"
    return 0
}

# Get kubectl command (either kubectl or microk8s kubectl)
get_kubectl_cmd() {
    if command_exists "kubectl"; then
        echo "kubectl"
    elif command_exists "microk8s"; then
        echo "microk8s kubectl"
    else
        echo "kubectl"
    fi
}

# Check cluster connectivity
check_cluster_connectivity() {
    log_debug "Checking Kubernetes cluster connectivity..."

    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    if $kubectl_cmd cluster-info &> /dev/null; then
        log_pass "Kubernetes cluster is accessible"
        return 0
    else
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi
}

# Check ArgoCD installation
check_argocd_installed() {
    log_debug "Checking ArgoCD installation..."

    local kubectl_cmd
    kubectl_cmd=$(get_kubectl_cmd)

    if $kubectl_cmd get namespace argocd &> /dev/null; then
        log_pass "ArgoCD namespace exists"
        return 0
    else
        log_error "ArgoCD namespace not found"
        return 1
    fi
}

# Check GitLab accessibility
check_gitlab_accessible() {
    log_debug "Checking GitLab accessibility..."

    local gitlab_url="http://gitlab.gitlab.svc.cluster.local"

    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${gitlab_url}" | grep -q "^[23]"; then
        log_pass "GitLab is accessible"
        return 0
    else
        log_warn "GitLab may not be accessible (this is OK if running outside cluster)"
        return 0  # Don't fail - might be testing from outside cluster
    fi
}

# Generate test timestamp
generate_test_timestamp() {
    date +%Y%m%d-%H%M%S
}

# Generate test namespace name
generate_test_namespace() {
    echo "pipeline-test-$(generate_test_timestamp)"
}

# Wait for condition with timeout
wait_for_condition() {
    local condition=$1
    local timeout=${2:-60}
    local interval=${3:-2}
    local elapsed=0

    while ! eval "$condition" &> /dev/null; do
        if [ $elapsed -ge $timeout ]; then
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    return 0
}

# Retry command with backoff
retry_with_backoff() {
    local max_attempts=${1:-3}
    local delay=${2:-5}
    local command="${@:3}"
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_debug "Attempt $attempt/$max_attempts: $command"

        if eval "$command"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_debug "Command failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi

        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts"
    return 1
}

# Get test results directory
get_results_dir() {
    echo "${TEST_RESULTS_DIR:-$(pwd)/test-results}"
}

# Initialize test results directory
init_results_dir() {
    local results_dir
    results_dir=$(get_results_dir)
    mkdir -p "$results_dir"
    export TEST_RESULTS_DIR="$results_dir"
}

# Convert seconds to human readable format
seconds_to_human() {
    local seconds=$1
    printf '%02d:%02d:%02d' $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
}
