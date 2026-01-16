#!/bin/bash
#
# K3s Installation Verification Script
# Purpose: Verify k3s-in-k8s installation works across different Kubernetes distributions
# This script makes NO assumptions about the underlying K8s platform
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
NAMESPACE="${K3S_NAMESPACE:-k3s-test}"
INSTANCE_NAME="${K3S_INSTANCE:-test}"
TIMEOUT="${K3S_TIMEOUT:-300}"

# Track verification results
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

check_result() {
    local check_name="$1"
    local result="$2"
    local details="${3:-}"

    if [ "$result" = "pass" ]; then
        log_success "$check_name"
        ((CHECKS_PASSED++))
    elif [ "$result" = "warn" ]; then
        log_warn "$check_name${details:+ - $details}"
        ((CHECKS_WARNED++))
    else
        log_error "$check_name${details:+ - $details}"
        ((CHECKS_FAILED++))
    fi
}

echo "========================================"
echo " K3s Installation Verification"
echo "========================================"
echo ""

# ============================================================================
# 1. PREREQUISITES VERIFICATION
# ============================================================================
log_info "Step 1: Verifying prerequisites..."

# Check kubectl is available
if command -v kubectl &> /dev/null; then
    check_result "kubectl command available" "pass"
else
    check_result "kubectl command available" "fail" "kubectl not found in PATH"
    exit 1
fi

# Check kubectl can connect to cluster
if kubectl cluster-info &> /dev/null; then
    check_result "kubectl can connect to cluster" "pass"
else
    check_result "kubectl can connect to cluster" "fail" "Cannot connect to Kubernetes cluster"
    exit 1
fi

# Check if namespace exists
if kubectl get namespace "$NAMESPACE" &> /dev/null; then
    check_result "Namespace '$NAMESPACE' exists" "pass"
else
    check_result "Namespace '$NAMESPACE' exists" "fail" "Namespace not found"
fi

echo ""

# ============================================================================
# 2. RESOURCE AVAILABILITY VERIFICATION
# ============================================================================
log_info "Step 2: Verifying cluster resource availability..."

# Get node count
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
check_result "Cluster has nodes" "$([ "$NODE_COUNT" -gt 0 ] && echo pass || echo fail)" "$NODE_COUNT node(s)"

# Check resource allocation
RESOURCE_INFO=$(kubectl describe nodes | grep -A 5 "Allocated resources:" | grep cpu | head -1)
if echo "$RESOURCE_INFO" | grep -q "cpu"; then
    CPU_ALLOCATED=$(echo "$RESOURCE_INFO" | awk '{print $2}' | sed 's/[^0-9]//g')
    CPU_PERCENT=$(echo "$RESOURCE_INFO" | grep -oP '\(\K[0-9]+' || echo "0")

    if [ "$CPU_PERCENT" -lt 80 ]; then
        check_result "CPU resources available" "pass" "${CPU_PERCENT}% allocated"
    elif [ "$CPU_PERCENT" -lt 90 ]; then
        check_result "CPU resources available" "warn" "${CPU_PERCENT}% allocated - may cause scheduling issues"
    else
        check_result "CPU resources available" "fail" "${CPU_PERCENT}% allocated - insufficient for k3s"
    fi
else
    check_result "CPU resources check" "warn" "Could not determine CPU allocation"
fi

