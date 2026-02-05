#!/bin/bash
# Build and push Jenkins Agent Image to cluster registry
#
# Builds custom agent with JDK 21, Maven, Docker, CUE and pushes to Nexus.
#
# Usage: ./build-agent-image.sh <config-file>
#
# Example: ./build-agent-image.sh config/clusters/alpha.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source infrastructure config
source "$PROJECT_ROOT/scripts/lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

IMAGE_NAME="jenkins-agent-custom"
IMAGE_TAG="latest"

# Registry URL (external registry, accessed via ingress)
REGISTRY_URL="${DOCKER_REGISTRY_HOST:?DOCKER_REGISTRY_HOST not set}"
PATH_PREFIX="${CONTAINER_REGISTRY_PATH_PREFIX:?CONTAINER_REGISTRY_PATH_PREFIX not set}"
FULL_IMAGE="${REGISTRY_URL}/${PATH_PREFIX}/${IMAGE_NAME}:${IMAGE_TAG}"

# Output helpers
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }
log_warn()  { echo "[!] $*"; }

check_docker() {
    log_step "Checking Docker..."

    if ! command -v docker &> /dev/null; then
        log_fail "Docker is not installed"
        exit 1
    fi

    if ! docker ps &> /dev/null; then
        log_fail "Docker daemon is not running or you don't have permission"
        log_info "Try: sudo usermod -aG docker $USER"
        exit 1
    fi

    log_info "Docker is available"
}

build_image() {
    log_step "Building Jenkins agent image..."

    cd "$SCRIPT_DIR"

    # Build with progress output
    if docker build \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        -f Dockerfile.agent \
        . 2>&1; then
        log_pass "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        log_fail "Failed to build image"
        exit 1
    fi
}

tag_image() {
    log_step "Tagging image for registry..."

    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_IMAGE}"
    log_info "Tagged as: ${FULL_IMAGE}"
}

docker_login() {
    log_step "Authenticating with registry..."

    # Use credentials from environment if available
    local reg_user="${CONTAINER_REGISTRY_USER:-}"
    local reg_pass="${CONTAINER_REGISTRY_PASS:-}"

    if [[ -n "$reg_user" && -n "$reg_pass" ]]; then
        if echo "$reg_pass" | docker login -u "$reg_user" --password-stdin "$REGISTRY_URL" &>/dev/null; then
            log_pass "Authenticated with registry"
            return 0
        fi
    fi

    # Check if already logged in (try a small push to test)
    if docker push "${FULL_IMAGE}" &>/dev/null 2>&1; then
        log_info "Already authenticated"
        return 0
    fi

    # Prompt for credentials
    log_info "Registry credentials required for push"
    echo -n "  Username: "
    read -r reg_user
    echo -n "  Password: "
    read -rs reg_pass
    echo ""

    if echo "$reg_pass" | docker login -u "$reg_user" --password-stdin "$REGISTRY_URL" &>/dev/null; then
        log_pass "Authenticated with registry"
        return 0
    fi

    log_fail "Failed to authenticate with registry"
    return 1
}

push_image() {
    log_step "Pushing image to registry..."
    log_info "Registry: ${REGISTRY_URL}"

    # Push to registry
    if docker push "${FULL_IMAGE}" 2>&1; then
        log_pass "Image pushed: ${FULL_IMAGE}"
    else
        log_fail "Failed to push image"
        log_info "Check registry authentication and accessibility"
        exit 1
    fi
}

verify_image() {
    log_step "Verifying image in registry..."

    # Try to pull the image back to verify
    if docker pull "${FULL_IMAGE}" &>/dev/null; then
        log_pass "Image verified in registry"
    else
        log_warn "Could not verify image (may still be available)"
    fi
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "Jenkins Agent Image Build"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Registry: $REGISTRY_URL"
    log_info "Image: $FULL_IMAGE"
    echo ""

    check_docker
    build_image
    tag_image
    docker_login
    push_image
    verify_image

    echo ""
    echo "=========================================="
    log_pass "Jenkins agent image ready"
    echo "=========================================="
    echo ""
    echo "Image: ${FULL_IMAGE}"
    echo ""
    echo "This image is now available for Jenkins pipelines."
    echo ""
}

main "$@"
