#!/bin/bash
# Configure global environment variables in Jenkins
#
# Copies environment variables from the Jenkins controller's system environment
# into Jenkins global node properties, making them available to all pipelines.
#
# This is necessary because while the controller container has envFrom ConfigMap,
# the Jenkinsfile's env.VAR syntax only sees Jenkins-configured global variables,
# not system environment variables.
#
# Usage: ./scripts/02-configure/configure-jenkins-global-env.sh [config-file]

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

# Configure global environment variables
configure_global_env() {
    log_step "Configuring global environment variables..."

    # Groovy script to configure global env vars
    local script='
import jenkins.model.*
import hudson.slaves.EnvironmentVariablesNodeProperty
import hudson.EnvVars

def jenkins = Jenkins.instance

// List of env vars to copy from system to Jenkins global
// These are loaded into the Jenkins controller via envFrom ConfigMap
def envVarsToExpose = [
    "JENKINS_AGENT_IMAGE",
    "CONTAINER_REGISTRY_EXTERNAL",
    "CONTAINER_REGISTRY_PATH_PREFIX",
    "GITLAB_URL_EXTERNAL",
    "GITLAB_URL_INTERNAL",
    "GITLAB_GROUP",
    "MAVEN_REPO_URL_EXTERNAL",
    "MAVEN_REPO_URL_INTERNAL",
    "ARGOCD_URL_EXTERNAL",
    "ARGOCD_URL_INTERNAL",
    "ARGOCD_SERVER",
    "ARGOCD_OPTS",
    "JENKINS_URL_EXTERNAL",
    "JENKINS_URL_INTERNAL",
    "APP_REPO_URL",
    "DEPLOYMENTS_REPO_URL",
    "GIT_SSL_NO_VERIFY"
]

// Get or create global properties
def globalProps = jenkins.getGlobalNodeProperties()
def envPropList = globalProps.getAll(EnvironmentVariablesNodeProperty.class)
def envProp
if (envPropList.isEmpty()) {
    envProp = new EnvironmentVariablesNodeProperty()
    globalProps.add(envProp)
} else {
    envProp = envPropList[0]
}

// Add env vars from system environment
def envVars = envProp.getEnvVars()
def setCount = 0
def warnCount = 0
envVarsToExpose.each { key ->
    def value = System.getenv(key)
    if (value) {
        envVars.put(key, value)
        setCount++
    } else {
        println "WARN: ${key} not found in system environment"
        warnCount++
    }
}

jenkins.save()
println ""
println "SUCCESS: Set ${setCount} environment variables (${warnCount} warnings)"
'

    local result
    result=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        --data-urlencode "script=$script" \
        "$JENKINS_URL/scriptText" 2>/dev/null)

    if echo "$result" | grep -q "SUCCESS"; then
        log_pass "Global environment variables configured"
        echo "$result" | grep -E "^(SUCCESS|Set|WARN):" | while read line; do
            if echo "$line" | grep -q "^WARN:"; then
                log_warn "${line#WARN: }"
            else
                log_info "$line"
            fi
        done
        return 0
    else
        log_fail "Failed to configure global environment variables"
        log_info "Response: $result"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "Jenkins Global Environment Configuration"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Jenkins: $JENKINS_URL"
    echo ""

    load_credentials
    get_crumb
    configure_global_env

    echo ""
    echo "=========================================="
    log_pass "Global environment configuration complete"
    echo "=========================================="
    echo ""
    echo "Pipelines now have access to:"
    echo "  - env.JENKINS_AGENT_IMAGE (for kubernetes pod templates)"
    echo "  - env.CONTAINER_REGISTRY_* (for image pushing)"
    echo "  - env.GITLAB_URL_* (for API calls)"
    echo "  - env.ARGOCD_* (for deployments)"
    echo "  - And more from pipeline-config ConfigMap"
    echo ""
}

main "$@"
