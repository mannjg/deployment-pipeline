#!/usr/bin/env bash
# Teardown Script
# Completely tears down a cluster with safety features
#
# Usage: ./scripts/teardown.sh <config-file>
#
# Safety features:
# - PROTECTED=true clusters cannot be torn down
# - Shows what will be deleted before confirming
# - Requires explicit "yes" confirmation (not just y/n)
# - Deletes in safe order (ArgoCD apps first, then environments, then infrastructure)
# - Handles stuck namespaces with timeout and force delete

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Colors and Logging
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") <config-file>

Teardown a cluster completely.

This script deletes all namespaces associated with a cluster configuration,
including environment namespaces (dev, stage, prod) and infrastructure
namespaces (GitLab, Jenkins, Nexus, ArgoCD).

Safety Features:
  - Clusters with PROTECTED=true cannot be torn down
  - Shows what will be deleted and requires explicit 'yes' confirmation
  - Deletes in safe order to prevent conflicts

Arguments:
  config-file  Path to cluster configuration file (e.g., config/clusters/alpha.env)

Examples:
  $(basename "$0") config/clusters/alpha.env

Notes:
  - This action is IRREVERSIBLE. All data will be lost.
  - To teardown a protected cluster, edit the config file to set PROTECTED=false
EOF
    exit 1
}

# =============================================================================
# Configuration Validation
# =============================================================================

validate_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    # Source the config
    # shellcheck source=/dev/null
    source "$config_file"

    # Required variables for teardown
    local required_vars=(
        "CLUSTER_NAME"
        "GITLAB_NAMESPACE"
        "JENKINS_NAMESPACE"
        "NEXUS_NAMESPACE"
        "ARGOCD_NAMESPACE"
        "DEV_NAMESPACE"
        "STAGE_NAMESPACE"
        "PROD_NAMESPACE"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Config file missing required variables:"
        for var in "${missing[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi
}

# =============================================================================
# Protection Check
# =============================================================================

check_protection() {
    if [[ "${PROTECTED:-false}" == "true" ]]; then
        log_error "Cluster '$CLUSTER_NAME' is marked PROTECTED=true"
        log_error ""
        log_error "Teardown refused."
        log_error ""
        log_error "If you really want to delete this cluster, edit the config file:"
        log_error "  $CONFIG_FILE"
        log_error ""
        log_error "And set PROTECTED=\"false\""
        exit 1
    fi
}

# =============================================================================
# Deletion Preview
# =============================================================================

show_deletion_preview() {
    # Deduplicate: configs may map multiple components to the same namespace
    local unique_namespaces
    unique_namespaces=$(echo "$ARGOCD_NAMESPACE $NEXUS_NAMESPACE $JENKINS_NAMESPACE $GITLAB_NAMESPACE $DEV_NAMESPACE $STAGE_NAMESPACE $PROD_NAMESPACE" | tr ' ' '\n' | sort -u)

    echo ""
    echo -e "${YELLOW}=============================================="
    echo "WARNING: DESTRUCTIVE OPERATION"
    echo -e "==============================================${NC}"
    echo ""
    echo "Cluster: $CLUSTER_NAME"
    echo "Config:  $CONFIG_FILE"
    echo ""
    echo "The following namespaces will be DELETED:"
    echo ""
    for ns in $unique_namespaces; do
        echo "    - $ns"
    done
    echo ""
    echo -e "${RED}This action is IRREVERSIBLE. All data will be lost.${NC}"
    echo ""
}

# =============================================================================
# Confirmation
# =============================================================================

require_confirmation() {
    echo -n "Type 'yes' to confirm deletion: "
    read -r confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log_info "Teardown cancelled"
        exit 0
    fi

    echo ""
}

# =============================================================================
# Namespace Deletion
# =============================================================================

delete_namespace() {
    local namespace="$1"
    local timeout="${2:-120}"

    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_info "Namespace does not exist, skipping: $namespace"
        return 0
    fi

    log_info "Deleting namespace: $namespace"

    # Try graceful deletion first with timeout
    if kubectl delete namespace "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        log_info "Namespace deleted: $namespace"
        return 0
    fi

    # If that failed, the namespace might be stuck
    log_warn "Timeout deleting $namespace, attempting force delete..."

    # Try to remove finalizers from stuck resources
    # This handles cases where resources are stuck in Terminating state
    kubectl get namespace "$namespace" -o json 2>/dev/null | \
        jq '.spec.finalizers = []' | \
        kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f - 2>/dev/null || true

    # Force delete
    if kubectl delete namespace "$namespace" --force --grace-period=0 2>/dev/null; then
        log_info "Namespace force-deleted: $namespace"
        return 0
    fi

    log_warn "Could not fully delete namespace: $namespace (may need manual cleanup)"
    return 1
}

