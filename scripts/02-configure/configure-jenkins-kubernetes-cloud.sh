#!/bin/bash
# Configure Kubernetes cloud in Jenkins for pod-based agents
#
# This script configures Jenkins to use the Kubernetes cluster for dynamic
# build agents. It uses JCasC via the Script Console to apply the configuration.
#
# Usage: ./scripts/02-configure/configure-jenkins-kubernetes-cloud.sh [config-file]

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

# Check if Kubernetes cloud is already configured
check_cloud_exists() {
    log_step "Checking if Kubernetes cloud is already configured..."

    local script='
import jenkins.model.Jenkins
def clouds = Jenkins.instance.clouds
def k8sCloud = clouds.find { it.getClass().name.contains("KubernetesCloud") }
if (k8sCloud) {
    println "CLOUD_EXISTS:${k8sCloud.name}"
} else {
    println "CLOUD_MISSING"
}
'

    local result
    result=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        --data-urlencode "script=$script" \
        "$JENKINS_URL/scriptText" 2>/dev/null)

    if echo "$result" | grep -q "CLOUD_EXISTS"; then
        local cloud_name
        cloud_name=$(echo "$result" | grep "CLOUD_EXISTS" | cut -d: -f2)
        log_info "Kubernetes cloud already configured: $cloud_name"
        return 0
    fi

    log_info "No Kubernetes cloud found"
    return 1
}

# Configure Kubernetes cloud
configure_cloud() {
    log_step "Configuring Kubernetes cloud..."

    # Get Jenkins internal URL from ConfigMap
    local jenkins_internal_url
    jenkins_internal_url=$(kubectl get configmap pipeline-config -n "$JENKINS_NAMESPACE" \
        -o jsonpath='{.data.JENKINS_URL_INTERNAL}' 2>/dev/null) || true

    if [[ -z "$jenkins_internal_url" ]]; then
        # Fallback to constructed URL
        jenkins_internal_url="http://jenkins.${JENKINS_NAMESPACE}.svc.cluster.local:8080"
        log_warn "JENKINS_URL_INTERNAL not found in ConfigMap, using: $jenkins_internal_url"
    fi

    log_info "Jenkins URL for agents: $jenkins_internal_url"
    log_info "Jenkins namespace: $JENKINS_NAMESPACE"

    # Groovy script to configure Kubernetes cloud
    local script="
import jenkins.model.Jenkins
import org.csanchez.jenkins.plugins.kubernetes.KubernetesCloud
import org.csanchez.jenkins.plugins.kubernetes.PodTemplate

def jenkins = Jenkins.instance

// Remove existing Kubernetes clouds to ensure clean config
def existingClouds = jenkins.clouds.findAll { it.getClass().name.contains('KubernetesCloud') }
existingClouds.each { jenkins.clouds.remove(it) }

// Create new Kubernetes cloud
def k8sCloud = new KubernetesCloud('kubernetes')
k8sCloud.setServerUrl('https://kubernetes.default.svc')
k8sCloud.setSkipTlsVerify(true)
k8sCloud.setNamespace('${JENKINS_NAMESPACE}')
k8sCloud.setJenkinsUrl('${jenkins_internal_url}')
k8sCloud.setContainerCapStr('10')
k8sCloud.setConnectTimeout(5)
k8sCloud.setReadTimeout(15)
k8sCloud.setRetentionTimeout(5)
k8sCloud.setMaxRequestsPerHostStr('32')
k8sCloud.setWaitForPodSec(600)

// Add to Jenkins
jenkins.clouds.add(k8sCloud)
jenkins.save()

println 'SUCCESS: Kubernetes cloud configured'
println 'Namespace: ${JENKINS_NAMESPACE}'
println 'Jenkins URL: ${jenkins_internal_url}'
"

    local result
    result=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        --data-urlencode "script=$script" \
        "$JENKINS_URL/scriptText" 2>/dev/null)

    if echo "$result" | grep -q "SUCCESS"; then
        log_pass "Kubernetes cloud configured successfully"
        echo "$result" | grep -E "^(Namespace|Jenkins URL):" | while read line; do
            log_info "$line"
        done
        return 0
    else
        log_fail "Failed to configure Kubernetes cloud"
        log_info "Response: $result"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "Jenkins Kubernetes Cloud Configuration"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Jenkins: $JENKINS_URL"
    log_info "Namespace: $JENKINS_NAMESPACE"
    echo ""

    load_credentials
    get_crumb

    if check_cloud_exists; then
        log_info "Skipping configuration (already configured)"
    else
        configure_cloud
    fi

    echo ""
    echo "=========================================="
    log_pass "Kubernetes cloud configuration complete"
    echo "=========================================="
    echo ""
}

main "$@"