# Check for storage classes
STORAGE_CLASSES=$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l)
if [ "$STORAGE_CLASSES" -gt 0 ]; then
    DEFAULT_SC=$(kubectl get storageclasses -o json | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name' | head -1)
    if [ -n "$DEFAULT_SC" ]; then
        check_result "Storage class available" "pass" "Default: $DEFAULT_SC"
    else
        check_result "Storage class available" "warn" "No default storage class defined"
    fi
else
    check_result "Storage class available" "fail" "No storage classes found"
fi

echo ""

# ============================================================================
# 3. K3S DEPLOYMENT VERIFICATION
# ============================================================================
log_info "Step 3: Verifying k3s deployment..."

# Check deployment exists
if kubectl get deployment -n "$NAMESPACE" -l app=k3s,instance="$INSTANCE_NAME" &> /dev/null; then
    DEPLOYMENT_NAME=$(kubectl get deployment -n "$NAMESPACE" -l app=k3s,instance="$INSTANCE_NAME" -o name | head -1 | cut -d/ -f2)
    check_result "K3s deployment exists" "pass" "$DEPLOYMENT_NAME"

    # Check deployment status
    DESIRED=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
    READY=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')

    if [ "${READY:-0}" -eq "$DESIRED" ]; then
        check_result "K3s deployment ready" "pass" "$READY/$DESIRED replicas"
    else
        check_result "K3s deployment ready" "fail" "$READY/$DESIRED replicas ready"
    fi
else
    check_result "K3s deployment exists" "fail" "No deployment found"
    DEPLOYMENT_NAME=""
fi

# Check pod status
if [ -n "$DEPLOYMENT_NAME" ]; then
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=k3s,instance="$INSTANCE_NAME" -o name 2>/dev/null | head -1)

    if [ -n "$POD_NAME" ]; then
        POD_STATUS=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
        POD_READY=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

        if [ "$POD_STATUS" = "Running" ] && [ "$POD_READY" = "True" ]; then
            check_result "K3s pod status" "pass" "Running and Ready"
        elif [ "$POD_STATUS" = "Running" ]; then
            check_result "K3s pod status" "warn" "Running but not Ready"
        elif [ "$POD_STATUS" = "Pending" ]; then
            # Get pending reason
            PENDING_REASON=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}')
            check_result "K3s pod status" "fail" "Pending - $PENDING_REASON"
        else
            check_result "K3s pod status" "fail" "$POD_STATUS"
        fi

        # Check container statuses
        CONTAINERS=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}')
        for container in $CONTAINERS; do
            CONTAINER_READY=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].ready}")
            CONTAINER_STATE=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state}" | jq -r 'keys[0]')

            if [ "$CONTAINER_READY" = "true" ]; then
                check_result "Container '$container' ready" "pass"
            else
                check_result "Container '$container' ready" "fail" "State: $CONTAINER_STATE"
            fi
        done
    else
        check_result "K3s pod exists" "fail" "No pod found"
    fi
fi

echo ""

# ============================================================================
# 4. SERVICE VERIFICATION
# ============================================================================
log_info "Step 4: Verifying k3s services..."

