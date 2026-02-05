#!/bin/bash
# Setup Jenkins Credentials from Kubernetes Secrets
#
# Creates required credentials in Jenkins for pipeline operations.
# Reads from K8s secrets and creates via Jenkins API.
# Idempotent - skips credentials that already exist.
#
# Usage:
#   ./scripts/01-infrastructure/setup-jenkins-credentials.sh
#
# Prerequisites:
#   - Jenkins running and accessible
#   - kubectl configured with cluster access
#   - K8s secrets created (gitlab, nexus, argocd namespaces)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
source "$PROJECT_ROOT/scripts/lib/logging.sh"
source "$PROJECT_ROOT/scripts/lib/infra.sh"
source "$PROJECT_ROOT/scripts/lib/credentials.sh"

# Get Jenkins auth
JENKINS_AUTH=$(require_jenkins_credentials)
JENKINS_URL="${JENKINS_URL_EXTERNAL}"

# =============================================================================
# Helper Functions
# =============================================================================

# Get Jenkins CSRF crumb
get_crumb() {
    local crumb_json
    crumb_json=$(curl -sfk -u "$JENKINS_AUTH" \
        "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null) || {
        log_error "Failed to get Jenkins CSRF crumb"
        return 1
    }
    CRUMB_FIELD=$(echo "$crumb_json" | jq -r '.crumbRequestField')
    CRUMB_VALUE=$(echo "$crumb_json" | jq -r '.crumb')
    log_info "Got Jenkins CSRF crumb"
}

# Check if a credential exists in Jenkins
credential_exists() {
    local cred_id="$1"
    local result
    result=$(curl -sfk -u "$JENKINS_AUTH" \
        "$JENKINS_URL/credentials/store/system/domain/_/credential/${cred_id}/api/json" 2>/dev/null | \
        jq -r '.id // empty') || true
    [[ -n "$result" ]]
}

# Create a username/password credential in Jenkins
create_username_password_credential() {
    local cred_id="$1"
    local username="$2"
    local password="$3"
    local description="$4"

    if credential_exists "$cred_id"; then
        log_info "  $cred_id: already exists (skipping)"
        return 0
    fi

    local json_payload
    json_payload=$(cat <<EOF
{
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "${cred_id}",
    "username": "${username}",
    "password": "${password}",
    "description": "${description}",
    "\$class": "com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl"
  }
}
EOF
)

    if curl -sfk -u "$JENKINS_AUTH" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -X POST "$JENKINS_URL/credentials/store/system/domain/_/createCredentials" \
        --data-urlencode "json=${json_payload}" 2>/dev/null; then
        log_info "  $cred_id: created"
    else
        log_error "  $cred_id: failed to create"
        return 1
    fi
}

# Create a secret text credential in Jenkins
create_secret_text_credential() {
    local cred_id="$1"
    local secret="$2"
    local description="$3"

    if credential_exists "$cred_id"; then
        log_info "  $cred_id: already exists (skipping)"
        return 0
    fi

    local json_payload
    json_payload=$(cat <<EOF
{
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "${cred_id}",
    "secret": "${secret}",
    "description": "${description}",
    "\$class": "org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"
  }
}
EOF
)

    if curl -sfk -u "$JENKINS_AUTH" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -X POST "$JENKINS_URL/credentials/store/system/domain/_/createCredentials" \
        --data-urlencode "json=${json_payload}" 2>/dev/null; then
        log_info "  $cred_id: created"
    else
        log_error "  $cred_id: failed to create"
        return 1
    fi
}

# =============================================================================
# Credential Setup Functions
# =============================================================================

setup_gitlab_credentials() {
    log_info "Setting up GitLab credentials..."

    # gitlab-credentials (username/password for git operations)
    local gitlab_user gitlab_token
    gitlab_user=$(kubectl get secret "$GITLAB_USER_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_USER_KEY}}" 2>/dev/null | base64 -d) || true
    gitlab_token=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$gitlab_user" && -n "$gitlab_token" ]]; then
        create_username_password_credential \
            "gitlab-credentials" \
            "$gitlab_user" \
            "$gitlab_token" \
            "GitLab credentials for git operations"
    else
        log_warn "  gitlab-credentials: K8s secrets not found (skipping)"
    fi

    # gitlab-api-token-secret (secret text for API calls)
    if [[ -n "$gitlab_token" ]]; then
        create_secret_text_credential \
            "gitlab-api-token-secret" \
            "$gitlab_token" \
            "GitLab API token for REST API calls"
    else
        log_warn "  gitlab-api-token-secret: K8s secret not found (skipping)"
    fi
}

setup_nexus_credentials() {
    log_info "Setting up Nexus credentials..."

    local nexus_user nexus_pass
    nexus_user=$(kubectl get secret "$NEXUS_ADMIN_SECRET" -n "$NEXUS_NAMESPACE" \
        -o jsonpath="{.data.${NEXUS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    nexus_pass=$(kubectl get secret "$NEXUS_ADMIN_SECRET" -n "$NEXUS_NAMESPACE" \
        -o jsonpath="{.data.${NEXUS_ADMIN_PASSWORD_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$nexus_user" && -n "$nexus_pass" ]]; then
        create_username_password_credential \
            "nexus-credentials" \
            "$nexus_user" \
            "$nexus_pass" \
            "Nexus Repository Manager credentials for artifact deployment"
    else
        log_warn "  nexus-credentials: K8s secrets not found (skipping)"
    fi
}

setup_argocd_credentials() {
    log_info "Setting up ArgoCD credentials..."

    # ArgoCD admin password is in argocd-initial-admin-secret
    local argocd_pass
    argocd_pass=$(kubectl get secret argocd-initial-admin-secret -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || true

    if [[ -n "$argocd_pass" ]]; then
        create_username_password_credential \
            "argocd-credentials" \
            "admin" \
            "$argocd_pass" \
            "ArgoCD credentials for deployment sync"
    else
        log_warn "  argocd-credentials: K8s secret not found (skipping)"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_info "=== Setting up Jenkins Credentials ==="
    log_info "Jenkins URL: $JENKINS_URL"
    echo ""

    get_crumb

    setup_gitlab_credentials
    setup_nexus_credentials
    setup_argocd_credentials

    echo ""
    log_info "=== Credential setup complete ==="
}

main "$@"
