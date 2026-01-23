#!/bin/bash
set -euo pipefail

# Infrastructure Apply Script
# Deploys all CI/CD infrastructure components to a remote microk8s cluster
#
# Usage: ./scripts/apply-infrastructure.sh [env-file]
# Default env-file: env.local

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment configuration
ENV_FILE="${1:-$PROJECT_DIR/env.local}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file $ENV_FILE not found"
    echo "Copy env.example to env.local and configure it first"
    exit 1
fi

echo "Loading configuration from $ENV_FILE"
set -a
source "$ENV_FILE"
set +a

# Validate required variables
REQUIRED_VARS=(GITLAB_HOST JENKINS_HOST NEXUS_HOST ARGOCD_HOST STORAGE_CLASS REMOTE_HOST REMOTE_USER)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable $var is not set in $ENV_FILE"
        exit 1
    fi
done

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
# ArgoCD uses the upstream manifest directly
echo "Applying ArgoCD from upstream..."
ssh "$REMOTE_USER@$REMOTE_HOST" \
    "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml" || {
    # If upstream fails, try local copy
    echo "Upstream failed, trying local copy..."
    if [[ -f "$PROJECT_DIR/k8s/argocd/install.yaml" ]]; then
        scp "$PROJECT_DIR/k8s/argocd/install.yaml" "$REMOTE_USER@$REMOTE_HOST:/tmp/"
        ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl apply -n argocd -f /tmp/install.yaml"
    fi
}
apply_manifest "$PROJECT_DIR/k8s/argocd/ingress.yaml" "ArgoCD Ingress"

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Waiting for all pods to be ready..."

# Wait for critical pods
wait_for_pods "gitlab" "app=gitlab" 300
wait_for_pods "nexus" "app=nexus" 180
wait_for_pods "jenkins" "app=jenkins" 180
wait_for_pods "argocd" "app.kubernetes.io/name=argocd-server" 180

echo ""
echo "=== Infrastructure Status ==="
ssh "$REMOTE_USER@$REMOTE_HOST" "kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd|cert-manager'"

echo ""
echo "=== Next Steps ==="
echo "1. Add hosts entries to /etc/hosts:"
echo "   $(ssh "$REMOTE_USER@$REMOTE_HOST" "hostname -I | awk '{print \$1}'") $GITLAB_HOST $JENKINS_HOST $NEXUS_HOST $ARGOCD_HOST"
echo ""
echo "2. Run verification: ./scripts/verify-phase1.sh"
