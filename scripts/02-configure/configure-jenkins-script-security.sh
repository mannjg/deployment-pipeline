#!/usr/bin/env bash
# Configure Jenkins script security approvals
#
# Approves required method signatures that pipelines need to use.
# This is necessary for pipelines to read configuration from environment variables.
#
# Usage: ./scripts/02-configure/configure-jenkins-script-security.sh [config-file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load infrastructure config
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"

# Output helpers
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }
log_warn()  { echo "[!] $*"; }

# Signatures to approve for pipeline functionality
SIGNATURES=(
    "staticMethod java.lang.System getenv java.lang.String"
)

# Load credentials
load_credentials() {
    log_step "Loading Jenkins credentials from K8s secrets..."

    JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true

    JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$JENKINS_USER" || -z "$JENKINS_TOKEN" ]]; then
        log_fail "Could not load Jenkins credentials"
        exit 1
    fi

    log_info "Loaded credentials for user: $JENKINS_USER"
}

# Get CSRF crumb
get_crumb() {
    log_step "Getting Jenkins CSRF crumb..."

    COOKIE_JAR=$(mktemp)
    trap "rm -f '$COOKIE_JAR'" EXIT

    local crumb_response
    crumb_response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -c "$COOKIE_JAR" \
        "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null)

    CRUMB_FIELD=$(echo "$crumb_response" | jq -r '.crumbRequestField // empty')
    CRUMB_VALUE=$(echo "$crumb_response" | jq -r '.crumb // empty')

    if [[ -z "$CRUMB_FIELD" || -z "$CRUMB_VALUE" ]]; then
        log_fail "Could not get Jenkins CSRF crumb"
        exit 1
    fi

    log_info "Got crumb"
}

# Approve a signature
approve_signature() {
    local signature="$1"

    local script="
import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

def approval = ScriptApproval.get()
def sig = '${signature}'

// Check if already approved
def approved = approval.approvedSignatures.contains(sig)
if (approved) {
    println 'ALREADY_APPROVED: ' + sig
} else {
    approval.approveSignature(sig)
    println 'APPROVED: ' + sig
}
"

    local result
    result=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        --data-urlencode "script=$script" \
        "$JENKINS_URL/scriptText" 2>/dev/null)

    if echo "$result" | grep -q "APPROVED:"; then
        log_info "  Approved: $signature"
        return 0
    elif echo "$result" | grep -q "ALREADY_APPROVED:"; then
        log_info "  Already approved: $signature"
        return 0
    else
        log_warn "  Failed to approve: $signature"
        log_info "  Response: $result"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "Jenkins Script Security Configuration"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Jenkins: $JENKINS_URL"
    echo ""

    load_credentials
    get_crumb

    log_step "Approving required method signatures..."
    local errors=0

    for sig in "${SIGNATURES[@]}"; do
        approve_signature "$sig" || ((++errors))
    done

    echo ""
    if [[ $errors -gt 0 ]]; then
        log_warn "Script security configuration completed with $errors error(s)"
    else
        log_pass "Script security configuration complete"
    fi
    echo "=========================================="
    echo ""
}

main "$@"
