#!/bin/bash
# Prepare host machine for cluster bootstrap
#
# This script prepares the local machine to work with a cluster by:
# 1. Generating a CA certificate (if not exists)
# 2. Installing the CA to Docker's trust store (requires sudo)
#
# Run this ONCE before bootstrap. The CA persists across cluster rebuilds.
#
# Usage: ./scripts/00-prepare-cluster.sh <config-file>
#
# Example: ./scripts/00-prepare-cluster.sh config/clusters/alpha.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Base directory for cluster secrets (not in git)
CLUSTERS_DATA_DIR="${HOME}/.local/share/deployment-pipeline/clusters"

# =============================================================================
# Colors and Logging
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
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
log_step()  { echo -e "${BLUE}[→]${NC} $*"; }
log_pass()  { echo -e "${GREEN}[✓]${NC} $*"; }

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") <config-file>

Prepare host machine for cluster bootstrap.

This script:
  1. Generates a CA certificate for the cluster (stored locally, not in git)
  2. Installs the CA to Docker's trust store (requires sudo)

Run this ONCE before bootstrap. The CA persists across cluster rebuilds,
so Docker will trust certificates from any bootstrap using this cluster config.

Arguments:
  config-file  Path to cluster configuration file (e.g., config/clusters/alpha.env)

Examples:
  $(basename "$0") config/clusters/alpha.env
  sudo $(basename "$0") config/clusters/alpha.env  # If not in sudoers

Data location:
  ~/.local/share/deployment-pipeline/clusters/<cluster-name>/
    ca.crt    - CA certificate (shared with cluster)
    ca.key    - CA private key (keep secure!)

EOF
    exit 1
}

# =============================================================================
# Configuration
# =============================================================================

load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    # Source the config file
    # shellcheck source=/dev/null
    source "$config_file"

    # Validate required variables
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        log_error "CLUSTER_NAME not set in config file"
        exit 1
    fi

    if [[ -z "${DOCKER_REGISTRY_HOST:-}" ]]; then
        log_error "DOCKER_REGISTRY_HOST not set in config file"
        exit 1
    fi

    # Set derived paths
    CLUSTER_DATA_DIR="${CLUSTERS_DATA_DIR}/${CLUSTER_NAME}"
    CA_CERT="${CLUSTER_DATA_DIR}/ca.crt"
    CA_KEY="${CLUSTER_DATA_DIR}/ca.key"
    DOCKER_CERT_DIR="/etc/docker/certs.d/${DOCKER_REGISTRY_HOST}"
}

# =============================================================================
# CA Generation
# =============================================================================

generate_ca() {
    log_step "Checking CA certificate..."

    # Create directory if needed
    if [[ ! -d "$CLUSTER_DATA_DIR" ]]; then
        mkdir -p "$CLUSTER_DATA_DIR"
        chmod 700 "$CLUSTER_DATA_DIR"
        log_info "  Created: $CLUSTER_DATA_DIR"
    fi

    # Check if CA already exists
    if [[ -f "$CA_CERT" ]] && [[ -f "$CA_KEY" ]]; then
        log_info "  CA already exists for cluster: $CLUSTER_NAME"
        openssl x509 -in "$CA_CERT" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
        return 0
    fi

    log_step "Generating new CA certificate..."

    # Generate CA private key (ECDSA P-256)
    openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY" 2>/dev/null
    chmod 600 "$CA_KEY"

    # Generate CA certificate (valid for 10 years)
    openssl req -new -x509 -sha256 \
        -key "$CA_KEY" \
        -out "$CA_CERT" \
        -days 3650 \
        -subj "/CN=${CLUSTER_NAME}-ca" \
        2>/dev/null

    # Create marker file with generation timestamp
    date -Iseconds > "${CLUSTER_DATA_DIR}/generated"

    log_pass "CA certificate generated"
    log_info "  Location: $CLUSTER_DATA_DIR"
    openssl x509 -in "$CA_CERT" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
}

# =============================================================================
# Docker Trust Configuration
# =============================================================================

configure_docker_trust() {
    log_step "Configuring Docker to trust cluster CA..."

    # Check if already configured
    if [[ -f "${DOCKER_CERT_DIR}/ca.crt" ]]; then
        # Compare with our CA
        if diff -q "$CA_CERT" "${DOCKER_CERT_DIR}/ca.crt" >/dev/null 2>&1; then
            log_info "  Docker already trusts this CA"
            return 0
        else
            log_warn "  Docker has different CA - will update"
        fi
    fi

    # Create directory and copy cert (requires sudo)
    log_info "  Installing CA to: $DOCKER_CERT_DIR"

    if ! sudo mkdir -p "$DOCKER_CERT_DIR" 2>/dev/null; then
        log_error "  Failed to create directory (need sudo)"
        log_error "  Run: sudo mkdir -p $DOCKER_CERT_DIR"
        return 1
    fi

    if ! sudo cp "$CA_CERT" "${DOCKER_CERT_DIR}/ca.crt" 2>/dev/null; then
        log_error "  Failed to copy CA cert (need sudo)"
        log_error "  Run: sudo cp $CA_CERT ${DOCKER_CERT_DIR}/ca.crt"
        return 1
    fi

    sudo chmod 644 "${DOCKER_CERT_DIR}/ca.crt"

    log_pass "Docker configured to trust cluster CA"
}

# =============================================================================
# Verification
# =============================================================================

verify_setup() {
    log_step "Verifying setup..."

    local errors=0

    # Check CA files exist
    if [[ ! -f "$CA_CERT" ]]; then
        log_error "  CA cert missing: $CA_CERT"
        ((++errors))
    fi

    if [[ ! -f "$CA_KEY" ]]; then
        log_error "  CA key missing: $CA_KEY"
        ((++errors))
    fi

    # Check Docker trust
    if [[ ! -f "${DOCKER_CERT_DIR}/ca.crt" ]]; then
        log_error "  Docker CA missing: ${DOCKER_CERT_DIR}/ca.crt"
        ((++errors))
    fi

    # Verify CA cert is valid
    if ! openssl x509 -in "$CA_CERT" -noout 2>/dev/null; then
        log_error "  CA cert is invalid"
        ((++errors))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Verification failed with $errors error(s)"
        return 1
    fi

    log_pass "Setup verified successfully"
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        usage
    fi

    local config_file="$1"

    echo ""
    echo "=========================================="
    echo "Cluster Host Preparation"
    echo "=========================================="
    echo ""

    load_config "$config_file"

    log_info "Cluster: $CLUSTER_NAME"
    log_info "Docker Registry: $DOCKER_REGISTRY_HOST"
    log_info "Data Directory: $CLUSTER_DATA_DIR"
    echo ""

    generate_ca
    configure_docker_trust
    verify_setup

    echo ""
    echo "=========================================="
    log_pass "Host preparation complete"
    echo "=========================================="
    echo ""
    echo "CA certificate: $CA_CERT"
    echo "CA private key: $CA_KEY"
    echo "Docker trust:   ${DOCKER_CERT_DIR}/ca.crt"
    echo ""
    echo "Next step:"
    echo "  ./scripts/bootstrap.sh $config_file"
    echo ""
}

main "$@"
