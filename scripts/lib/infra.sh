#!/bin/bash
# Infrastructure configuration loader
# Sources config/infra.env and validates required variables
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/infra.sh"

set -euo pipefail

# Determine paths
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_LIB_DIR/../.." && pwd)"
_INFRA_ENV="$_PROJECT_ROOT/config/infra.env"

# Source logging if not already loaded
if ! declare -f log_error &>/dev/null; then
    source "$_LIB_DIR/logging.sh"
fi

# Verify infra.env exists
if [[ ! -f "$_INFRA_ENV" ]]; then
    log_error "Infrastructure config not found: $_INFRA_ENV"
    exit 1
fi

# Source infrastructure configuration
# shellcheck source=../../config/infra.env
source "$_INFRA_ENV"

# Validate required variables exist
: "${GITLAB_NAMESPACE:?GITLAB_NAMESPACE not set in infra.env}"
: "${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set in infra.env}"
: "${GITLAB_GROUP:?GITLAB_GROUP not set in infra.env}"
: "${GITLAB_API_TOKEN_SECRET:?GITLAB_API_TOKEN_SECRET not set in infra.env}"
: "${GITLAB_API_TOKEN_KEY:?GITLAB_API_TOKEN_KEY not set in infra.env}"
: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE not set in infra.env}"
: "${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set in infra.env}"
: "${JENKINS_ADMIN_SECRET:?JENKINS_ADMIN_SECRET not set in infra.env}"

# Export PROJECT_ROOT for scripts that need it
export PROJECT_ROOT="$_PROJECT_ROOT"
