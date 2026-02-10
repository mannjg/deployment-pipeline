#!/bin/bash
# Configure Jenkins root URL (JenkinsLocationConfiguration)
#
# Usage: ./scripts/02-configure/configure-jenkins-root-url.sh [config-file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load infrastructure config
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"

log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

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

configure_root_url() {
    log_step "Configuring Jenkins root URL..."

    local script
    script=$(cat <<EOF
import jenkins.model.JenkinsLocationConfiguration

def cfg = JenkinsLocationConfiguration.get()
cfg.setUrl("${JENKINS_URL}")
cfg.save()
println "Jenkins root URL set to: ${JENKINS_URL}"
EOF
)

    curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        --data-urlencode "script=${script}" \
        "$JENKINS_URL/scriptText" \
        >/dev/null

    log_pass "Jenkins root URL configured"
}

main() {
    load_credentials
    get_crumb
    configure_root_url
}

main "$@"
