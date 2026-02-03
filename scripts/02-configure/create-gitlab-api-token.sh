#!/bin/bash
# Create GitLab API Token
# Creates a personal access token via gitlab-rails and stores it in K8s secret
#
# Usage: ./scripts/02-configure/create-gitlab-api-token.sh <config-file>
#
# This script is idempotent - if the secret already exists with a valid token,
# it will skip creation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load cluster configuration
CONFIG_FILE="${1:-${CLUSTER_CONFIG:-}}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Cluster config file required"
    echo "Usage: $0 <config-file>"
    exit 1
fi
source "$CONFIG_FILE"
export CLUSTER_CONFIG="$CONFIG_FILE"

# Source logging
source "$SCRIPT_DIR/../lib/logging.sh"

# =============================================================================
# Configuration
# =============================================================================

TOKEN_NAME="api-automation-token"
TOKEN_SCOPES="api read_user read_repository write_repository"
SECRET_NAME="${GITLAB_API_TOKEN_SECRET:-gitlab-api-token}"
SECRET_KEY="${GITLAB_API_TOKEN_KEY:-token}"

# =============================================================================
# Functions
# =============================================================================

check_existing_token() {
    log_info "Checking for existing GitLab API token..."

    local token
    token=$(kubectl get secret "$SECRET_NAME" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${SECRET_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$token" ]]; then
        # Verify token works
        local status_code
        status_code=$(curl -sfk -o /dev/null -w "%{http_code}" \
            -H "PRIVATE-TOKEN: $token" \
            "http://gitlab.${GITLAB_NAMESPACE}.svc.cluster.local/api/v4/user" 2>/dev/null) || status_code="000"

        if [[ "$status_code" == "200" ]]; then
            log_info "Valid GitLab API token already exists in secret '$SECRET_NAME'"
            return 0
        else
            log_warn "Existing token is invalid (status: $status_code), will create new one"
            return 1
        fi
    fi

    log_info "No existing token found"
    return 1
}

wait_for_gitlab_ready() {
    log_info "Waiting for GitLab to be fully ready..."

    local max_attempts=60
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        # Check if GitLab rails is ready by testing a simple query
        if kubectl exec -n "$GITLAB_NAMESPACE" deployment/gitlab -- \
            gitlab-rails runner "puts User.count" &>/dev/null; then
            log_info "GitLab rails is ready"
            return 0
        fi

        ((attempt++)) || true
        echo -n "."
        sleep 5
    done

    echo ""
    log_error "GitLab did not become ready in time"
    return 1
}

create_api_token() {
    # NOTE: This function outputs ONLY the token to stdout
    # All log messages go to stderr so callers can capture just the token

    echo "[INFO] Creating GitLab personal access token via rails runner..." >&2

    # Create token via gitlab-rails runner
    # The ruby script creates a token and outputs just the token value
    local ruby_script='
user = User.find_by_username("root")
if user.nil?
  STDERR.puts "ERROR: root user not found"
  exit 1
end

# Delete existing token with same name (idempotent)
user.personal_access_tokens.where(name: "'"$TOKEN_NAME"'").destroy_all

# Create new token
token = user.personal_access_tokens.create!(
  name: "'"$TOKEN_NAME"'",
  scopes: ["api", "read_user", "read_repository", "write_repository"],
  expires_at: 365.days.from_now
)

puts token.token
'

    local token
    token=$(kubectl exec -n "$GITLAB_NAMESPACE" deployment/gitlab -- \
        gitlab-rails runner "$ruby_script" 2>/dev/null)

    if [[ -z "$token" || "$token" == "ERROR"* ]]; then
        echo "[ERROR] Failed to create GitLab API token" >&2
        return 1
    fi

    echo "[INFO] Token created successfully" >&2
    echo "$token"
}

store_token_in_secret() {
    local token="$1"

    log_info "Storing token in Kubernetes secret '$SECRET_NAME'..."

    # Delete existing secret if present
    kubectl delete secret "$SECRET_NAME" -n "$GITLAB_NAMESPACE" --ignore-not-found=true &>/dev/null

    # Create new secret
    kubectl create secret generic "$SECRET_NAME" \
        -n "$GITLAB_NAMESPACE" \
        --from-literal="$SECRET_KEY=$token"

    log_info "Token stored in secret '$SECRET_NAME'"
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_header "GitLab API Token Setup"
    log_info "Namespace: $GITLAB_NAMESPACE"
    log_info "Secret: $SECRET_NAME"
    echo ""

    # Check if valid token already exists
    if check_existing_token; then
        log_info "Skipping token creation (already exists and valid)"
        return 0
    fi

    # Wait for GitLab to be ready
    wait_for_gitlab_ready

    # Create token
    local token
    token=$(create_api_token)

    # Store in K8s secret
    store_token_in_secret "$token"

    echo ""
    log_header "GitLab API Token Ready"
    log_info "Token stored in: $GITLAB_NAMESPACE/$SECRET_NAME"
}

main "$@"
