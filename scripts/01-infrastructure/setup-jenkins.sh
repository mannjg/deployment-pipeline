#!/usr/bin/env bash
set -euo pipefail

# Jenkins Setup Script
# Deploys Jenkins using Helm with custom agent
#
# Usage: ./setup-jenkins.sh <config-file>
#    Or: export CLUSTER_CONFIG=<config-file>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load cluster configuration (provides JENKINS_NAMESPACE and other vars)
# Accept config file as argument or from CLUSTER_CONFIG env var
CONFIG_FILE="${1:-${CLUSTER_CONFIG:-}}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Cluster config file required"
    echo "Usage: $0 <config-file>"
    echo "   Or: export CLUSTER_CONFIG=<config-file>"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
export CLUSTER_CONFIG="$CONFIG_FILE"

# Source shared logging library
source "$SCRIPT_DIR/../lib/logging.sh"

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Add ~/bin to PATH if helm is there
    if [[ -f "$HOME/bin/helm" ]]; then
        export PATH="$HOME/bin:$PATH"
    fi

    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed"
        exit 1
    fi

    if ! kubectl get namespace "$JENKINS_NAMESPACE" &> /dev/null; then
        log_warn "Jenkins namespace '$JENKINS_NAMESPACE' doesn't exist. Creating..."
        kubectl create namespace "$JENKINS_NAMESPACE"
    fi

    # Check if custom agent image exists
    if ! docker images | grep -q "jenkins-agent-custom"; then
        log_error "Custom Jenkins agent image not found. Please run: ./k8s/jenkins/agent/build-agent-image.sh"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

add_helm_repo() {
    log_info "Adding Jenkins Helm repository..."

    helm repo add jenkins https://charts.jenkins.io
    helm repo update

    log_info "Jenkins Helm repository added"
}

deploy_jenkins() {
    log_info "Deploying Jenkins..."

    # Check if already deployed
    if helm list -n "$JENKINS_NAMESPACE" | grep -q "jenkins"; then
        log_warn "Jenkins is already deployed"
        read -p "Do you want to upgrade? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Upgrading Jenkins..."
            helm upgrade jenkins jenkins/jenkins \
                -n "$JENKINS_NAMESPACE" \
                -f "$PROJECT_ROOT/k8s/jenkins/values.yaml" \
                --timeout=600s
        else
            log_info "Skipping deployment"
            return 0
        fi
    else
        log_info "Installing Jenkins (this may take several minutes)..."
        helm install jenkins jenkins/jenkins \
            -n "$JENKINS_NAMESPACE" \
            -f "$PROJECT_ROOT/k8s/jenkins/values.yaml" \
            --timeout=600s \
            --wait
    fi

    log_info "Jenkins deployed successfully"
}

wait_for_jenkins() {
    log_info "Waiting for Jenkins to be ready..."

    # Wait for Jenkins controller to be ready
    log_info "Waiting for Jenkins controller..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/component=jenkins-controller \
        -n "$JENKINS_NAMESPACE" \
        --timeout=600s || {
        log_warn "Jenkins controller pods may still be starting. Checking status..."
        kubectl get pods -n "$JENKINS_NAMESPACE"
    }

    log_info "Jenkins is ready!"
}

get_admin_password() {
    log_info "Retrieving Jenkins admin password..."

    # Wait for secret to be created
    sleep 10

    if kubectl get secret -n "$JENKINS_NAMESPACE" jenkins &> /dev/null; then
        ADMIN_PASSWORD=$(kubectl get secret -n "$JENKINS_NAMESPACE" jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
        echo "$ADMIN_PASSWORD" > "$PROJECT_ROOT/k8s/jenkins/admin-password.txt"
        chmod 600 "$PROJECT_ROOT/k8s/jenkins/admin-password.txt"
        log_info "Admin password saved to: $PROJECT_ROOT/k8s/jenkins/admin-password.txt"
    else
        log_warn "Admin password secret not found. It may be created later."
        log_info "You can retrieve it with:"
        log_info "  kubectl get secret -n $JENKINS_NAMESPACE jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d"
    fi
}

create_docker_config() {
    log_info "Creating Docker config for agent..."

    # Create a secret for Docker config (if needed)
    # This allows agents to pull images from Docker Hub
    if ! kubectl get secret -n "$JENKINS_NAMESPACE" docker-config &> /dev/null; then
        log_info "Creating docker-config secret..."
        kubectl create secret generic docker-config \
            -n "$JENKINS_NAMESPACE" \
            --from-literal=config.json='{"auths":{}}' || true
    fi
}

print_info() {
    local jenkins_url="${JENKINS_URL_EXTERNAL:-http://${JENKINS_HOST_EXTERNAL:-jenkins.local}}"
    echo ""
    echo "========================================="
    log_info "Jenkins Setup Complete!"
    echo "========================================="
    echo ""
    echo "Access Jenkins at: $jenkins_url"
    echo ""
    echo "Default credentials:"
    echo "  Username: admin"
    if [[ -f "$PROJECT_ROOT/k8s/jenkins/admin-password.txt" ]]; then
        echo "  Password: $(cat $PROJECT_ROOT/k8s/jenkins/admin-password.txt)"
    else
        echo "  Password: Run the following to retrieve:"
        echo "    kubectl get secret -n $JENKINS_NAMESPACE jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d"
    fi
    echo ""
    echo "Jenkins pods:"
    kubectl get pods -n "$JENKINS_NAMESPACE"
    echo ""
    echo "Ingress:"
    kubectl get ingress -n "$JENKINS_NAMESPACE"
    echo ""
    echo "Next steps:"
    echo "  1. Login to Jenkins at $jenkins_url"
    echo "  2. Configure GitLab connection"
    echo "  3. Create pipeline jobs for example-app"
    echo "  4. Configure credentials for GitLab and Nexus"
    echo ""
}

main() {
    log_info "Starting Jenkins setup..."

    check_prerequisites
    add_helm_repo
    deploy_jenkins
    wait_for_jenkins
    get_admin_password
    create_docker_config
    print_info
}

main "$@"
