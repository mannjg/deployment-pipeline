#!/bin/bash
set -euo pipefail

# GitLab Setup Script
# Deploys GitLab Community Edition using Helm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v helm &> /dev/null; then
        log_error "Helm is not installed. Please run setup-all.sh first"
        exit 1
    fi

    if ! kubectl get namespace gitlab &> /dev/null; then
        log_warn "GitLab namespace doesn't exist. Creating..."
        kubectl create namespace gitlab
    fi

    log_info "Prerequisites check passed"
}

add_helm_repo() {
    log_info "Adding GitLab Helm repository..."

    helm repo add gitlab https://charts.gitlab.io/
    helm repo update

    log_info "GitLab Helm repository added"
}

deploy_gitlab() {
    log_info "Deploying GitLab..."

    # Use lightweight deployment by default
    USE_LIGHTWEIGHT="${USE_LIGHTWEIGHT:-true}"

    if [[ "$USE_LIGHTWEIGHT" == "true" ]]; then
        log_info "Using lightweight GitLab deployment"

        # Check if already deployed
        if kubectl get deployment -n gitlab gitlab &> /dev/null; then
            log_warn "GitLab is already deployed"
            read -p "Do you want to redeploy? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Deleting existing GitLab deployment..."
                kubectl delete -f "$PROJECT_ROOT/k8s/gitlab/gitlab-lightweight.yaml" || true
                sleep 10
            else
                log_info "Skipping deployment"
                return 0
            fi
        fi

        log_info "Deploying GitLab (this may take several minutes)..."
        kubectl apply -f "$PROJECT_ROOT/k8s/gitlab/gitlab-lightweight.yaml"
    else
        # Use Helm deployment
        log_info "Using Helm-based GitLab deployment"

        if helm list -n gitlab | grep -q "gitlab"; then
            log_warn "GitLab is already deployed"
            read -p "Do you want to upgrade? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Upgrading GitLab..."
                helm upgrade gitlab gitlab/gitlab \
                    -n gitlab \
                    -f "$PROJECT_ROOT/k8s/gitlab/values.yaml" \
                    --timeout=600s
            else
                log_info "Skipping deployment"
                return 0
            fi
        else
            log_info "Installing GitLab (this may take several minutes)..."
            helm install gitlab gitlab/gitlab \
                -n gitlab \
                -f "$PROJECT_ROOT/k8s/gitlab/values.yaml" \
                --timeout=600s \
                --wait
        fi
    fi

    log_info "GitLab deployed successfully"
}

wait_for_gitlab() {
    log_info "Waiting for GitLab to be ready (this can take 5-10 minutes)..."

    if [[ "$USE_LIGHTWEIGHT" == "true" ]]; then
        # Wait for lightweight deployment
        log_info "Waiting for GitLab pod..."
        kubectl wait --for=condition=ready pod \
            -l app=gitlab \
            -n gitlab \
            --timeout=600s || {
            log_warn "GitLab pod may still be starting. Checking status..."
            kubectl get pods -n gitlab -l app=gitlab
        }
    else
        # Wait for Helm deployment
        log_info "Waiting for GitLab webservice..."
        kubectl wait --for=condition=ready pod \
            -l app=webservice \
            -n gitlab \
            --timeout=600s || {
            log_warn "Webservice pods may still be starting. Checking status..."
            kubectl get pods -n gitlab -l app=webservice
        }
    fi

    log_info "GitLab is ready!"
}

create_ingress() {
    log_info "Verifying Ingress for GitLab..."

    if [[ "$USE_LIGHTWEIGHT" == "true" ]]; then
        # Ingress is created by the lightweight manifest
        if kubectl get ingress -n gitlab gitlab &> /dev/null; then
            log_info "GitLab Ingress exists"
        else
            log_error "GitLab Ingress not found. Check deployment."
            return 1
        fi
    else
        # GitLab Helm chart should create ingress automatically
        if kubectl get ingress -n gitlab gitlab-webservice-default &> /dev/null; then
            log_info "GitLab Ingress already exists"
        else
            log_warn "GitLab Ingress not found, creating manually..."

            cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab
  namespace: gitlab
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"
spec:
  ingressClassName: public
  rules:
  - host: gitlab.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gitlab-webservice-default
            port:
              number: 8181
EOF
            log_info "GitLab Ingress created"
        fi
    fi
}

get_root_password() {
    log_info "Retrieving GitLab root password..."

    if [[ "$USE_LIGHTWEIGHT" == "true" ]]; then
        # For lightweight deployment, password is set in the manifest
        log_info "Using default password from lightweight deployment"
        echo "changeme123" > "$PROJECT_ROOT/k8s/gitlab/root-password.txt"
        chmod 600 "$PROJECT_ROOT/k8s/gitlab/root-password.txt"
        log_warn "Initial password is: changeme123"
        log_warn "Please change this after first login!"
    else
        # Wait for secret to be created by Helm
        sleep 10

        if kubectl get secret -n gitlab gitlab-gitlab-initial-root-password &> /dev/null; then
            ROOT_PASSWORD=$(kubectl get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d)
            echo "$ROOT_PASSWORD" > "$PROJECT_ROOT/k8s/gitlab/root-password.txt"
            chmod 600 "$PROJECT_ROOT/k8s/gitlab/root-password.txt"
            log_info "Root password saved to: $PROJECT_ROOT/k8s/gitlab/root-password.txt"
        else
            log_warn "Root password secret not found. It may be created later."
        fi
    fi
}

print_info() {
    echo ""
    echo "========================================="
    log_info "GitLab Setup Complete!"
    echo "========================================="
    echo ""
    echo "Access GitLab at: http://gitlab.local"
    echo ""
    echo "Default credentials:"
    echo "  Username: root"
    if [[ -f "$PROJECT_ROOT/k8s/gitlab/root-password.txt" ]]; then
        echo "  Password: $(cat $PROJECT_ROOT/k8s/gitlab/root-password.txt)"
    else
        echo "  Password: Check $PROJECT_ROOT/k8s/gitlab/root-password.txt (will be created)"
        echo "  Or run: kubectl get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d"
    fi
    echo ""
    echo "GitLab pods:"
    kubectl get pods -n gitlab
    echo ""
    echo "Ingress:"
    kubectl get ingress -n gitlab
    echo ""
    echo "Next steps:"
    echo "  1. Login to GitLab at http://gitlab.local"
    echo "  2. Change the root password"
    echo "  3. Create projects for example-app and k8s-deployments"
    echo "  4. Configure GitLab to work with Jenkins (webhooks)"
    echo ""
}

main() {
    log_info "Starting GitLab setup..."

    # Use lightweight deployment by default
    export USE_LIGHTWEIGHT="${USE_LIGHTWEIGHT:-true}"

    check_prerequisites

    # Only add Helm repo if not using lightweight
    if [[ "$USE_LIGHTWEIGHT" != "true" ]]; then
        add_helm_repo
    fi

    deploy_gitlab
    wait_for_gitlab
    create_ingress
    get_root_password
    print_info
}

main "$@"
