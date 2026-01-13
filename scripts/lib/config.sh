#!/bin/bash
# Helper to source GitLab configuration with validation
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

# Determine script location and source config
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_FILE="${_SCRIPT_DIR}/../config/gitlab.env"

# Handle scripts in subdirectories (like scripts/lib/)
if [[ ! -f "$_CONFIG_FILE" ]]; then
    _CONFIG_FILE="${_SCRIPT_DIR}/../../config/gitlab.env"
fi

if [[ ! -f "$_CONFIG_FILE" ]]; then
    echo "ERROR: Cannot find config/gitlab.env" >&2
    echo "Expected at: ${_SCRIPT_DIR}/../config/gitlab.env" >&2
    exit 1
fi

# shellcheck source=../../config/gitlab.env
source "$_CONFIG_FILE"

# Validate required variables
: "${GITLAB_URL:?GITLAB_URL is required - check config/gitlab.env}"
: "${GITLAB_GROUP:?GITLAB_GROUP is required - check config/gitlab.env}"
: "${DEPLOYMENTS_REPO_URL:?DEPLOYMENTS_REPO_URL is required - check config/gitlab.env}"
