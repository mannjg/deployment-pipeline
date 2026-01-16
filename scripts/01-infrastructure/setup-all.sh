#!/bin/bash
set -euo pipefail

# Master Setup Script
# Deploys all infrastructure components in the correct order

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

check_microk8s() {
    log_info "Checking if MicroK8s is installed..."

    if ! command -v microk8s &> /dev/null; then
        log_error "MicroK8s is not installed. Please run ./scripts/install-microk8s.sh first"
        exit 1
    fi

    if ! microk8s status --wait-ready &> /dev/null; then
        log_error "MicroK8s is not running or not ready"
        exit 1
    fi

    log_info "MicroK8s is ready"
}

install_helm() {
    log_info "Checking if Helm is installed..."

    if ! command -v helm &> /dev/null; then
        log_warn "Helm not found. Installing Helm..."

        # Install Helm
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

        log_info "Helm installed successfully"
    else
        log_info "Helm is already installed: $(helm version --short)"
    fi
}

install_argocd_cli() {
    log_info "Checking if ArgoCD CLI is installed..."

    if ! command -v argocd &> /dev/null; then
        log_warn "ArgoCD CLI not found. Installing..."

        # Download and install ArgoCD CLI
        ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
        sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
        rm /tmp/argocd

        log_info "ArgoCD CLI installed successfully: $(argocd version --client --short)"
    else
        log_info "ArgoCD CLI is already installed: $(argocd version --client --short)"
    fi
}

install_cue() {
    log_info "Checking if CUE is installed..."

    if ! command -v cue &> /dev/null; then
        log_warn "CUE not found. Installing..."

        # Download and install CUE
        CUE_VERSION=$(curl -s https://api.github.com/repos/cue-lang/cue/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        curl -sSL "https://github.com/cue-lang/cue/releases/download/${CUE_VERSION}/cue_${CUE_VERSION}_linux_amd64.tar.gz" -o /tmp/cue.tar.gz
        tar -xzf /tmp/cue.tar.gz -C /tmp
        sudo install -m 555 /tmp/cue /usr/local/bin/cue
        rm /tmp/cue.tar.gz /tmp/cue

        log_info "CUE installed successfully: $(cue version)"
    else
        log_info "CUE is already installed: $(cue version)"
    fi
}

setup_gitlab() {
    log_step "Step 1/4: Setting up GitLab"

    if [[ -f "$SCRIPT_DIR/setup-gitlab.sh" ]]; then
        bash "$SCRIPT_DIR/setup-gitlab.sh"
    else
        log_warn "setup-gitlab.sh not found yet. Skipping..."
    fi
}

setup_jenkins() {
    log_step "Step 2/4: Setting up Jenkins"

    if [[ -f "$SCRIPT_DIR/setup-jenkins.sh" ]]; then
        bash "$SCRIPT_DIR/setup-jenkins.sh"
    else
        log_warn "setup-jenkins.sh not found yet. Skipping..."
    fi
}

setup_nexus() {
    log_step "Step 3/4: Setting up Nexus"

    if [[ -f "$SCRIPT_DIR/setup-nexus.sh" ]]; then
        bash "$SCRIPT_DIR/setup-nexus.sh"
    else
        log_warn "setup-nexus.sh not found yet. Skipping..."
    fi
}

setup_argocd() {
    log_step "Step 4/4: Setting up ArgoCD"

    if [[ -f "$SCRIPT_DIR/setup-argocd.sh" ]]; then
        bash "$SCRIPT_DIR/setup-argocd.sh"
    else
        log_warn "setup-argocd.sh not found yet. Skipping..."
    fi
}

print_summary() {
    log_step "Setup Complete!"

    echo "All infrastructure components have been deployed."
    echo ""
    echo "Access the services at:"
    echo "  - GitLab:  http://gitlab.local"
    echo "  - Jenkins: http://jenkins.local"
    echo "  - Nexus:   http://nexus.local"
    echo "  - ArgoCD:  http://argocd.local"
    echo ""
    echo "Default credentials can be found in the respective setup scripts output."
    echo ""
    echo "Next steps:"
    echo "  1. Create the example Quarkus application"
    echo "  2. Setup the k8s-deployments repository"
    echo "  3. Configure CI/CD pipelines"
    echo "  4. Test the end-to-end workflow"
    echo ""
    echo "For more information, see: docs/ARCHITECTURE.md"
    echo ""
}

main() {
    echo -e "${BLUE}"
    echo "========================================="
    echo "  Deployment Pipeline Setup"
    echo "========================================="
    echo -e "${NC}"
    echo "This script will deploy all infrastructure components:"
    echo "  1. GitLab CE"
    echo "  2. Jenkins"
    echo "  3. Nexus Repository"
    echo "  4. ArgoCD"
    echo ""

    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Setup cancelled"
        exit 0
    fi

    log_info "Starting setup..."

    check_microk8s
    install_helm
    install_argocd_cli
    install_cue

    setup_gitlab
    setup_jenkins
    setup_nexus
    setup_argocd

    print_summary
}

main "$@"
