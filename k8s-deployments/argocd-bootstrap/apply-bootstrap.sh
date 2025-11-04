#!/bin/bash
set -euo pipefail

# Apply the ArgoCD Bootstrap Application
# This script applies the bootstrap app-of-apps that manages all other ArgoCD applications

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_FILE="${SCRIPT_DIR}/bootstrap-app.yaml"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
fi

# Check if ArgoCD namespace exists
if ! kubectl get namespace argocd &> /dev/null; then
    log_error "ArgoCD namespace 'argocd' not found. Please install ArgoCD first."
    exit 1
fi

# Check if bootstrap file exists
if [ ! -f "$BOOTSTRAP_FILE" ]; then
    log_error "Bootstrap file not found: $BOOTSTRAP_FILE"
    exit 1
fi

log_info "Applying ArgoCD Bootstrap Application..."
log_info "This will create the 'bootstrap' Application that manages all other Applications"
echo

# Show what will be applied
log_info "Bootstrap Application configuration:"
echo "----------------------------------------"
cat "$BOOTSTRAP_FILE"
echo "----------------------------------------"
echo

# Ask for confirmation
read -p "Apply this configuration? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warn "Aborted by user"
    exit 0
fi

# Apply the bootstrap application
if kubectl apply -f "$BOOTSTRAP_FILE"; then
    log_info "Bootstrap Application applied successfully!"
    echo
    log_info "Waiting for bootstrap application to be created..."
    sleep 2

    # Show the created application
    log_info "Bootstrap Application status:"
    kubectl get application bootstrap -n argocd
    echo

    log_info "The bootstrap application will now:"
    log_info "  1. Sync ArgoCD Application definitions from Git"
    log_info "  2. Create/update application resources in manifests/argocd/"
    log_info "  3. Manage the lifecycle of all applications"
    echo
    log_info "To watch applications being created:"
    log_info "  kubectl get applications -n argocd -w"
    echo
    log_info "To view application details:"
    log_info "  kubectl describe application bootstrap -n argocd"
    log_info "  argocd app get bootstrap"
else
    log_error "Failed to apply bootstrap application"
    exit 1
fi
