#!/bin/bash
# Credential helpers with fail-fast behavior
# Fetches credentials from K8s secrets or environment variables
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/credentials.sh"
#        GITLAB_TOKEN=$(require_gitlab_token)

set -euo pipefail

# Determine paths
_CRED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies if not already loaded
if ! declare -f log_error &>/dev/null; then
    source "$_CRED_LIB_DIR/logging.sh"
fi

# Ensure infra.sh is loaded (we need secret names from infra.env)
if [[ -z "${GITLAB_TOKEN_SECRET:-}" ]]; then
    source "$_CRED_LIB_DIR/infra.sh"
fi

# Fetch GitLab API token - fails if not available
# Checks: 1) GITLAB_TOKEN env var, 2) K8s secret
require_gitlab_token() {
    # Check environment variable first
    if [[ -n "${GITLAB_TOKEN:-}" ]]; then
        echo "$GITLAB_TOKEN"
        return 0
    fi

    # Try K8s secret
    local token
    token=$(kubectl get secret "$GITLAB_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$token" ]]; then
        echo "$token"
        return 0
    fi

    # Fail fast with clear instructions
    log_error "GitLab token not available."
    echo "" >&2
    echo "Provide token via one of:" >&2
    echo "  1. Environment: export GITLAB_TOKEN=glpat-..." >&2
    echo "  2. K8s secret:  kubectl get secret $GITLAB_TOKEN_SECRET -n $GITLAB_NAMESPACE" >&2
    exit 1
}

# Fetch Jenkins credentials - fails if not available
# Returns: username:password (for basic auth)
require_jenkins_credentials() {
    local user password

    # Check environment variables first
    if [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_TOKEN:-}" ]]; then
        echo "${JENKINS_USER}:${JENKINS_TOKEN}"
        return 0
    fi

    # Try K8s secret
    user=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    password=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$user" && -n "$password" ]]; then
        echo "${user}:${password}"
        return 0
    fi

    # Fail fast with clear instructions
    log_error "Jenkins credentials not available."
    echo "" >&2
    echo "Provide credentials via one of:" >&2
    echo "  1. Environment: export JENKINS_USER=... JENKINS_TOKEN=..." >&2
    echo "  2. K8s secret:  kubectl get secret $JENKINS_ADMIN_SECRET -n $JENKINS_NAMESPACE" >&2
    exit 1
}

# Fetch GitLab user credentials (username for git operations)
require_gitlab_user() {
    # Check environment variable first
    if [[ -n "${GITLAB_USER:-}" ]]; then
        echo "$GITLAB_USER"
        return 0
    fi

    # Try K8s secret
    local user
    user=$(kubectl get secret "$GITLAB_USER_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_USER_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$user" ]]; then
        echo "$user"
        return 0
    fi

    # Fail fast
    log_error "GitLab user not available."
    echo "" >&2
    echo "Provide via: export GITLAB_USER=... or ensure K8s secret exists" >&2
    exit 1
}

# Fetch Nexus credentials - fails if not available
# Returns: username:password (for basic auth)
require_nexus_credentials() {
    local user password

    # Check environment variables first
    if [[ -n "${NEXUS_USER:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
        echo "${NEXUS_USER}:${NEXUS_PASSWORD}"
        return 0
    fi

    # Try K8s secret
    user=$(kubectl get secret "$NEXUS_ADMIN_SECRET" -n "$NEXUS_NAMESPACE" \
        -o jsonpath="{.data.${NEXUS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    password=$(kubectl get secret "$NEXUS_ADMIN_SECRET" -n "$NEXUS_NAMESPACE" \
        -o jsonpath="{.data.${NEXUS_ADMIN_PASSWORD_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$user" && -n "$password" ]]; then
        echo "${user}:${password}"
        return 0
    fi

    # Fail fast with clear instructions
    log_error "Nexus credentials not available."
    echo "" >&2
    echo "Provide credentials via one of:" >&2
    echo "  1. Environment: export NEXUS_USER=... NEXUS_PASSWORD=..." >&2
    echo "  2. K8s secret:  kubectl get secret $NEXUS_ADMIN_SECRET -n $NEXUS_NAMESPACE" >&2
    exit 1
}
