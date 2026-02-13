#!/usr/bin/env bash
# Shared preflight check functions for k8s-deployments scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/preflight.sh"
#   preflight_check_required GITLAB_URL_INTERNAL GITLAB_GROUP GITLAB_TOKEN

# Colors for output
_PREFLIGHT_RED='\033[0;31m'
_PREFLIGHT_GREEN='\033[0;32m'
_PREFLIGHT_YELLOW='\033[1;33m'
_PREFLIGHT_NC='\033[0m'

# Check if a single variable is set and non-empty
# Returns 0 if set, 1 if not
preflight_check_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    if [[ -z "$var_value" ]]; then
        echo -e "${_PREFLIGHT_RED}ERROR:${_PREFLIGHT_NC} $var_name not set" >&2
        return 1
    fi
    return 0
}

# Check multiple required variables
# Exits with error if any are missing
preflight_check_required() {
    local failed=0
    local missing=()

    for var in "$@"; do
        if ! preflight_check_var "$var" 2>/dev/null; then
            missing+=("$var")
            failed=1
        fi
    done

    if [[ $failed -eq 1 ]]; then
        echo "" >&2
        echo -e "${_PREFLIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PREFLIGHT_NC}" >&2
        echo -e "${_PREFLIGHT_RED}PREFLIGHT CHECK FAILED${_PREFLIGHT_NC}" >&2
        echo -e "${_PREFLIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PREFLIGHT_NC}" >&2
        echo "" >&2
        echo "Missing required configuration:" >&2
        for var in "${missing[@]}"; do
            echo "  - $var" >&2
        done
        echo "" >&2
        echo "For Jenkins: Configure pipeline-config ConfigMap" >&2
        echo "For local:   Copy config/local.env.example to config/local.env and edit" >&2
        echo "See:         docs/CONFIGURATION.md" >&2
        echo "" >&2
        exit 1
    fi

    echo -e "${_PREFLIGHT_GREEN}✓ Preflight checks passed${_PREFLIGHT_NC}"
}

# Check if a command exists
preflight_check_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${_PREFLIGHT_RED}ERROR:${_PREFLIGHT_NC} Required command not found: $cmd" >&2
        if [[ -n "$install_hint" ]]; then
            echo "  Install: $install_hint" >&2
        fi
        return 1
    fi
    return 0
}

# Load local.env if it exists and we're not in Jenkins
preflight_load_local_env() {
    local script_dir="$1"
    local local_env="${script_dir}/../config/local.env"

    # Skip if running in Jenkins (BUILD_URL is set)
    if [[ -n "${BUILD_URL:-}" ]]; then
        return 0
    fi

    if [[ -f "$local_env" ]]; then
        echo -e "${_PREFLIGHT_YELLOW}Loading local configuration from config/local.env${_PREFLIGHT_NC}"
        # shellcheck source=/dev/null
        source "$local_env"
    fi
}
