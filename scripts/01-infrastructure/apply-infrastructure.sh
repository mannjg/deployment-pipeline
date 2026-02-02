#!/bin/bash
set -euo pipefail

# Infrastructure Apply Script
# Deploys all CI/CD infrastructure components to a remote microk8s cluster
#
# Usage: ./scripts/apply-infrastructure.sh <config-file>
#    Or: export CLUSTER_CONFIG=<config-file>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load cluster configuration
# Accept config file as argument or from CLUSTER_CONFIG env var
CONFIG_FILE="${1:-${CLUSTER_CONFIG:-}}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Cluster config file required"
    echo "Usage: $0 <config-file>"
    echo "   Or: export CLUSTER_CONFIG=<config-file>"
    exit 1
fi

echo "Loading configuration from $CONFIG_FILE"
set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a
export CLUSTER_CONFIG="$CONFIG_FILE"

# Validate required variables for remote deployment
REQUIRED_VARS=(GITLAB_NAMESPACE JENKINS_NAMESPACE NEXUS_NAMESPACE ARGOCD_NAMESPACE STORAGE_CLASS REMOTE_HOST REMOTE_USER)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable $var is not set in $CONFIG_FILE"
        exit 1
    fi
done

# For backwards compatibility, support old variable names if new ones not set
GITLAB_HOST="${GITLAB_HOST_EXTERNAL:-${GITLAB_HOST:-}}"
JENKINS_HOST="${JENKINS_HOST_EXTERNAL:-${JENKINS_HOST:-}}"
NEXUS_HOST="${NEXUS_HOST_EXTERNAL:-${NEXUS_HOST:-}}"
ARGOCD_HOST="${ARGOCD_HOST_EXTERNAL:-${ARGOCD_HOST:-}}"

echo "=== Infrastructure Deployment ==="
echo "Target: $REMOTE_USER@$REMOTE_HOST"
echo "GitLab:  https://$GITLAB_HOST"
echo "Jenkins: https://$JENKINS_HOST"
echo "Nexus:   https://$NEXUS_HOST"
echo "ArgoCD:  https://$ARGOCD_HOST"
echo ""

# Function to apply a manifest with envsubst
apply_manifest() {
    local manifest="$1"
    local description="${2:-$manifest}"

    echo "Applying $description..."
    envsubst < "$manifest" | ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl apply -f -"
}

# Function to wait for pods
wait_for_pods() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-300}"

    echo "Waiting for pods in $namespace with label $label..."
    ssh "$REMOTE_USER@$REMOTE_HOST" \
        "kubectl wait --for=condition=ready pod -l $label -n $namespace --timeout=${timeout}s" || {
        echo "Warning: Pods not ready within timeout, continuing..."
    }
}

# 1. cert-manager (if not already installed)
echo ""
echo "=== Step 1: cert-manager ==="
if ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl get namespace cert-manager" &>/dev/null; then
    echo "cert-manager namespace exists, checking pods..."
    if ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl get pods -n cert-manager -l app.kubernetes.io/instance=cert-manager" 2>/dev/null | grep -q Running; then
        echo "cert-manager already running, skipping..."
    else
        echo "Applying cert-manager..."
        scp "$PROJECT_DIR/k8s/cert-manager/cert-manager.yaml" "$REMOTE_USER@$REMOTE_HOST:/tmp/"
        ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl apply -f /tmp/cert-manager.yaml"
        wait_for_pods "cert-manager" "app.kubernetes.io/instance=cert-manager" 120
    fi
else
    echo "Applying cert-manager..."
    scp "$PROJECT_DIR/k8s/cert-manager/cert-manager.yaml" "$REMOTE_USER@$REMOTE_HOST:/tmp/"
    ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl apply -f /tmp/cert-manager.yaml"
    wait_for_pods "cert-manager" "app.kubernetes.io/instance=cert-manager" 120
fi

# Apply cluster issuers
echo "Applying ClusterIssuers..."
apply_manifest "$PROJECT_DIR/k8s/cert-manager/cluster-issuer.yaml" "ClusterIssuers"

# 2. GitLab
echo ""
echo "=== Step 2: GitLab ==="
apply_manifest "$PROJECT_DIR/k8s/gitlab/gitlab-lightweight.yaml" "GitLab"
echo "GitLab deployment started (takes 3-5 minutes to be ready)"

# 3. Nexus
echo ""
echo "=== Step 3: Nexus ==="
apply_manifest "$PROJECT_DIR/k8s/nexus/nexus-lightweight.yaml" "Nexus"

# 4. Jenkins
echo ""
echo "=== Step 4: Jenkins ==="
apply_manifest "$PROJECT_DIR/k8s/jenkins/jenkins-lightweight.yaml" "Jenkins"

# 5. ArgoCD
echo ""
echo "=== Step 5: ArgoCD ==="
# Ensure ArgoCD namespace exists
ssh "$REMOTE_USER@$REMOTE_HOST" \
    "kubectl get namespace $ARGOCD_NAMESPACE &>/dev/null || kubectl create namespace $ARGOCD_NAMESPACE"
# ArgoCD uses the upstream manifest directly
echo "Applying ArgoCD from upstream..."
ssh "$REMOTE_USER@$REMOTE_HOST" \
    "kubectl apply -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml" || {
    # If upstream fails, try local copy
    echo "Upstream failed, trying local copy..."
    if [[ -f "$PROJECT_DIR/k8s/argocd/install.yaml" ]]; then
        scp "$PROJECT_DIR/k8s/argocd/install.yaml" "$REMOTE_USER@$REMOTE_HOST:/tmp/"
        ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl apply -n $ARGOCD_NAMESPACE -f /tmp/install.yaml"
    fi
}
apply_manifest "$PROJECT_DIR/k8s/argocd/ingress.yaml" "ArgoCD Ingress"

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Waiting for all pods to be ready..."

# Wait for critical pods
wait_for_pods "$GITLAB_NAMESPACE" "app=gitlab" 300
wait_for_pods "$NEXUS_NAMESPACE" "app=nexus" 180
wait_for_pods "$JENKINS_NAMESPACE" "app=jenkins" 180
wait_for_pods "$ARGOCD_NAMESPACE" "app.kubernetes.io/name=argocd-server" 180

echo ""
echo "=== Infrastructure Status ==="
ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd|cert-manager'"

echo ""
echo "=== Next Steps ==="
echo "1. Add hosts entries to /etc/hosts:"
echo "   $(ssh "$REMOTE_USER@$REMOTE_HOST" "hostname -I | awk '{print \$1}'") $GITLAB_HOST $JENKINS_HOST $NEXUS_HOST $ARGOCD_HOST"
echo ""
echo "2. Run verification: ./scripts/verify-phase1.sh"