# Check ClusterIP service
if kubectl get service -n "$NAMESPACE" k3s-service &> /dev/null; then
    SERVICE_TYPE=$(kubectl get service k3s-service -n "$NAMESPACE" -o jsonpath='{.spec.type}')
    CLUSTER_IP=$(kubectl get service k3s-service -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
    check_result "K3s ClusterIP service exists" "pass" "$CLUSTER_IP"
else
    check_result "K3s ClusterIP service exists" "fail"
fi

# Check NodePort service (if access method is nodeport)
if kubectl get service -n "$NAMESPACE" k3s-nodeport &> /dev/null; then
    NODEPORT=$(kubectl get service k3s-nodeport -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
    check_result "K3s NodePort service exists" "pass" "Port: $NODEPORT"
else
    check_result "K3s NodePort service exists" "warn" "Not using NodePort access"
fi

echo ""

# ============================================================================
# 5. INGRESS VERIFICATION (if ingress is used)
# ============================================================================
log_info "Step 5: Verifying ingress configuration..."

# Check if ingress controller exists
INGRESS_PODS=$(kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx -o name 2>/dev/null | wc -l)
if [ "$INGRESS_PODS" -eq 0 ]; then
    # Try alternative label
    INGRESS_PODS=$(kubectl get pods -A -l app=nginx-ingress -o name 2>/dev/null | wc -l)
fi
if [ "$INGRESS_PODS" -eq 0 ]; then
    # Try microk8s label
    INGRESS_PODS=$(kubectl get pods -A -l name=nginx-ingress-microk8s -o name 2>/dev/null | wc -l)
fi

if [ "$INGRESS_PODS" -gt 0 ]; then
    check_result "Ingress controller present" "pass" "$INGRESS_PODS pod(s)"
else
    check_result "Ingress controller present" "warn" "No ingress controller detected"
fi

# Check for ingress resources
if kubectl get ingress -n "$NAMESPACE" &> /dev/null; then
    INGRESS_COUNT=$(kubectl get ingress -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$INGRESS_COUNT" -gt 0 ]; then
        check_result "K3s ingress configured" "pass" "$INGRESS_COUNT ingress rule(s)"
    else
        check_result "K3s ingress configured" "warn" "No ingress rules found"
    fi
else
    check_result "K3s ingress configured" "warn" "Not using ingress"
fi

echo ""

# ============================================================================
# 6. K3S CLUSTER HEALTH (if pod is running)
# ============================================================================
if [ -n "${POD_NAME:-}" ] && [ "${POD_READY:-False}" = "True" ]; then
    log_info "Step 6: Verifying internal k3s cluster health..."

    # Check if kubeconfig is available
    if kubectl exec "$POD_NAME" -n "$NAMESPACE" -c k3d -- test -f /output/kubeconfig.yaml 2>/dev/null; then
        check_result "K3s kubeconfig generated" "pass"

        # Try to query the internal k3s cluster
        if kubectl exec "$POD_NAME" -n "$NAMESPACE" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml get nodes &> /dev/null; then
            NODE_STATUS=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -c k3d -- kubectl --kubeconfig=/output/kubeconfig.yaml get nodes --no-headers 2>/dev/null | awk '{print $2}')
            if [ "$NODE_STATUS" = "Ready" ]; then
                check_result "Internal k3s cluster accessible" "pass" "Node status: Ready"
            else
                check_result "Internal k3s cluster accessible" "warn" "Node status: $NODE_STATUS"
            fi
        else
            check_result "Internal k3s cluster accessible" "fail" "Cannot query internal cluster"
        fi
    else
        check_result "K3s kubeconfig generated" "fail" "Kubeconfig not found"
    fi
    echo ""
else
    log_warn "Step 6: Skipping k3s cluster health check (pod not ready)"
    echo ""
fi

# ============================================================================
# 7. CONNECTIVITY TESTS
# ============================================================================
log_info "Step 7: Testing connectivity..."

# Test ClusterIP connectivity (from within cluster)
if [ -n "${CLUSTER_IP:-}" ]; then
    # Try to create a test pod to check connectivity
    log_info "Testing ClusterIP connectivity (requires test pod)..."
    check_result "ClusterIP connectivity test" "warn" "Manual testing required"
fi

# Test NodePort connectivity (if available)
if [ -n "${NODEPORT:-}" ]; then
    # Get node IP
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    if [ -n "$NODE_IP" ]; then
        log_info "NodePort accessible at: $NODE_IP:$NODEPORT"
        check_result "NodePort endpoint identified" "pass" "$NODE_IP:$NODEPORT"
    else
        check_result "NodePort endpoint identified" "warn" "Could not determine node IP"
    fi
fi

echo ""

# ============================================================================
# 8. SECURITY AND BEST PRACTICES
# ============================================================================
log_info "Step 8: Checking security and best practices..."

# Check if privileged containers are used (Docker-in-Docker requires it)
if [ -n "${POD_NAME:-}" ]; then
    PRIVILEGED=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="dind")].securityContext.privileged}')
    if [ "$PRIVILEGED" = "true" ]; then
        check_result "Privileged containers" "warn" "DinD requires privileged mode (expected for k3d)"
    fi

    # Check resource limits are set
    DIND_LIMITS=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="dind")].resources.limits}')
    K3D_LIMITS=$(kubectl get "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="k3d")].resources.limits}')

    if [ -n "$DIND_LIMITS" ] && [ "$DIND_LIMITS" != "{}" ]; then
        check_result "Resource limits defined (dind)" "pass"
    else
        check_result "Resource limits defined (dind)" "warn" "No limits set"
    fi

    if [ -n "$K3D_LIMITS" ] && [ "$K3D_LIMITS" != "{}" ]; then
        check_result "Resource limits defined (k3d)" "pass"
    else
        check_result "Resource limits defined (k3d)" "warn" "No limits set"
    fi
fi

echo ""

# ============================================================================
# SUMMARY
# ============================================================================
echo "========================================"
echo " Verification Summary"
echo "========================================"
echo -e "${GREEN}Passed:${NC}   $CHECKS_PASSED"
echo -e "${YELLOW}Warnings:${NC} $CHECKS_WARNED"
echo -e "${RED}Failed:${NC}   $CHECKS_FAILED"
echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
    if [ $CHECKS_WARNED -eq 0 ]; then
        log_success "All checks passed! K3s installation is healthy."
        exit 0
    else
        log_warn "Installation is functional but has warnings. Review above."
        exit 0
    fi
else
    log_error "Installation verification failed. Please review errors above."
    echo ""
    echo "Common issues and solutions:"
    echo "  - Insufficient CPU: Scale down other workloads or add nodes"
    echo "  - Pod pending: Check 'kubectl describe pod' for detailed reasons"
    echo "  - Storage issues: Ensure a default storage class is configured"
    echo "  - Container not ready: Check logs with 'kubectl logs'"
    exit 1
fi
