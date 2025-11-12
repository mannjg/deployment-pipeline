# K3s Nested Installer - Installation Analysis & Recommendations

**Date**: 2025-11-10
**Cluster**: microk8s on ubuntu-dev
**Installer Location**: ~/git/mannjg/k3s-nested-installer/install.sh

## Executive Summary

The k3s-nested-installer successfully deploys k8s resources (pods, services, ingress) but **the internal k3s cluster fails to start** due to version compatibility issues. The pod reports as "ready" while the actual k3s cluster inside never initializes, demonstrating a critical gap between reported status and actual functionality.

## Installation Attempt Results

### What Worked ✅
1. **Resource deployment**: All Kubernetes manifests applied successfully
2. **Pod scheduling**: Pod scheduled and started after freeing resources
3. **Ingress configuration**: Ingress rules created with correct annotations
4. **Container startup**: Both dind and k3d containers started
5. **Readiness probe passed**: Pod reported as 2/2 Ready

### What Failed ❌
1. **K3s cluster creation**: Failed due to incompatible k3d CLI flags
2. **Kubeconfig generation**: Empty kubeconfig file (0 bytes)
3. **Internal cluster accessibility**: Cannot connect to inner k3s API
4. **Silent failure**: No obvious indication that cluster creation failed

## Root Cause Analysis

### 1. Version Compatibility Issue (CRITICAL)

**Problem**: install.sh:401 uses `--k3s-image` flag which doesn't exist in k3d v5+

```bash
# Current code (install.sh line 388-401)
k3d cluster create ${INSTANCE_NAME} \
  --api-port 0.0.0.0:6443 \
  --servers 1 \
  --agents 0 \
  --wait \
  --timeout 5m \
  --k3s-arg "--tls-san=${INSTANCE_NAME}@server:0" \
  ...
  --k3s-image=rancher/k3s:${K3S_VERSION}  # ❌ This flag doesn't exist in v5
```

**Error observed**:
```
time="2025-11-10T13:43:34Z" level=fatal msg="unknown flag: --k3s-image"
```

**K3d version detected**: v5-dev

**Fix required**: Change `--k3s-image` to `--image` for k3d v5+ compatibility

### 2. Inadequate Health Checks

**Problem**: Readiness probe only checks file existence, not cluster health

```yaml
# Current readiness probe (install.sh line 425-433)
readinessProbe:
  exec:
    command:
    - sh
    - -c
    - test -f /output/kubeconfig.yaml
  initialDelaySeconds: 60
  periodSeconds: 10
  timeoutSeconds: 5
```

**Issue**: The kubeconfig file is created (even if empty) before cluster creation fails, so the probe passes even though the cluster never starts.

**Recommendation**: Check cluster health, not just file existence:
```yaml
readinessProbe:
  exec:
    command:
    - sh
    - -c
    - kubectl --kubeconfig=/output/kubeconfig.yaml get nodes 2>/dev/null | grep -q Ready
```

### 3. Resource Constraints (RESOLVED)

**Initial Problem**: Cluster had insufficient CPU for default resource requests

- **Before**: 3450m CPU allocated (86% of ~4 CPUs)
- **Pod requires**: 750m CPU minimum (500m dind + 250m k3d)
- **Solution**: Scaled down dev/stage/prod deployments
- **After**: 2350m CPU allocated (58%), sufficient for k3s pod

**Resource requests used**:
```bash
--cpu-request 0.25 --cpu-limit 1 \
--memory-request 1Gi --memory-limit 2Gi
```

**Note**: dind container has hardcoded 500m CPU request (install.sh:373-374)

### 4. Hardcoded Resource Limits

**Problem**: dind container resources are hardcoded in deployment generation

```yaml
# install.sh lines 368-374 (hardcoded, not parameterized)
resources:
  limits:
    cpu: "1"
    memory: 2Gi
  requests:
    cpu: "500m"
    memory: 1Gi
```

Only the k3d container uses the configurable `CPU_REQUEST`/`CPU_LIMIT` variables.

**Impact**: Even with `--cpu-request 0.1`, total CPU request is still 0.6 (0.5 dind + 0.1 k3d)

## Portability Issues Found

### 1. **Assumptions About External Dependencies**
- ❌ Assumes specific k3d version/API
- ❌ No version detection or compatibility checks
- ❌ Uses `:latest` image tag (unpredictable)

### 2. **Resource Assumptions**
- ❌ Default resources too high for constrained environments (1.5 CPU request)
- ❌ No automatic resource detection or adjustment
- ❌ Partial parameterization (only k3d container, not dind)

### 3. **Validation Gaps**
- ❌ Readiness probe doesn't verify cluster is functional
- ❌ No post-deployment validation
- ❌ Script reports success when cluster creation fails

### 4. **Platform-Specific Patterns**
- ✅ Storage class is parameterized (good!)
- ✅ Ingress class is configurable (good!)
- ⚠️  Ingress requires SSL passthrough (not all ingress controllers support this)

