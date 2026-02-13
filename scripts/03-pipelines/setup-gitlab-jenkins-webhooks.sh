#!/usr/bin/env bash
# Setup GitLab webhooks to trigger Jenkins MultiBranch Pipeline scans
#
# Creates webhooks in GitLab that notify Jenkins when code is pushed,
# triggering an immediate branch scan instead of waiting for polling.
#
# Usage: ./scripts/03-pipelines/setup-gitlab-jenkins-webhooks.sh [config-file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load infrastructure config
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

# Output helpers
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# URL encode helper
url_encode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
}

# GitLab API helper
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

# Load GitLab credentials
load_credentials() {
    log_step "Loading GitLab credentials from K8s secrets..."

    GITLAB_TOKEN=$(kubectl get secret "$GITLAB_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) || true

    if [[ -z "$GITLAB_TOKEN" ]]; then
        log_fail "Could not load GitLab token"
        exit 1
    fi

    log_info "GitLab token loaded"
}

# Setup webhook for a project
setup_project_webhook() {
    local project_path="$1"
    local jenkins_job="$2"

    log_step "Setting up webhook for $project_path -> $jenkins_job"

    local encoded_path
    encoded_path=$(url_encode "$project_path")

    # Webhook URL for multibranch scan trigger
    local webhook_url="${JENKINS_URL_INTERNAL}/multibranch-webhook-trigger/invoke?token=${jenkins_job}"
    log_info "Webhook URL: $webhook_url"

    # Check for existing webhook
    local existing_hooks
    existing_hooks=$(gitlab_api GET "/projects/${encoded_path}/hooks" 2>/dev/null)

    if [[ -z "$existing_hooks" ]] || [[ "$existing_hooks" == "null" ]]; then
        log_fail "Could not fetch webhooks for $project_path"
        return 1
    fi

    # Check if webhook already exists (by URL pattern)
    local existing_id
    existing_id=$(echo "$existing_hooks" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for hook in data:
    if 'multibranch-webhook-trigger' in hook.get('url', '') and 'token=${jenkins_job}' in hook.get('url', ''):
        print(hook['id'])
        break
" 2>/dev/null)

    if [[ -n "$existing_id" ]]; then
        log_info "Webhook already exists (id: $existing_id), updating..."
        local update_result
        update_result=$(gitlab_api PUT "/projects/${encoded_path}/hooks/${existing_id}" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"merge_requests_events\": false, \"enable_ssl_verification\": false}")

        if echo "$update_result" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'id' in d else 1)" 2>/dev/null; then
            log_pass "Webhook updated"
        else
            log_fail "Failed to update webhook"
            echo "$update_result"
            return 1
        fi
    else
        log_step "Creating new webhook..."
        local create_result
        create_result=$(gitlab_api POST "/projects/${encoded_path}/hooks" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"merge_requests_events\": false, \"enable_ssl_verification\": false}")

        if echo "$create_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print('id:', d.get('id')); exit(0 if 'id' in d else 1)" 2>/dev/null; then
            log_pass "Webhook created"
        else
            log_fail "Failed to create webhook"
            echo "$create_result"
            return 1
        fi
    fi
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Setup GitLab → Jenkins Webhooks"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    GITLAB_URL="${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set}"
    JENKINS_URL_INTERNAL="${JENKINS_URL_INTERNAL:?JENKINS_URL_INTERNAL not set}"

    log_info "GitLab: $GITLAB_URL"
    log_info "Jenkins: $JENKINS_URL_INTERNAL"
    echo ""

    load_credentials
    echo ""

    local failed=0

    # Setup webhook for example-app
    setup_project_webhook "$APP_REPO_PATH" "example-app" || ((++failed)) || true
    echo ""

    # Setup webhook for k8s-deployments
    setup_project_webhook "$DEPLOYMENTS_REPO_PATH" "k8s-deployments" || ((++failed)) || true
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $failed -eq 0 ]]; then
        log_pass "All webhooks configured"
    else
        log_fail "$failed webhook(s) failed to configure"
        exit 1
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "When code is pushed to these repos, GitLab will notify"
    echo "Jenkins to immediately scan for new/changed branches."
}

main "$@"
