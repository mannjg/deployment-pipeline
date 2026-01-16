#!/bin/bash
# Setup GitLab webhook for k8s-deployments auto-promote
#
# Configures GitLab webhook to trigger Jenkins auto-promote job
# when MRs are merged to dev or stage branches.
#
# Usage: ./scripts/03-pipelines/setup-auto-promote-webhook.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - GitLab running and accessible
#   - Jenkins auto-promote job created

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

source "$PROJECT_ROOT/config/infra.env"

GITLAB_URL="${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set}"
JENKINS_URL_INTERNAL="${JENKINS_URL_INTERNAL:?JENKINS_URL_INTERNAL not set}"
JOB_NAME="${JENKINS_AUTO_PROMOTE_JOB_NAME:-k8s-deployments-auto-promote}"
PROJECT_PATH="${DEPLOYMENTS_REPO_PATH:?DEPLOYMENTS_REPO_PATH not set}"

# -----------------------------------------------------------------------------
# Validate Configuration
# -----------------------------------------------------------------------------
validate_config() {
    local missing=()

    [[ -z "${GITLAB_URL:-}" ]] && missing+=("GITLAB_URL_EXTERNAL")
    [[ -z "${JENKINS_URL_INTERNAL:-}" ]] && missing+=("JENKINS_URL_INTERNAL")
    [[ -z "${PROJECT_PATH:-}" ]] && missing+=("DEPLOYMENTS_REPO_PATH")
    [[ -z "${GITLAB_NAMESPACE:-}" ]] && missing+=("GITLAB_NAMESPACE")
    [[ -z "${GITLAB_API_TOKEN_SECRET:-}" ]] && missing+=("GITLAB_API_TOKEN_SECRET")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_fail "Missing required configuration: ${missing[*]}"
        log_info "Ensure config/infra.env is properly configured"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Load GitLab Token
# -----------------------------------------------------------------------------
load_gitlab_token() {
    log_step "Loading GitLab credentials from K8s secrets..."

    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_fail "Could not load GitLab token"
        exit 1
    fi

    log_info "GitLab token loaded"
}

# -----------------------------------------------------------------------------
# GitLab API Helper
# -----------------------------------------------------------------------------
gitlab_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    curl -sk -X "$method" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        "${GITLAB_URL}/api/v4${endpoint}" \
        "$@"
}

url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------
setup_webhook() {
    log_step "Setting up webhook for $PROJECT_PATH..."

    # Generate webhook token (must match Jenkins job config)
    local webhook_token
    webhook_token=$(echo -n "${JOB_NAME}-webhook" | sha256sum | cut -c1-32)

    # Webhook URL uses GitLab plugin endpoint
    local webhook_url="${JENKINS_URL_INTERNAL}/project/${JOB_NAME}"

    log_info "Webhook URL: $webhook_url"
    log_info "Token: ${webhook_token:0:8}..."

    local encoded_path
    encoded_path=$(url_encode "$PROJECT_PATH")

    # Get existing webhooks
    local existing_hooks
    existing_hooks=$(gitlab_api GET "/projects/${encoded_path}/hooks")

    if [[ -z "$existing_hooks" ]] || [[ "$existing_hooks" == "null" ]]; then
        log_fail "Could not fetch webhooks (project may not exist or access denied)"
        log_info "Project path: $PROJECT_PATH"
        [[ -n "$existing_hooks" ]] && echo "$existing_hooks"
        exit 1
    fi

    # Check for existing webhook with this URL
    local existing_id
    existing_id=$(echo "$existing_hooks" | jq -r --arg url "$webhook_url" \
        '.[] | select(.url == $url) | .id' | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        log_info "Webhook already exists (id: $existing_id), updating..."

        local update_result
        update_result=$(gitlab_api PUT "/projects/${encoded_path}/hooks/${existing_id}" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"push_events_branch_filter\": \"dev,stage\", \"enable_ssl_verification\": false, \"token\": \"${webhook_token}\"}")

        if echo "$update_result" | jq -e '.id' &>/dev/null; then
            log_pass "Webhook updated successfully"
        else
            log_fail "Failed to update webhook"
            echo "$update_result"
            exit 1
        fi
    else
        log_step "Creating new webhook..."

        local create_result
        create_result=$(gitlab_api POST "/projects/${encoded_path}/hooks" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"push_events_branch_filter\": \"dev,stage\", \"enable_ssl_verification\": false, \"token\": \"${webhook_token}\"}")

        if echo "$create_result" | jq -e '.id' &>/dev/null; then
            local new_id
            new_id=$(echo "$create_result" | jq -r '.id')
            log_pass "Webhook created (id: $new_id)"
        else
            log_fail "Failed to create webhook"
            echo "$create_result"
            exit 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "=== Setup Auto-Promote Webhook ==="
    echo ""

    validate_config
    load_gitlab_token

    log_info "GitLab: $GITLAB_URL"
    log_info "Project: $PROJECT_PATH"
    log_info "Jenkins job: $JOB_NAME"
    echo ""

    setup_webhook

    echo ""
    log_pass "Webhook setup complete"
    echo ""
    echo "The webhook will trigger on push to 'dev' and 'stage' branches."
    echo "This happens automatically when MRs are merged to these branches."
}

main "$@"