## Recommendations

### Immediate Fixes

#### 1. Fix k3d v5 Compatibility
```bash
# Replace line 401 in install.sh
# OLD: --k3s-image=rancher/k3s:${K3S_VERSION}
# NEW: --image=rancher/k3s:${K3S_VERSION}
```

#### 2. Pin k3d Version
```yaml
# Replace line 381 in install.sh
# OLD: image: ghcr.io/k3d-io/k3d:latest
# NEW: image: ghcr.io/k3d-io/k3d:v5.7.5  # or specific stable version
```

#### 3. Improve Readiness Probe
```yaml
readinessProbe:
  exec:
    command:
    - sh
    - -c
    - |
      test -f /output/kubeconfig.yaml && \
      kubectl --kubeconfig=/output/kubeconfig.yaml get nodes 2>/dev/null | grep -q Ready
  initialDelaySeconds: 90  # Increased to allow cluster startup
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

#### 4. Make dind Resources Configurable
Add parameters:
```bash
DIND_CPU_REQUEST="${DIND_CPU_REQUEST:-500m}"
DIND_CPU_LIMIT="${DIND_CPU_LIMIT:-1}"
DIND_MEMORY_REQUEST="${DIND_MEMORY_REQUEST:-1Gi}"
DIND_MEMORY_LIMIT="${DIND_MEMORY_LIMIT:-2Gi}"
```

### Enhanced Portability

#### 1. Add Version Detection
```bash
check_k3d_compatibility() {
    # Detect k3d version and adjust flags accordingly
    kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- k3d version | grep -q "v5"
    if [ $? -eq 0 ]; then
        K3S_IMAGE_FLAG="--image"
    else
        K3S_IMAGE_FLAG="--k3s-image"
    fi
}
```

#### 2. Add Resource Detection
```bash
check_available_resources() {
    local cpu_percent=$(kubectl describe nodes | grep "cpu.*%" | awk '{print $2}' | tr -d '()%')
    if [ "$cpu_percent" -gt 80 ]; then
        warn "Cluster CPU utilization is ${cpu_percent}%. Consider reducing resource requests."
        # Optionally adjust defaults
    fi
}
```

#### 3. Add Post-Deployment Validation
```bash
validate_deployment() {
    log "Validating internal k3s cluster..."

    local max_wait=120
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        if kubectl exec -n "$NAMESPACE" "$POD_NAME" -c k3d -- \
           kubectl --kubeconfig=/output/kubeconfig.yaml get nodes 2>/dev/null | grep -q Ready; then
            success "Internal k3s cluster is healthy"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    error "Internal k3s cluster did not become healthy"
    kubectl logs -n "$NAMESPACE" "$POD_NAME" -c k3d --tail=50
    return 1
}
```

#### 4. Add Ingress Controller Detection
```bash
detect_ingress_capabilities() {
    # Check if ingress controller supports SSL passthrough
    local ingress_controller=$(kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx -o name | head -1)

    if [ -n "$ingress_controller" ]; then
        # Check for SSL passthrough support
        if kubectl exec -n ingress-nginx "$ingress_controller" -- \
           /nginx-ingress-controller --help 2>/dev/null | grep -q "enable-ssl-passthrough"; then
            log "Ingress controller supports SSL passthrough"
        else
            warn "Ingress controller may not support SSL passthrough. Consider using NodePort or LoadBalancer."
        fi
    fi
}
```

### Architecture Recommendations

#### 1. Resource Presets
Create environment-specific presets:

```bash
# examples/presets/minimal.yaml
cpu_request: "100m"
cpu_limit: "500m"
memory_request: "512Mi"
memory_limit: "1Gi"
dind_cpu_request: "250m"
dind_cpu_limit: "500m"

# examples/presets/standard.yaml
cpu_request: "250m"
cpu_limit: "1"
memory_request: "1Gi"
memory_limit: "2Gi"
dind_cpu_request: "500m"
dind_cpu_limit: "1"

