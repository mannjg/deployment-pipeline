#!/bin/bash
# Setup GitLab webhooks for k8s-deployments auto-promote
#
# Configures GitLab webhooks to trigger Jenkins auto-promote job
# when code is pushed to dev or stage branches (e.g., MR merges).
#
# Uses the build-token-root plugin endpoint which bypasses CRUMB:
#   /buildByToken/buildWithParameters?job=<job>&token=<token>&BRANCH=<branch>
#
# Creates separate webhooks for dev and stage branches because each
# needs a different BRANCH parameter value.
#
# Usage: ./scripts/03-pipelines/setup-auto-promote-webhook.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - GitLab running and accessible
#   - Jenkins auto-promote job created with auth token
#   - build-token-root plugin installed in Jenkins

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

# Branches to set up webhooks for
AUTO_PROMOTE_BRANCHES=("dev" "stage")

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
setup_webhook_for_branch() {
    local branch="$1"
    local webhook_token="$2"

    log_step "Setting up webhook for $PROJECT_PATH branch: $branch"

    # Webhook URL uses build-token-root plugin endpoint (bypasses CRUMB)
    # Format: /buildByToken/buildWithParameters?job=<job>&token=<token>&BRANCH=<branch>
    local webhook_url="${JENKINS_URL_INTERNAL}/buildByToken/buildWithParameters?job=${JOB_NAME}&token=${webhook_token}&BRANCH=${branch}"

    log_info "Webhook URL: ${JENKINS_URL_INTERNAL}/buildByToken/buildWithParameters?job=${JOB_NAME}&token=***&BRANCH=${branch}"

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

    # Check for existing webhook for this branch (by matching BRANCH= parameter)
    local existing_id
    existing_id=$(echo "$existing_hooks" | jq -r --arg branch "$branch" \
        '.[] | select(.url | contains("BRANCH=" + $branch)) | .id' | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        log_info "Webhook for $branch already exists (id: $existing_id), updating..."

        local update_result
        # Note: merge_requests_events must be FALSE to prevent feedback loops
        # When CI creates a promotion MR, we don't want that MR event to trigger another build
        update_result=$(gitlab_api PUT "/projects/${encoded_path}/hooks/${existing_id}" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"merge_requests_events\": false, \"push_events_branch_filter\": \"${branch}\", \"enable_ssl_verification\": false}")

        if echo "$update_result" | jq -e '.id' &>/dev/null; then
            log_pass "Webhook for $branch updated successfully"
        else
            log_fail "Failed to update webhook for $branch"
            echo "$update_result"
            return 1
        fi
    else
        log_step "Creating new webhook for $branch..."

        local create_result
        # Note: merge_requests_events must be FALSE to prevent feedback loops
        # When CI creates a promotion MR, we don't want that MR event to trigger another build
        create_result=$(gitlab_api POST "/projects/${encoded_path}/hooks" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"merge_requests_events\": false, \"push_events_branch_filter\": \"${branch}\", \"enable_ssl_verification\": false}")

        if echo "$create_result" | jq -e '.id' &>/dev/null; then
            local new_id
            new_id=$(echo "$create_result" | jq -r '.id')
            log_pass "Webhook for $branch created (id: $new_id)"
        else
            log_fail "Failed to create webhook for $branch"
            echo "$create_result"
            return 1
        fi
    fi
}

setup_webhooks() {
    # Generate webhook token (must match Jenkins job auth token)
    local webhook_token
    webhook_token=$(echo -n "${JOB_NAME}-webhook" | sha256sum | cut -c1-32)

    log_info "Auth token: ${webhook_token:0:8}..."
    log_info "Branches: ${AUTO_PROMOTE_BRANCHES[*]}"
    echo ""

    for branch in "${AUTO_PROMOTE_BRANCHES[@]}"; do
        setup_webhook_for_branch "$branch" "$webhook_token" || exit 1
        echo ""
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "=== Setup Auto-Promote Webhooks ==="
    echo ""

    validate_config
    load_gitlab_token

    log_info "GitLab: $GITLAB_URL"
    log_info "Project: $PROJECT_PATH"
    log_info "Jenkins job: $JOB_NAME"
    echo ""

    setup_webhooks

    log_pass "All webhooks setup complete"
    echo ""
    echo "Webhooks will trigger on push to environment branches."
    echo "This happens automatically when MRs are merged to dev/stage."
    echo ""
    echo "Flow:"
    echo "  1. MR merged to dev → webhook triggers auto-promote → creates stage promotion MR"
    echo "  2. MR merged to stage → webhook triggers auto-promote → creates prod promotion MR"
}

main "$@"
