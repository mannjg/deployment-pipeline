#!/bin/bash
# Ensure GitLab Webhook for Jenkins MultiBranch Pipeline
#
# Usage: ./scripts/ensure-gitlab-webhook.sh <gitlab-project-path>
#   e.g.: ./scripts/ensure-gitlab-webhook.sh p2c/example-app
#
# This script ensures a GitLab project has the correct webhook configured
# to trigger Jenkins MultiBranch Pipeline builds on push events.
#
# Prerequisites:
#   - kubectl configured with access to cluster
#   - config/infra.env with infrastructure URLs and secret references

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Load infrastructure config
if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
    source "$REPO_ROOT/config/infra.env"
else
    echo "[✗] Infrastructure config not found: config/infra.env"
    exit 1
fi

# Validate required config from infra.env
validate_config() {
    local missing=()

    [[ -z "${GITLAB_NAMESPACE:-}" ]] && missing+=("GITLAB_NAMESPACE")
    [[ -z "${GITLAB_URL_EXTERNAL:-}" ]] && missing+=("GITLAB_URL_EXTERNAL")
    [[ -z "${GITLAB_API_TOKEN_SECRET:-}" ]] && missing+=("GITLAB_API_TOKEN_SECRET")
    [[ -z "${GITLAB_API_TOKEN_KEY:-}" ]] && missing+=("GITLAB_API_TOKEN_KEY")
    [[ -z "${JENKINS_URL_INTERNAL:-}" ]] && missing+=("JENKINS_URL_INTERNAL")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[✗] Missing required config in infra.env:"
        for var in "${missing[@]}"; do
            echo "    - $var"
        done
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
# Credentials
# -----------------------------------------------------------------------------
load_gitlab_token() {
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_fail "Could not load GitLab token"
        log_info "Secret: $GITLAB_API_TOKEN_SECRET (namespace: $GITLAB_NAMESPACE)"
        log_info "Key: $GITLAB_API_TOKEN_KEY"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# GitLab API Helpers
# -----------------------------------------------------------------------------
gitlab_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    curl -sk -X "$method" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        "${GITLAB_URL_EXTERNAL}/api/v4${endpoint}" \
        "$@"
}

url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------
ensure_webhook() {
    local project_path="$1"
    local job_name="${project_path##*/}"  # Extract last segment (e.g., "example-app")

    # MultiBranch Scan Webhook Trigger URL (token-based, bypasses CSRF)
    # Requires multibranch-scan-webhook-trigger plugin and job configured with matching token
    local expected_webhook_url="${JENKINS_URL_INTERNAL}/multibranch-webhook-trigger/invoke?token=${job_name}"

    log_step "Ensuring webhook for $project_path"
    log_info "Jenkins job: $job_name"
    log_info "Expected webhook: $expected_webhook_url"
    echo ""

    # URL-encode the project path for API calls
    local encoded_path
    encoded_path=$(url_encode "$project_path")

    # Get existing webhooks
    local existing_hooks
    existing_hooks=$(gitlab_api GET "/projects/${encoded_path}/hooks")

    if [[ -z "$existing_hooks" ]] || [[ "$existing_hooks" == "null" ]]; then
        log_fail "Could not fetch webhooks (project may not exist or access denied)"
        exit 1
    fi

    # Check if correct webhook already exists
    local correct_hook_id
    correct_hook_id=$(echo "$existing_hooks" | jq -r --arg url "$expected_webhook_url" \
        '.[] | select(.url == $url) | .id' | head -1)

    if [[ -n "$correct_hook_id" ]]; then
        log_pass "Correct webhook already exists (id: $correct_hook_id)"
        return 0
    fi

    # Check for any Jenkins webhook (possibly misconfigured)
    local old_id old_url
    old_id=$(echo "$existing_hooks" | jq -r '.[] | select(.url | contains("jenkins")) | .id' | head -1)
    old_url=$(echo "$existing_hooks" | jq -r '.[] | select(.url | contains("jenkins")) | .url' | head -1)

    if [[ -n "$old_id" ]] && [[ "$old_id" != "null" ]]; then
        log_info "Found misconfigured Jenkins webhook (id: $old_id)"
        log_info "Old URL: $old_url"
        log_step "Updating webhook to correct URL..."

        # Update the existing webhook
        local update_result
        update_result=$(gitlab_api PUT "/projects/${encoded_path}/hooks/${old_id}" \
            -d "{\"url\": \"${expected_webhook_url}\", \"push_events\": true, \"enable_ssl_verification\": false}")

        if echo "$update_result" | jq -e '.id' &>/dev/null; then
            log_pass "Webhook updated successfully"
        else
            log_fail "Failed to update webhook"
            echo "$update_result" | jq '.' 2>/dev/null || echo "$update_result"
            exit 1
        fi
    else
        log_step "Creating new webhook..."

        # Create new webhook
        local create_result
        create_result=$(gitlab_api POST "/projects/${encoded_path}/hooks" \
            -d "{\"url\": \"${expected_webhook_url}\", \"push_events\": true, \"enable_ssl_verification\": false}")

        if echo "$create_result" | jq -e '.id' &>/dev/null; then
            local new_id
            new_id=$(echo "$create_result" | jq -r '.id')
            log_pass "Webhook created (id: $new_id)"
        else
            log_fail "Failed to create webhook"
            echo "$create_result" | jq '.' 2>/dev/null || echo "$create_result"
            exit 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <gitlab-project-path>"
        echo "  e.g.: $0 p2c/example-app"
        exit 1
    fi

    local project_path="$1"

    validate_config

    log_step "Loading GitLab credentials..."
    load_gitlab_token
    log_info "GitLab: $GITLAB_URL_EXTERNAL"
    log_info "Jenkins (internal): $JENKINS_URL_INTERNAL"
    echo ""

    ensure_webhook "$project_path"
}

main "$@"