# examples/presets/performance.yaml
cpu_request: "1"
cpu_limit: "2"
memory_request: "2Gi"
memory_limit: "4Gi"
dind_cpu_request: "1"
dind_cpu_limit: "2"
```

Usage:
```bash
./install.sh --name dev --preset minimal
```

#### 2. Pre-flight Checks
Add comprehensive pre-flight validation:

```bash
preflight_checks() {
    log "Running pre-flight checks..."

    # Check 1: Cluster resources
    check_available_resources || return 1

    # Check 2: Storage class
    check_storage_class || return 1

    # Check 3: Ingress capabilities (if using ingress)
    if [ "$ACCESS_METHOD" = "ingress" ]; then
        check_ingress_controller || return 1
    fi

    # Check 4: Network policies (if any)
    check_network_policies || return 1

    # Check 5: Privileged containers allowed
    check_privileged_pods || return 1

    success "Pre-flight checks passed"
}
```

#### 3. Better Error Reporting
```bash
diagnose_failure() {
    error "Deployment failed. Gathering diagnostics..."

    echo "=== Pod Status ==="
    kubectl get pods -n "$NAMESPACE" -o wide

    echo "=== Pod Events ==="
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp'

    echo "=== Container Logs (dind) ==="
    kubectl logs -n "$NAMESPACE" "$POD_NAME" -c dind --tail=50

    echo "=== Container Logs (k3d) ==="
    kubectl logs -n "$NAMESPACE" "$POD_NAME" -c k3d --tail=50

    echo "=== Node Resources ==="
    kubectl describe nodes | grep -A 10 "Allocated resources"
}
```

## Testing Checklist for Portability

- [ ] Test on different Kubernetes distributions:
  - [ ] microk8s (current)
  - [ ] k3s
  - [ ] kind
  - [ ] minikube
  - [ ] EKS
  - [ ] GKE
  - [ ] AKS

- [ ] Test with different resource constraints:
  - [ ] Single-node cluster with limited CPU
  - [ ] Multi-node cluster
  - [ ] Cluster with high existing load

- [ ] Test with different ingress controllers:
  - [ ] nginx-ingress (current)
  - [ ] traefik
  - [ ] HAProxy
  - [ ] AWS ALB
  - [ ] GCP Load Balancer

- [ ] Test with different storage classes:
  - [ ] hostpath (current)
  - [ ] local-path
  - [ ] NFS
  - [ ] Cloud provider storage (EBS, GCE PD, Azure Disk)

- [ ] Test version compatibility:
  - [ ] k3d v4.x
  - [ ] k3d v5.x (current - failing)
  - [ ] Different k3s versions

## Verification Evidence

### Current State (Evidence-Based)

**Pod Status**:
```
NAME                   READY   STATUS    RESTARTS   AGE
k3s-6768bb6cc5-gvnpw   2/2     Running   0          87s
```
- ✅ Pod is scheduled
- ✅ Both containers started
- ✅ Readiness probe passed
- ❌ Internal cluster not functional

**Ingress Configuration**:
```yaml
Name:             k3s-ingress
Namespace:        k3s-test
Address:          127.0.0.1
Ingress Class:    public
Host:             k3s-test.local
Path:             / → k3s-service:6443
Annotations:
  nginx.ingress.kubernetes.io/backend-protocol: HTTPS
  nginx.ingress.kubernetes.io/ssl-passthrough: true
```
- ✅ Ingress created
- ✅ Rules configured
- ✅ SSL passthrough enabled
- ❌ Backend service has no healthy endpoints

**K3d Error Log**:
```
time="2025-11-10T13:43:34Z" level=fatal msg="unknown flag: --k3s-image"
ERRO[0000] Failed to get nodes for cluster 'test': docker failed to get containers
FATA[0000] No nodes found for given cluster
```
- ❌ Cluster creation failed
- ❌ Flag incompatibility confirmed
- ❌ No k3s nodes created

**Kubeconfig Status**:
```
-rw-rw-rw- 1 root root 0 Nov 10 08:44 k3s-test.yaml
```
- ❌ File exists but is empty (0 bytes)
- ❌ Cannot connect to internal cluster

**Resource Allocation**:
```
Before scaling down: 3450m CPU (86%)
After scaling down:  2350m CPU (58%)
Available:          ~1650m CPU
K3s pod requires:    750m CPU (500m dind + 250m k3d)
```
- ✅ Sufficient resources available after optimization

## Conclusion

The k3s-nested-installer has good structure and handles many portability concerns well (parameterized storage class, configurable ingress), but fails due to:

1. **Version assumptions** - Hardcoded k3d API that changed between versions
2. **Incomplete validation** - Reports success when core functionality fails
3. **Partial parameterization** - Some resources configurable, others hardcoded

The installation **appears to succeed** but **does not work**. This is more dangerous than an obvious failure because it's not immediately apparent that the system is non-functional.

### Recommended Action Plan

1. **Immediate** (blocks current functionality):
   - Fix k3d v5 flag compatibility
   - Pin k3d version to avoid future breakage

2. **Short-term** (improves reliability):
   - Improve readiness probe to verify cluster health
   - Add post-deployment validation
   - Make all resources configurable

3. **Medium-term** (improves portability):
   - Add version detection and compatibility layer
   - Create resource presets for different environments
   - Add comprehensive pre-flight checks

4. **Long-term** (production readiness):
   - Test across multiple K8s distributions
   - Add automated compatibility testing
   - Create troubleshooting runbooks

## Files Created

1. **verify-k3s-installation.sh**: Portable verification script (deployment-pipeline/)
2. **K3S_INSTALLATION_ANALYSIS.md**: This comprehensive analysis (deployment-pipeline/)

Both files use only standard kubectl commands and make no assumptions about the underlying Kubernetes platform.
