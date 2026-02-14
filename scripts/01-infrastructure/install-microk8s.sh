#!/usr/bin/env bash
set -euo pipefail

# MicroK8s Installation and Configuration Script
# This script installs MicroK8s and configures it for the deployment pipeline

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if running on Linux
    if [[ "$(uname)" != "Linux" ]]; then
        log_error "This script only works on Linux systems"
        exit 1
    fi

    # Check available RAM (need at least 8GB, recommend 16GB)
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    if (( total_ram < 8 )); then
        log_error "Insufficient RAM. Need at least 8GB, found ${total_ram}GB"
        exit 1
    elif (( total_ram < 16 )); then
        log_warn "Found ${total_ram}GB RAM. 16GB is recommended for optimal performance"
    else
        log_info "RAM check passed: ${total_ram}GB available"
    fi

    # Check available disk space (need at least 8GB for minimal, 50GB recommended)
    available_disk=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if (( available_disk < 8 )); then
        log_error "Insufficient disk space. Need at least 8GB, found ${available_disk}GB"
        exit 1
    elif (( available_disk < 20 )); then
        log_warn "Low disk space: ${available_disk}GB available. This may limit the number of components you can deploy."
        log_warn "Recommended: 50GB for full setup"
        log_warn "Continuing with minimal setup..."
    elif (( available_disk < 50 )); then
        log_warn "Found ${available_disk}GB disk space. 50GB is recommended for full setup"
    else
        log_info "Disk space check passed: ${available_disk}GB available"
    fi

    # Check if running as root or with sudo
    if [[ $EUID -eq 0 ]]; then
        log_error "Don't run this script as root. Run as a regular user (will use sudo when needed)"
        exit 1
    fi

    # Check if user is in sudo or admin group
    if groups | grep -q '\(sudo\|admin\|wheel\)'; then
        log_info "User has sudo group membership"
    else
        log_error "User needs sudo access. Run: sudo usermod -aG sudo $USER"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

install_microk8s() {
    log_info "Installing MicroK8s..."

    # Check if already installed
    if command -v microk8s &> /dev/null; then
        log_warn "MicroK8s is already installed"
        microk8s version
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping installation"
            return 0
        fi
        log_info "Removing existing MicroK8s installation..."
        sudo snap remove microk8s
    fi

    # Install MicroK8s using snap
    log_info "Installing MicroK8s via snap..."
    sudo snap install microk8s --classic --channel=1.28/stable

    # Add user to microk8s group
    log_info "Adding user $USER to microk8s group..."
    sudo usermod -a -G microk8s $USER

    # Set ownership of kubectl config
    sudo chown -R $USER ~/.kube 2>/dev/null || true

    log_info "MicroK8s installed successfully"
    log_warn "You may need to log out and back in for group changes to take effect"
    log_warn "Alternatively, run: newgrp microk8s"
}

wait_for_microk8s() {
    log_info "Waiting for MicroK8s to be ready..."

    # Wait up to 5 minutes for MicroK8s to be ready
    timeout=300
    elapsed=0
    while ! microk8s status --wait-ready &> /dev/null; do
        if (( elapsed >= timeout )); then
            log_error "MicroK8s failed to become ready within ${timeout} seconds"
            exit 1
        fi
        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""

    log_info "MicroK8s is ready"
    microk8s status
}

enable_addons() {
    log_info "Enabling required addons..."

    # Enable DNS addon
    log_info "Enabling dns addon..."
    microk8s enable dns

    # Enable storage addon
    log_info "Enabling storage addon..."
    microk8s enable storage

    # Enable ingress addon
    log_info "Enabling ingress addon..."
    microk8s enable ingress

    # Wait for addons to be ready
    log_info "Waiting for addons to be ready..."
    sleep 10

    # Wait for DNS to be ready
    log_info "Waiting for CoreDNS..."
    microk8s kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=300s

    # Wait for ingress controller to be ready
    log_info "Waiting for Ingress Controller..."
    microk8s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress --timeout=300s

    log_info "All addons enabled and ready"
}

