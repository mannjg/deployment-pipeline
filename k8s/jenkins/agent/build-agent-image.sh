#!/bin/bash
set -euo pipefail

# Build Jenkins Agent Image
# Builds custom agent with JDK 21, Maven, Docker, CUE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="jenkins-agent-custom"
IMAGE_TAG="latest"

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

check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi

    if ! docker ps &> /dev/null; then
        log_error "Docker daemon is not running or you don't have permission"
        log_info "Try: sudo usermod -aG docker $USER"
        exit 1
    fi

    log_info "Docker check passed"
}

build_image() {
    log_info "Building Jenkins agent image..."

    cd "$SCRIPT_DIR"

    docker build \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        -f Dockerfile.agent \
        . \
        2>&1 | tee build.log

    log_info "Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
}

import_to_microk8s() {
    log_info "Importing image to MicroK8s..."

    if ! command -v microk8s &> /dev/null; then
        log_warn "MicroK8s not found, skipping import"
        log_info "You can manually import with: docker save ${IMAGE_NAME}:${IMAGE_TAG} | microk8s ctr image import -"
        return 0
    fi

    # Save and import to MicroK8s
    docker save "${IMAGE_NAME}:${IMAGE_TAG}" | microk8s ctr image import -

    log_info "Image imported to MicroK8s"

    # Verify
    microk8s ctr images ls | grep "${IMAGE_NAME}" || log_warn "Image not found in MicroK8s"
}

tag_for_nexus() {
    log_info "Tagging image for Nexus registry..."

    # Tag for Nexus (will be used later when Nexus is deployed)
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "nexus.local:5000/${IMAGE_NAME}:${IMAGE_TAG}"

    log_info "Tagged as: nexus.local:5000/${IMAGE_NAME}:${IMAGE_TAG}"
    log_warn "Push to Nexus later with: docker push nexus.local:5000/${IMAGE_NAME}:${IMAGE_TAG}"
}

print_summary() {
    echo ""
    echo "========================================="
    log_info "Jenkins Agent Image Build Complete!"
    echo "========================================="
    echo ""
    echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
    echo ""
    echo "Includes:"
    echo "  - OpenJDK 21"
    echo "  - Maven 3.9.6"
    echo "  - Docker CLI"
    echo "  - CUE CLI (v0.14.2)"
    echo "  - kubectl"
    echo ""
    echo "Build log: $SCRIPT_DIR/build.log"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy Jenkins with custom agent image"
    echo "  2. After Nexus is deployed, push image:"
    echo "     docker push nexus.local:5000/${IMAGE_NAME}:${IMAGE_TAG}"
    echo ""
}

main() {
    log_info "Starting Jenkins agent image build..."

    check_docker
    build_image
    import_to_microk8s
    tag_for_nexus
    print_summary
}

main "$@"
