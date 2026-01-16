#!/bin/bash
set -euo pipefail

# Teardown Script
# Removes all deployed infrastructure components

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

confirm_teardown() {
    echo -e "${RED}"
    echo "WARNING: This will delete all deployed infrastructure!"
    echo "  - GitLab (including all repositories)"
    echo "  - Jenkins (including all job configurations)"
    echo "  - Nexus (including all artifacts)"
    echo "  - ArgoCD (including all applications)"
    echo "  - All application deployments in dev/stage/prod namespaces"
    echo -e "${NC}"

    read -p "Are you absolutely sure? Type 'yes' to continue: " -r
    if [[ ! $REPLY == "yes" ]]; then
        log_info "Teardown cancelled"
        exit 0
    fi
}

delete_namespaces() {
    log_info "Deleting application namespaces..."

    namespaces=("dev" "stage" "prod")

    for ns in "${namespaces[@]}"; do
        if microk8s kubectl get namespace "$ns" &> /dev/null; then
            log_warn "Deleting namespace: $ns"
            microk8s kubectl delete namespace "$ns" --timeout=60s
        fi
    done
}

delete_infrastructure() {
    log_info "Deleting infrastructure components..."

    # Delete ArgoCD
    if microk8s kubectl get namespace argocd &> /dev/null; then
        log_warn "Deleting ArgoCD..."
        microk8s kubectl delete namespace argocd --timeout=60s
    fi

    # Delete Nexus
    if microk8s kubectl get namespace nexus &> /dev/null; then
        log_warn "Deleting Nexus..."
        microk8s kubectl delete namespace nexus --timeout=60s
    fi

    # Delete Jenkins
    if microk8s kubectl get namespace jenkins &> /dev/null; then
        log_warn "Deleting Jenkins..."
        microk8s kubectl delete namespace jenkins --timeout=60s
    fi

    # Delete GitLab
    if microk8s kubectl get namespace gitlab &> /dev/null; then
        log_warn "Deleting GitLab..."
        microk8s kubectl delete namespace gitlab --timeout=60s
    fi
}

delete_pvcs() {
    log_info "Checking for remaining PVCs..."

    # List all PVCs
    pvcs=$(microk8s kubectl get pvc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')

    if [[ -n "$pvcs" ]]; then
        log_warn "Found PVCs that need manual cleanup:"
        echo "$pvcs"
        read -p "Delete all PVCs? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            while IFS='/' read -r ns name; do
                microk8s kubectl delete pvc -n "$ns" "$name"
            done <<< "$pvcs"
        fi
    fi
}

cleanup_helm() {
    log_info "Cleaning up Helm releases..."

    if command -v helm &> /dev/null; then
        releases=$(helm list --all-namespaces -q)
        if [[ -n "$releases" ]]; then
            log_warn "Found Helm releases:"
            echo "$releases"
            while IFS= read -r release; do
                log_warn "Uninstalling Helm release: $release"
                helm uninstall "$release" --wait || true
            done <<< "$releases"
        fi
    fi
}

print_summary() {
    echo ""
    log_info "Teardown complete!"
    echo ""
    echo "Remaining resources:"
    microk8s kubectl get all --all-namespaces
    echo ""
    echo "To completely remove MicroK8s:"
    echo "  sudo snap remove microk8s"
    echo ""
    echo "To reinstall everything:"
    echo "  ./scripts/install-microk8s.sh"
    echo "  ./scripts/setup-all.sh"
    echo ""
}

main() {
    log_warn "Starting teardown..."

    confirm_teardown

    delete_namespaces
    delete_infrastructure
    cleanup_helm
    delete_pvcs

    print_summary
}

main "$@"
