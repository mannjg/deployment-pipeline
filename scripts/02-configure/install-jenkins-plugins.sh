#!/bin/bash
# Install required Jenkins plugins via REST API
#
# Installs plugins needed for the CI/CD pipeline:
# - credentials (credential management)
# - credentials-binding (secret injection)
# - git (git SCM)
# - workflow-aggregator (Pipeline)
# - workflow-multibranch (MultiBranch Pipeline)
# - gitlab-plugin (GitLab integration)
# - multibranch-scan-webhook-trigger (webhook scanning)
#
# Usage: ./scripts/02-configure/install-jenkins-plugins.sh [config-file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load infrastructure config
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"

# Required plugins (in dependency order)
REQUIRED_PLUGINS=(
    "credentials"
    "plain-credentials"
    "credentials-binding"
    "ssh-credentials"
    "git-client"
    "git"
    "workflow-api"
    "workflow-step-api"
    "workflow-scm-step"
    "workflow-cps"
    "workflow-job"
    "workflow-basic-steps"
    "workflow-durable-task-step"
    "workflow-support"
    "workflow-multibranch"
    "workflow-aggregator"
    "branch-api"
    "scm-api"
    "gitlab-plugin"
    "multibranch-scan-webhook-trigger"
    # Kubernetes plugin for pod-based agents
    "kubernetes"
    "kubernetes-credentials"
    # Pipeline UX: timestamps and colored output
    "timestamper"
    "ansicolor"
)

# Output helpers
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }
log_warn()  { echo "[!] $*"; }

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

# Check if plugin is installed
plugin_installed() {
    local plugin="$1"
    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/pluginManager/api/json?depth=1&xpath=//plugin[shortName='$plugin']")

    if [[ "$status_code" == "200" ]]; then
        # Check if plugin exists in response
        curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/pluginManager/api/json?depth=1" 2>/dev/null | \
            jq -e ".plugins[] | select(.shortName == \"$plugin\")" &>/dev/null
        return $?
    fi
    return 1
}

# Install a single plugin
install_plugin() {
    local plugin="$1"

    if plugin_installed "$plugin"; then
        log_info "  $plugin - already installed"
        return 0
    fi

    log_info "  $plugin - installing..."

    local xml="<jenkins><install plugin=\"$plugin@latest\" /></jenkins>"

    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -H "Content-Type: text/xml" \
        -X POST \
        --data "$xml" \
        "$JENKINS_URL/pluginManager/installNecessaryPlugins")

    if [[ "$status_code" == "200" || "$status_code" == "302" ]]; then
        return 0
    else
        log_warn "  $plugin - install request returned HTTP $status_code"
        return 1
    fi
}

# Wait for plugins to be installed by checking if they're in the plugin list
wait_for_installs() {
    log_step "Waiting for plugin installations to complete..."

    local max_attempts=60
    local attempt=0
    local key_plugins=("credentials" "workflow-multibranch" "gitlab-plugin" "kubernetes")

    while [[ $attempt -lt $max_attempts ]]; do
        # Get installed plugins to a temp file (avoid pipe issues with large JSON)
        if ! curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/pluginManager/api/json?depth=2" -o /tmp/jenkins_plugins.json 2>/dev/null; then
            log_info "  Jenkins API not ready yet, waiting..."
            sleep 10
            ((attempt++)) || true
            continue
        fi

        # Check if file has content
        if [[ ! -s /tmp/jenkins_plugins.json ]]; then
            log_info "  Empty response, Jenkins may be restarting..."
            sleep 10
            ((attempt++)) || true
            continue
        fi

        local missing=0
        for plugin in "${key_plugins[@]}"; do
            if ! jq -e ".plugins[] | select(.shortName == \"$plugin\" and .active == true)" /tmp/jenkins_plugins.json &>/dev/null; then
                ((missing++)) || true
            fi
        done

        if [[ $missing -eq 0 ]]; then
            log_pass "All key plugins are installed and active"
            rm -f /tmp/jenkins_plugins.json
            return 0
        fi

        log_info "  Waiting for $missing key plugins to become active..."
        sleep 10
        ((attempt++)) || true
    done

    rm -f /tmp/jenkins_plugins.json
    log_warn "Timed out waiting for plugin installations"
    return 1
}

# Check if restart is required
check_restart_required() {
    local restart_required
    restart_required=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/updateCenter/api/json" 2>/dev/null | \
        jq -r '.restartRequiredForCompletion // false')

    if [[ "$restart_required" == "true" ]]; then
        return 0
    fi
    return 1
}

# Safe restart Jenkins
restart_jenkins() {
    log_step "Restarting Jenkins to activate plugins..."

    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -X POST \
        "$JENKINS_URL/safeRestart")

    if [[ "$status_code" == "200" || "$status_code" == "302" || "$status_code" == "503" ]]; then
        log_info "Restart initiated"
    else
        log_warn "Restart request returned HTTP $status_code"
    fi
}

# Wait for Jenkins to come back
wait_for_jenkins() {
    log_step "Waiting for Jenkins to restart..."

    local max_attempts=60
    local attempt=0

    # First wait for it to go down
    sleep 5

    while [[ $attempt -lt $max_attempts ]]; do
        local status_code
        status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/api/json" 2>/dev/null || echo "000")

        if [[ "$status_code" == "200" ]]; then
            log_pass "Jenkins is back online"
            return 0
        fi

        log_info "  Waiting... (HTTP $status_code)"
        sleep 5
        ((attempt++)) || true
    done

    log_fail "Timed out waiting for Jenkins"
    return 1
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "Jenkins Plugin Installation"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Jenkins: $JENKINS_URL"
    echo ""

    load_credentials
    get_crumb

    log_step "Installing required plugins..."
    local install_count=0

    for plugin in "${REQUIRED_PLUGINS[@]}"; do
        if install_plugin "$plugin"; then
            ((install_count++)) || true
        fi
    done

    if [[ $install_count -gt 0 ]]; then
        wait_for_installs

        if check_restart_required; then
            restart_jenkins
            wait_for_jenkins
        else
            log_info "No restart required"
        fi
    else
        log_info "All plugins already installed"
    fi

    echo ""
    echo "=========================================="
    log_pass "Plugin installation complete"
    echo "=========================================="
    echo ""
}

main "$@"