configure_kubectl_alias() {
    log_info "Configuring kubectl alias..."

    # Create kubectl alias
    if ! grep -q "alias kubectl='microk8s kubectl'" ~/.bashrc; then
        echo "alias kubectl='microk8s kubectl'" >> ~/.bashrc
        log_info "Added kubectl alias to ~/.bashrc"
    fi

    # Also add to current shell
    alias kubectl='microk8s kubectl'

    log_info "You can now use 'kubectl' instead of 'microk8s kubectl'"
    log_warn "Run 'source ~/.bashrc' or restart your shell for the alias to take effect"
}

configure_hosts() {
    log_info "Configuring /etc/hosts for local domains..."

    # Backup /etc/hosts
    sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d-%H%M%S)

    # Add local domains if not already present
    domains=("gitlab.local" "jenkins.local" "nexus.local" "argocd.local")

    for domain in "${domains[@]}"; do
        if ! grep -q "$domain" /etc/hosts; then
            echo "127.0.0.1 $domain" | sudo tee -a /etc/hosts > /dev/null
            log_info "Added $domain to /etc/hosts"
        else
            log_warn "$domain already exists in /etc/hosts"
        fi
    done

    log_info "/etc/hosts configured successfully"
}

create_namespaces() {
    log_info "Creating namespaces for applications..."

    namespaces=("dev" "stage" "prod" "gitlab" "jenkins" "nexus" "argocd")

    for ns in "${namespaces[@]}"; do
        if ! microk8s kubectl get namespace "$ns" &> /dev/null; then
            microk8s kubectl create namespace "$ns"
            log_info "Created namespace: $ns"
        else
            log_warn "Namespace $ns already exists"
        fi
    done
}

save_kubeconfig() {
    log_info "Saving kubeconfig for external tools..."

    mkdir -p "$PROJECT_ROOT/infrastructure/microk8s"

    # Export kubeconfig
    microk8s config > "$PROJECT_ROOT/infrastructure/microk8s/kubeconfig"

    log_info "Kubeconfig saved to: $PROJECT_ROOT/infrastructure/microk8s/kubeconfig"
    log_info "To use with kubectl: export KUBECONFIG=$PROJECT_ROOT/infrastructure/microk8s/kubeconfig"
}

print_summary() {
    echo ""
    echo "========================================="
    log_info "MicroK8s Installation Complete!"
    echo "========================================="
    echo ""
    echo "Cluster Information:"
    microk8s kubectl cluster-info
    echo ""
    echo "Enabled Addons:"
    microk8s status | grep -A 20 "addons:"
    echo ""
    echo "Available Namespaces:"
    microk8s kubectl get namespaces
    echo ""
    echo "Next Steps:"
    echo "  1. Run: source ~/.bashrc  (to enable kubectl alias)"
    echo "  2. Or run: newgrp microk8s  (to apply group changes)"
    echo "  3. Deploy services: ./scripts/setup-all.sh"
    echo ""
    echo "Access services at:"
    echo "  - GitLab:  http://gitlab.local"
    echo "  - Jenkins: http://jenkins.local"
    echo "  - Nexus:   http://nexus.local"
    echo "  - ArgoCD:  http://argocd.local"
    echo ""
}

main() {
    log_info "Starting MicroK8s installation and configuration..."
    echo ""

    check_prerequisites
    install_microk8s

    # Use newgrp to apply group changes in current script
    # This is a workaround for the group membership issue
    sg microk8s <<EOF
        $(declare -f wait_for_microk8s)
        $(declare -f enable_addons)
        $(declare -f configure_kubectl_alias)
        $(declare -f configure_hosts)
        $(declare -f create_namespaces)
        $(declare -f save_kubeconfig)
        $(declare -f log_info)
        $(declare -f log_warn)
        $(declare -f log_error)
        PROJECT_ROOT="$PROJECT_ROOT"
        GREEN='$GREEN'
        YELLOW='$YELLOW'
        RED='$RED'
        NC='$NC'

        wait_for_microk8s
        enable_addons
        configure_kubectl_alias
        configure_hosts
        create_namespaces
        save_kubeconfig
EOF

    print_summary
}

main "$@"
