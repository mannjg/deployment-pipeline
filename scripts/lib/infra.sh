#!/bin/bash
# Infrastructure configuration loader
# Sources cluster config and validates required variables
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/infra.sh" [config-file]
#
#   Or set CLUSTER_CONFIG environment variable before sourcing.
#
# If no config file is provided and CLUSTER_CONFIG is not set,
# the script will error (no defaults - explicit config required).

set -euo pipefail

# Determine paths
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_LIB_DIR/../.." && pwd)"

# Source logging if not already loaded
if ! declare -f log_error &>/dev/null; then
    source "$_LIB_DIR/logging.sh"
fi

# Determine config file location
# Priority: 1) argument passed to source, 2) CLUSTER_CONFIG env var, 3) error
_CONFIG_FILE="${1:-${CLUSTER_CONFIG:-}}"

if [[ -z "$_CONFIG_FILE" ]]; then
    log_error "No cluster config specified"
    log_error "Usage: source infra.sh <config-file>"
    log_error "   Or: export CLUSTER_CONFIG=<config-file>"
    exit 1
fi

if [[ ! -f "$_CONFIG_FILE" ]]; then
    # Try relative to project root
    if [[ -f "$_PROJECT_ROOT/$_CONFIG_FILE" ]]; then
        _CONFIG_FILE="$_PROJECT_ROOT/$_CONFIG_FILE"
    else
        log_error "Config file not found: $_CONFIG_FILE"
        exit 1
    fi
fi

# Source cluster configuration
# shellcheck source=/dev/null
source "$_CONFIG_FILE"

# Validate required variables exist
: "${CLUSTER_NAME:?CLUSTER_NAME not set in config}"
: "${GITLAB_NAMESPACE:?GITLAB_NAMESPACE not set in config}"
: "${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set in config}"
: "${GITLAB_GROUP:?GITLAB_GROUP not set in config}"
: "${GITLAB_API_TOKEN_SECRET:?GITLAB_API_TOKEN_SECRET not set in config}"
: "${GITLAB_API_TOKEN_KEY:?GITLAB_API_TOKEN_KEY not set in config}"
: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE not set in config}"
: "${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set in config}"
: "${JENKINS_ADMIN_SECRET:?JENKINS_ADMIN_SECRET not set in config}"
: "${DEV_NAMESPACE:?DEV_NAMESPACE not set in config}"
: "${STAGE_NAMESPACE:?STAGE_NAMESPACE not set in config}"
: "${PROD_NAMESPACE:?PROD_NAMESPACE not set in config}"

# Export PROJECT_ROOT for scripts that need it
export PROJECT_ROOT="$_PROJECT_ROOT"
export CLUSTER_CONFIG="$_CONFIG_FILE"
