#!/bin/bash
# Configure MultiBranch Pipeline jobs with webhook trigger
#
# This script adds the MultiBranchScanWebhookTrigger to existing MultiBranch
# Pipeline jobs so they respond to GitLab webhook pushes immediately instead
# of waiting for the polling interval.
#
# Usage:
#   ./scripts/03-pipelines/setup-jenkins-multibranch-webhook.sh <job-name>
#   ./scripts/03-pipelines/setup-jenkins-multibranch-webhook.sh --all
#
# Examples:
#   ./scripts/03-pipelines/setup-jenkins-multibranch-webhook.sh k8s-deployments
#   ./scripts/03-pipelines/setup-jenkins-multibranch-webhook.sh --all
#
# Prerequisites:
#   - kubectl configured with access to cluster
#   - config/infra.env with infrastructure URLs
#   - MultiBranch Pipeline jobs already exist in Jenkins
#   - multibranch-scan-webhook-trigger plugin installed in Jenkins

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

source "$PROJECT_ROOT/config/infra.env"

JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"

# Known MultiBranch Pipeline jobs
KNOWN_JOBS=(
    "example-app"
    "k8s-deployments"
)

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }
log_warn()  { echo "[!] $*"; }

# -----------------------------------------------------------------------------
# Load Credentials
# -----------------------------------------------------------------------------
load_credentials() {
    log_step "Loading Jenkins credentials..."

    JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true

    JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$JENKINS_USER" || -z "$JENKINS_TOKEN" ]]; then
        log_fail "Could not load Jenkins credentials"
        exit 1
    fi

    # Initialize cookie jar for session-based CSRF handling
    COOKIE_JAR="/tmp/jenkins_cookies_$$.txt"
    rm -f "$COOKIE_JAR"
    trap "rm -f '$COOKIE_JAR'" EXIT

    log_info "Jenkins: $JENKINS_URL"
}

# -----------------------------------------------------------------------------
# Jenkins API Helpers
# -----------------------------------------------------------------------------
jenkins_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    curl -sk -X "$method" \
        -b "$COOKIE_JAR" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL}${endpoint}" \
        "$@"
}

get_crumb() {
    # Get CSRF crumb for POST requests (with session cookies)
    local crumb_response
    crumb_response=$(curl -sk -c "$COOKIE_JAR" -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null) || true

    if [[ -n "$crumb_response" ]]; then
        CRUMB_HEADER=$(echo "$crumb_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('crumbRequestField',''))" 2>/dev/null) || true
        CRUMB_VALUE=$(echo "$crumb_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('crumb',''))" 2>/dev/null) || true
    fi
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------

configure_webhook_trigger() {
    local job_name="$1"
    local token="$job_name"  # Token matches job name by convention

    log_step "Configuring webhook trigger for job: $job_name"
    log_info "Webhook token: $token"

    # Get current job config
    local config
    config=$(jenkins_api GET "/job/${job_name}/config.xml" 2>/dev/null)

    if [[ -z "$config" ]] || echo "$config" | grep -q "404"; then
        log_fail "Job not found: $job_name"
        return 1
    fi

    # Check if webhook trigger already exists
    if echo "$config" | grep -q "ComputedFolderWebHookTrigger"; then
        # Check if it has the correct token
        local existing_token
        existing_token=$(echo "$config" | grep -A1 "ComputedFolderWebHookTrigger" | grep -o '<token>[^<]*</token>' | sed 's/<[^>]*>//g')

        if [[ "$existing_token" == "$token" ]]; then
            log_pass "Webhook trigger already configured with correct token"
            return 0
        else
            log_warn "Webhook trigger exists but has different token: $existing_token"
            log_info "Updating token to: $token"
        fi
    fi

    # Add or update the webhook trigger in the triggers section
    # Save config to temp file for processing
    local config_file="/tmp/jenkins_config_${job_name}.xml"
    local new_config_file="/tmp/jenkins_config_${job_name}_new.xml"
    echo "$config" > "$config_file"

    # Check if there's an existing triggers section
    if ! grep -q "<triggers>" "$config_file"; then
        log_fail "No <triggers> section found in job config"
        rm -f "$config_file"
        return 1
    fi

    # Use Python to properly handle XML manipulation
    python3 << PYEOF
import re

with open('$config_file', 'r') as f:
    content = f.read()

# Remove any existing ComputedFolderWebHookTrigger block
content = re.sub(
    r'\s*<com\.igalg\.jenkins\.plugins\.mswt\.trigger\.ComputedFolderWebHookTrigger[^>]*>.*?</com\.igalg\.jenkins\.plugins\.mswt\.trigger\.ComputedFolderWebHookTrigger>',
    '',
    content,
    flags=re.DOTALL
)

# Add new trigger after <triggers>
trigger_xml = '''
    <com.igalg.jenkins.plugins.mswt.trigger.ComputedFolderWebHookTrigger plugin="multibranch-scan-webhook-trigger">
      <spec></spec>
      <token>$token</token>
    </com.igalg.jenkins.plugins.mswt.trigger.ComputedFolderWebHookTrigger>'''

content = content.replace('<triggers>', '<triggers>' + trigger_xml)

with open('$new_config_file', 'w') as f:
    f.write(content)
PYEOF

    if [[ ! -f "$new_config_file" ]]; then
        log_fail "Failed to generate new config"
        rm -f "$config_file"
        return 1
    fi

    config=$(cat "$new_config_file")
    rm -f "$config_file" "$new_config_file"

    # Get CSRF crumb
    get_crumb

    # Update job config
    local update_args=(-H "Content-Type: application/xml")
    if [[ -n "${CRUMB_HEADER:-}" ]]; then
        update_args+=(-H "$CRUMB_HEADER: $CRUMB_VALUE")
    fi

    local result
    result=$(echo "$config" | jenkins_api POST "/job/${job_name}/config.xml" "${update_args[@]}" --data-binary @- 2>&1)

    if [[ -z "$result" ]] || ! echo "$result" | grep -qi "error"; then
        log_pass "Webhook trigger configured successfully"
        log_info "GitLab webhook URL: ${JENKINS_URL_INTERNAL}/multibranch-webhook-trigger/invoke?token=${token}"
        return 0
    else
        log_fail "Failed to update job config"
        echo "$result"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <job-name> | --all"
        echo ""
        echo "Configure MultiBranch Pipeline jobs with webhook trigger."
        echo ""
        echo "Options:"
        echo "  <job-name>  Configure a single job"
        echo "  --all       Configure all known MultiBranch jobs:"
        for job in "${KNOWN_JOBS[@]}"; do
            echo "                - $job"
        done
        echo ""
        echo "This script adds the MultiBranchScanWebhookTrigger so Jenkins"
        echo "responds to GitLab webhooks immediately instead of polling."
        exit 1
    fi

    load_credentials
    echo ""

    if [[ "$1" == "--all" ]]; then
        local failed=0
        for job_name in "${KNOWN_JOBS[@]}"; do
            configure_webhook_trigger "$job_name" || ((failed++))
            echo ""
        done

        if [[ $failed -eq 0 ]]; then
            log_pass "All jobs configured"
        else
            log_fail "$failed job(s) failed to configure"
            exit 1
        fi
    else
        configure_webhook_trigger "$1"
    fi
}

main "$@"
