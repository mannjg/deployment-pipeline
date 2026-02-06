#!/bin/bash
# Setup ArgoCD applications for all apps in all environments
#
# Usage: ./scripts/03-pipelines/setup-argocd-applications.sh <config-file>
#
# Creates ArgoCD Application resources for dev, stage, and prod environments
# pointing to the k8s-deployments repo branches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load infrastructure config
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"
source "$SCRIPT_DIR/../lib/logging.sh"

log_header "ArgoCD Application Setup"
log_info "Namespace: $ARGOCD_NAMESPACE"
log_info "GitLab: $GITLAB_URL_EXTERNAL"
log_info "Repo: $DEPLOYMENTS_REPO_PATH"
echo ""

# Create applications for each environment
for env in dev stage prod; do
    app_name="example-app-${env}"
    target_ns="${env}"

    # Use cluster-specific namespace if defined
    case $env in
        dev)   target_ns="${DEV_NAMESPACE:-dev}" ;;
        stage) target_ns="${STAGE_NAMESPACE:-stage}" ;;
        prod)  target_ns="${PROD_NAMESPACE:-prod}" ;;
    esac

    log_step "Creating ArgoCD application: $app_name"
    log_info "  Target namespace: $target_ns"
    log_info "  Source branch: $env"

    # Check if application already exists
    if kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_info "  Application already exists, updating..."
    fi

    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git
    targetRevision: ${env}
    path: manifests/exampleApp
  destination:
    server: https://kubernetes.default.svc
    namespace: ${target_ns}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

    log_pass "Created/updated $app_name"
done

# Create postgres applications for each environment
echo ""
log_step "Creating postgres ArgoCD applications..."
for env in dev stage prod; do
    app_name="postgres-${env}"
    target_ns="${env}"

    # Use cluster-specific namespace if defined
    case $env in
        dev)   target_ns="${DEV_NAMESPACE:-dev}" ;;
        stage) target_ns="${STAGE_NAMESPACE:-stage}" ;;
        prod)  target_ns="${PROD_NAMESPACE:-prod}" ;;
    esac

    log_step "Creating ArgoCD application: $app_name"
    log_info "  Target namespace: $target_ns"
    log_info "  Source branch: $env"

    # Check if application already exists
    if kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_info "  Application already exists, updating..."
    fi

    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    app: postgres
    environment: ${env}
spec:
  project: default
  source:
    repoURL: ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git
    targetRevision: ${env}
    path: manifests/postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: ${target_ns}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - PruneLast=true
EOF

    log_pass "Created/updated $app_name"
done

echo ""
log_header "ArgoCD Applications Ready"
echo ""
echo "Applications created:"
kubectl get applications -n "$ARGOCD_NAMESPACE" -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || true
echo ""