# =============================================================================
# ArgoCD Applications Cleanup
# =============================================================================

delete_argocd_applications() {
    log_info "Deleting ArgoCD applications to prevent sync conflicts..."

    if ! kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
        log_info "ArgoCD namespace does not exist, skipping application deletion"
        return 0
    fi

    # Delete all ArgoCD applications
    if kubectl delete applications --all -n "$ARGOCD_NAMESPACE" --timeout=60s 2>/dev/null; then
        log_info "ArgoCD applications deleted"
    else
        log_warn "Could not delete all ArgoCD applications (may not exist or timeout)"
    fi

    # Also try to delete any applicationsets
    kubectl delete applicationsets --all -n "$ARGOCD_NAMESPACE" --timeout=30s 2>/dev/null || true
}

# =============================================================================
# Certificate Cleanup
# =============================================================================

cleanup_certificates() {
    log_info "Cleaning up cluster-scoped certificates..."

    # Delete certificates labeled with cluster name
    kubectl delete certificate -A -l "cluster=$CLUSTER_NAME" 2>/dev/null || true

    # Also try to delete certificates by namespace if they exist
    local cert_ns
    cert_ns=$(echo "$GITLAB_NAMESPACE $JENKINS_NAMESPACE $NEXUS_NAMESPACE $ARGOCD_NAMESPACE" | tr ' ' '\n' | sort -u)
    for ns in $cert_ns; do
        kubectl delete certificate --all -n "$ns" 2>/dev/null || true
    done

    # Delete cluster-specific CA resources from cert-manager
    log_info "Cleaning up cluster-specific CA resources..."
    local ca_issuer="${CLUSTER_NAME}-ca-issuer"
    local ca_secret="${CLUSTER_NAME}-ca-key-pair"

    if kubectl get clusterissuer "$ca_issuer" &>/dev/null; then
        kubectl delete clusterissuer "$ca_issuer"
        log_info "  Deleted ClusterIssuer: $ca_issuer"
    fi

    if kubectl get secret "$ca_secret" -n cert-manager &>/dev/null; then
        kubectl delete secret "$ca_secret" -n cert-manager
        log_info "  Deleted Secret: $ca_secret"
    fi
}

# =============================================================================
# Main Teardown Logic
# =============================================================================

perform_teardown() {
    log_info "Starting teardown of cluster: $CLUSTER_NAME"
    echo ""

    local errors=0

    # Step 1: Delete ArgoCD applications first to prevent sync conflicts
    delete_argocd_applications

    # Step 2: Delete environment namespaces
    log_info "Deleting environment namespaces..."
    local env_ns
    env_ns=$(echo "$DEV_NAMESPACE $STAGE_NAMESPACE $PROD_NAMESPACE" | tr ' ' '\n' | sort -u)
    for ns in $env_ns; do
        if ! delete_namespace "$ns" 120; then
            ((errors++)) || true
        fi
    done

    # Step 3: Delete infrastructure namespaces (reverse order of bootstrap)
    log_info "Deleting infrastructure namespaces..."
    local infra_ns
    infra_ns=$(echo "$ARGOCD_NAMESPACE $NEXUS_NAMESPACE $JENKINS_NAMESPACE $GITLAB_NAMESPACE" | tr ' ' '\n' | sort -u)
    for ns in $infra_ns; do
        if ! delete_namespace "$ns" 180; then
            ((errors++)) || true
        fi
    done

    # Step 4: Cleanup cluster-scoped resources
    cleanup_certificates

    echo ""
    if [[ $errors -eq 0 ]]; then
        log_info "Teardown complete for cluster: $CLUSTER_NAME"
    else
        log_warn "Teardown completed with $errors error(s)"
        log_warn "Some namespaces may require manual cleanup"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        usage
    fi

    # Validate config file argument
    CONFIG_FILE="${1:-}"
    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "Config file required"
        echo ""
        usage
    fi

    # Validate and source config
    validate_config "$CONFIG_FILE"

    # Check protection flag
    check_protection

    # Show what will be deleted
    show_deletion_preview

    # Require explicit confirmation
    require_confirmation

    # Perform the teardown
    perform_teardown
}

main "$@"
