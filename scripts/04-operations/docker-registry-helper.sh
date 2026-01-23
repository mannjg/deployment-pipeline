#!/bin/bash
set -euo pipefail

# Docker Registry Helper Script
# Provides easy access to Nexus Docker registry

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
${BLUE}Nexus Docker Registry Helper${NC}

Usage: $0 [command]

Commands:
    login               Login to Docker registry
    logout              Logout from Docker registry
    status              Check registry status
    forward             Start port-forward (localhost:5000)
    stop-forward        Stop port-forward
    test                Test registry connectivity
    push <image>        Push image to registry
    help                Show this help

Registry Access:
    From Host:       localhost:30500 (NodePort - persistent)
    From Host (alt): localhost:5000 (port-forward - temporary)
    From Cluster:    nexus.local:5000 (internal)

Credentials:
    Username: admin
    Password: admin123
EOF
}

login_registry() {
    log_info "Logging into Docker registry..."

    # Try NodePort first (persistent)
    if echo "admin123" | docker login localhost:30500 -u admin --password-stdin 2>/dev/null; then
        log_info "✓ Logged in via NodePort (localhost:30500)"
        return 0
    fi

    # Try port-forward
    if echo "admin123" | docker login localhost:5000 -u admin --password-stdin 2>/dev/null; then
        log_info "✓ Logged in via port-forward (localhost:5000)"
        return 0
    fi

    log_error "Failed to login. Is the registry accessible?"
    log_warn "Try: $0 forward"
    return 1
}

logout_registry() {
    docker logout localhost:30500 2>/dev/null || true
    docker logout localhost:5000 2>/dev/null || true
    log_info "Logged out from Docker registry"
}

check_status() {
    log_info "Checking Nexus Docker registry status..."

    # Check Nexus pod
    if kubectl get pods -n nexus -l app=nexus | grep -q "Running"; then
        log_info "✓ Nexus pod is running"
    else
        log_error "✗ Nexus pod is not running"
        return 1
    fi

    # Check services
    log_info "Services:"
    kubectl get svc -n nexus

    # Check NodePort connectivity
    if curl -sf http://localhost:30500/v2/ > /dev/null 2>&1; then
        log_info "✓ NodePort registry is accessible (localhost:30500)"
    else
        log_warn "✗ NodePort registry not accessible"
    fi

    # Check port-forward connectivity
    if curl -sf http://localhost:5000/v2/ > /dev/null 2>&1; then
        log_info "✓ Port-forward registry is accessible (localhost:5000)"
    else
        log_warn "✗ Port-forward not active"
        log_info "Run: $0 forward"
    fi
}

start_forward() {
    # Check if already running
    if pgrep -f "kubectl port-forward.*nexus.*5000:5000" > /dev/null; then
        log_warn "Port-forward already running"
        return 0
    fi

    log_info "Starting port-forward on localhost:5000..."
    kubectl port-forward -n nexus svc/nexus 5000:5000 > /dev/null 2>&1 &

    sleep 2

    if curl -sf http://localhost:5000/v2/ > /dev/null 2>&1; then
        log_info "✓ Port-forward active on localhost:5000"
        log_info "Process ID: $(pgrep -f 'kubectl port-forward.*nexus.*5000:5000')"
    else
        log_error "Port-forward failed to start"
        return 1
    fi
}

stop_forward() {
    local pid=$(pgrep -f "kubectl port-forward.*nexus.*5000:5000" || true)

    if [ -z "$pid" ]; then
        log_warn "No port-forward process found"
        return 0
    fi

    kill $pid
    log_info "✓ Port-forward stopped"
}

test_registry() {
    log_info "Testing Docker registry connectivity..."

    # Test NodePort
    echo ""
    log_info "Testing NodePort (localhost:30500)..."
    if curl -sf http://localhost:30500/v2/ > /dev/null 2>&1; then
        log_info "✓ NodePort: OK"
    else
        log_error "✗ NodePort: FAILED"
    fi

    # Test port-forward
    echo ""
    log_info "Testing port-forward (localhost:5000)..."
    if curl -sf http://localhost:5000/v2/ > /dev/null 2>&1; then
        log_info "✓ Port-forward: OK"
    else
        log_warn "✗ Port-forward: Not active (run: $0 forward)"
    fi

    # Test from cluster
    echo ""
    log_info "Testing from inside cluster (nexus.local:5000)..."
    kubectl run -n nexus test-registry --rm -i --restart=Never \
        --image=curlimages/curl:latest \
        -- curl -sf http://nexus.nexus.svc.cluster.local:5000/v2/ && \
        log_info "✓ Cluster internal: OK" || \
        log_error "✗ Cluster internal: FAILED"
}

push_image() {
    local image=$1

    if [ -z "$image" ]; then
        log_error "Usage: $0 push <image>"
        return 1
    fi

    log_info "Pushing image: $image"

    # Tag for NodePort
    local nexus_image="localhost:30500/${image#*/}"
    docker tag "$image" "$nexus_image"

    log_info "Tagged as: $nexus_image"
    log_info "Pushing..."

    docker push "$nexus_image"

    log_info "✓ Image pushed successfully"
    log_info "Pull from cluster: nexus.local:5000/${image#*/}"
}

main() {
    case "${1:-help}" in
        login)
            login_registry
            ;;
        logout)
            logout_registry
            ;;
        status)
            check_status
            ;;
        forward)
            start_forward
            ;;
        stop-forward)
            stop_forward
            ;;
        test)
            test_registry
            ;;
        push)
            push_image "${2:-}"
            ;;
        help|*)
            show_help
            ;;
    esac
}

main "$@"
