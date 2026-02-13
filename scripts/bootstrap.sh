#!/usr/bin/env bash
# bootstrap.sh - Bootstrap a complete cluster from nothing
#
# Usage: ./scripts/bootstrap.sh <config-file>
#
# This script:
# 1. Validates the configuration file
# 2. Checks for namespace collisions (fails if namespaces exist)
# 3. Creates all namespaces (infrastructure + environments)
# 4. Applies infrastructure manifests with envsubst
# 5. Waits for pods to be ready
# 6. Configures services (GitLab repos, Jenkins jobs, webhooks)
# 7. Outputs hosts entries and next steps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# =============================================================================
# Colors and Logging
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
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
log_step()  { echo -e "\n${BLUE}=== $* ===${NC}\n"; }

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") [options] <config-file>

Bootstrap a complete cluster from nothing.

This script creates all namespaces, applies infrastructure manifests,
waits for pods to be ready, and runs configuration scripts.

Arguments:
  config-file  Path to cluster configuration file (e.g., config/clusters/alpha.env)

Options:
  --continue   Skip infrastructure setup (steps 1-4) and run only service
               configuration (step 5). Use this to resume after a partial
               bootstrap or to reconfigure an existing cluster.

Examples:
  $(basename "$0") config/clusters/alpha.env
  $(basename "$0") --continue config/clusters/alpha.env

Notes:
  - Without --continue, this script will FAIL if any namespaces already exist
  - Use teardown.sh to clean up before re-running full bootstrap
  - All manifests are processed with envsubst for parameterization
EOF
    exit 1
}

# =============================================================================
# Configuration Validation
# =============================================================================

validate_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    # Source the config
    # shellcheck source=/dev/null
    source "$config_file"
    export CLUSTER_CONFIG="$config_file"

    # Required variables for bootstrap
    local required_vars=(
        "CLUSTER_NAME"
        "GITLAB_NAMESPACE"
        "JENKINS_NAMESPACE"
        "NEXUS_NAMESPACE"
        "ARGOCD_NAMESPACE"
        "DEV_NAMESPACE"
        "STAGE_NAMESPACE"
        "PROD_NAMESPACE"
        "GITLAB_HOST_EXTERNAL"
        "JENKINS_HOST_EXTERNAL"
        "MAVEN_REPO_HOST_EXTERNAL"
        "ARGOCD_HOST_EXTERNAL"
        "STORAGE_CLASS"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Config file missing required variables:"
        for var in "${missing[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi

    log_info "Config validated: cluster=${CLUSTER_NAME}"
}

# =============================================================================
# Namespace Operations
# =============================================================================

get_all_namespaces() {
    # Deduplicate: configs may map multiple components to the same namespace
    echo "$GITLAB_NAMESPACE $JENKINS_NAMESPACE $NEXUS_NAMESPACE $ARGOCD_NAMESPACE $DEV_NAMESPACE $STAGE_NAMESPACE $PROD_NAMESPACE" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

check_namespace_collisions() {
    log_step "Step 1: Checking for namespace collisions"

    local namespaces
    namespaces=$(get_all_namespaces)
    local collisions=()

    for ns in $namespaces; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            collisions+=("$ns")
        fi
    done

    if [[ ${#collisions[@]} -gt 0 ]]; then
        log_error "Namespace collision detected. The following namespaces already exist:"
        for ns in "${collisions[@]}"; do
            log_error "  - $ns"
        done
        log_error ""
        log_error "Options:"
        log_error "  1. Run teardown.sh first: ./scripts/teardown.sh $CONFIG_FILE"
        log_error "  2. Use different namespace names in the config file"
        exit 1
    fi

    log_info "No namespace collisions detected"
}

create_namespaces() {
    log_step "Step 2: Creating namespaces"

    local namespaces
    namespaces=$(get_all_namespaces)

    for ns in $namespaces; do
        log_info "Creating namespace: $ns"
        kubectl create namespace "$ns"
    done

    log_info "All namespaces created"
}

# =============================================================================
# Manifest Application
# =============================================================================

generate_password() {
    # Generate a random password (16 alphanumeric characters)
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16
}

# Base directory for cluster secrets
CLUSTERS_DATA_DIR="${HOME}/.local/share/deployment-pipeline/clusters"

get_cluster_ca_paths() {
    CLUSTER_DATA_DIR="${CLUSTERS_DATA_DIR}/${CLUSTER_NAME}"
    CA_CERT="${CLUSTER_DATA_DIR}/ca.crt"
    CA_KEY="${CLUSTER_DATA_DIR}/ca.key"
}

ensure_cluster_ca() {
    log_info "Checking cluster CA certificate..."

    get_cluster_ca_paths

    if [[ -f "$CA_CERT" ]] && [[ -f "$CA_KEY" ]]; then
        log_info "  CA already exists for cluster: $CLUSTER_NAME"
    else
        log_info "  Generating new CA certificate..."
        mkdir -p "$CLUSTER_DATA_DIR"
        chmod 700 "$CLUSTER_DATA_DIR"

        openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY" 2>/dev/null
        chmod 600 "$CA_KEY"

        openssl req -new -x509 -sha256 \
            -key "$CA_KEY" \
            -out "$CA_CERT" \
            -days 3650 \
            -subj "/CN=${CLUSTER_NAME}-ca" \
            2>/dev/null

        log_info "  CA certificate generated"
    fi

    # Verify CA is valid
    if ! openssl x509 -in "$CA_CERT" -noout 2>/dev/null; then
        log_error "CA cert is invalid: $CA_CERT"
        exit 1
    fi

    # Verify Docker trust is configured for the container registry
    # The external registry has its own CA (not the cluster CA)
    local docker_cert_dir="/etc/docker/certs.d/${CONTAINER_REGISTRY_HOST}"
    if [[ ! -f "${docker_cert_dir}/ca.crt" ]]; then
        log_warn "Docker trust not found for registry: ${docker_cert_dir}/ca.crt"
        log_warn "Image push from this machine may fail. Ensure registry trust is configured."
    fi

    log_info "  CA cert: $CA_CERT"
    log_info "  Registry: ${CONTAINER_REGISTRY_HOST}"
}

export_config_for_envsubst() {
    # Export all config variables for envsubst
    # envsubst only substitutes exported variables
    export CLUSTER_NAME
    export GITLAB_NAMESPACE JENKINS_NAMESPACE NEXUS_NAMESPACE ARGOCD_NAMESPACE
    export DEV_NAMESPACE STAGE_NAMESPACE PROD_NAMESPACE
    export GITLAB_HOST_EXTERNAL JENKINS_HOST_EXTERNAL MAVEN_REPO_HOST_EXTERNAL ARGOCD_HOST_EXTERNAL
    export CONTAINER_REGISTRY_HOST
    export STORAGE_CLASS
    export GITLAB_URL_EXTERNAL GITLAB_URL_INTERNAL
    export GITLAB_GROUP APP_REPO_NAME DEPLOYMENTS_REPO_NAME
    export APP_REPO_PATH DEPLOYMENTS_REPO_PATH

    # Short aliases for manifests that use simplified variable names
    # Manifests use ${GITLAB_HOST} but config defines GITLAB_HOST_EXTERNAL
    export GITLAB_HOST="${GITLAB_HOST_EXTERNAL}"
    export JENKINS_HOST="${JENKINS_HOST_EXTERNAL}"
    export MAVEN_REPO_HOST="${MAVEN_REPO_HOST_EXTERNAL}"
    export ARGOCD_HOST="${ARGOCD_HOST_EXTERNAL}"
    export CONTAINER_REGISTRY="${CONTAINER_REGISTRY_HOST}"
    export CONTAINER_REGISTRY_PATH_PREFIX="${CONTAINER_REGISTRY_PATH_PREFIX:-}"
    export CA_ISSUER="${CA_ISSUER_NAME}"

    # Generate passwords if not already set
    export GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-$(generate_password)}"

    # Validate GitLab password meets minimum requirements (8 characters)
    if [[ ${#GITLAB_ROOT_PASSWORD} -lt 8 ]]; then
        log_warn "GITLAB_ROOT_PASSWORD is too short (${#GITLAB_ROOT_PASSWORD} chars, min 8)"
        log_info "Generating a valid password..."
        export GITLAB_ROOT_PASSWORD="$(generate_password)"
    fi
}

apply_manifest() {
    local manifest="$1"
    local description="${2:-$manifest}"

    if [[ ! -f "$manifest" ]]; then
        log_warn "Manifest not found: $manifest"
        return 1
    fi

    log_info "Applying $description..."
    if ! envsubst < "$manifest" | kubectl apply -f -; then
        log_error "Failed to apply: $manifest"
        return 1
    fi
}

provision_ca_to_certmanager() {
    log_info "Provisioning cluster-specific CA to cert-manager..."

    get_cluster_ca_paths

    # Cluster-specific resource names (don't touch shared resources)
    local secret_name="${CLUSTER_NAME}-ca-key-pair"
    local issuer_name="${CLUSTER_NAME}-ca-issuer"

    # Check if cert-manager namespace exists
    if ! kubectl get namespace cert-manager &>/dev/null; then
        log_error "cert-manager namespace not found"
        log_error "Install cert-manager first: kubectl apply -f k8s/cert-manager/cert-manager.yaml"
        return 1
    fi

    # Create or update the cluster-specific CA secret
    if kubectl get secret "$secret_name" -n cert-manager &>/dev/null; then
        log_info "  Updating existing $secret_name secret..."
        kubectl delete secret "$secret_name" -n cert-manager
    fi

    kubectl create secret tls "$secret_name" \
        -n cert-manager \
        --cert="$CA_CERT" \
        --key="$CA_KEY"

    log_info "  CA secret '$secret_name' created in cert-manager namespace"

    # Create cluster-specific ClusterIssuer
    log_info "  Creating ClusterIssuer '$issuer_name'..."
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${issuer_name}
spec:
  ca:
    secretName: ${secret_name}
EOF

    log_info "  ClusterIssuer '$issuer_name' configured"

    # Export for use in manifests
    export CA_ISSUER_NAME="$issuer_name"
}

apply_infrastructure_manifests() {
    log_step "Step 3: Applying infrastructure manifests"

    # Provision our CA to cert-manager first
    provision_ca_to_certmanager

    # Export all config variables for envsubst
    export_config_for_envsubst

    # Apply in order of dependencies

    # GitLab
    apply_manifest "$PROJECT_ROOT/k8s/gitlab/gitlab-lightweight.yaml" "GitLab"

    # Jenkins (pipeline-config first, then main deployment)
    if [[ -f "$PROJECT_ROOT/k8s/jenkins/pipeline-config.yaml" ]]; then
        apply_manifest "$PROJECT_ROOT/k8s/jenkins/pipeline-config.yaml" "Jenkins Pipeline Config"
    fi
    apply_manifest "$PROJECT_ROOT/k8s/jenkins/jenkins-lightweight.yaml" "Jenkins"

    # Nexus (Maven repos only - container registry is shared DSO resource)
    apply_manifest "$PROJECT_ROOT/k8s/nexus/nexus-lightweight.yaml" "Nexus"

    # ArgoCD - use upstream manifest with namespace override
    log_info "Applying ArgoCD..."
    if ! kubectl apply -n "$ARGOCD_NAMESPACE" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null; then
        log_warn "Upstream ArgoCD manifest failed, trying local copy..."
        if [[ -f "$PROJECT_ROOT/k8s/argocd/install.yaml" ]]; then
            kubectl apply -n "$ARGOCD_NAMESPACE" -f "$PROJECT_ROOT/k8s/argocd/install.yaml"
        else
            log_error "No ArgoCD manifest available"
            return 1
        fi
    fi

    # ArgoCD Ingress
    if [[ -f "$PROJECT_ROOT/k8s/argocd/ingress.yaml" ]]; then
        apply_manifest "$PROJECT_ROOT/k8s/argocd/ingress.yaml" "ArgoCD Ingress"
    fi

    log_info "Infrastructure manifests applied"
}

# =============================================================================
# Pod Readiness
# =============================================================================

wait_for_pods() {
    local namespace="$1"
    local timeout="${2:-300}"
    local description="${3:-$namespace}"

    log_info "Waiting for pods in $description (timeout: ${timeout}s)..."

    # First, wait for at least one pod to exist
    local wait_start
    wait_start=$(date +%s)
    while true; do
        local pod_count
        pod_count=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$pod_count" -gt 0 ]]; then
            break
        fi

        local elapsed=$(($(date +%s) - wait_start))
        if [[ $elapsed -ge 60 ]]; then
            log_warn "No pods found in $namespace after 60s, continuing..."
            return 0
        fi
        sleep 5
    done

    # Now wait for non-terminating pods to be ready
    # kubectl wait --all includes pods being removed by rolling updates,
    # which will never become ready. Use a label selector to exclude them.
    if ! kubectl wait --for=condition=ready pod --all -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        # Check if failure is just due to terminating pods from rolling updates
        local not_ready
        not_ready=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -v Terminating | grep -v '1/1.*Running' | grep -v '2/2.*Running' | grep -v Completed || true)
        if [[ -z "$not_ready" ]]; then
            log_info "All running pods are ready (terminating pods from rolling updates ignored)"
        else
            log_warn "Some pods in $namespace may not be ready:"
            echo "$not_ready"
            return 1
        fi
    fi

    log_info "Pods ready in $description"
}

wait_for_infrastructure() {
    log_step "Step 4: Waiting for infrastructure pods"

    # Deduplicate: configs may map multiple components to the same namespace
    # Use the most generous timeout (600s) for any shared namespace
    local infra_namespaces
    infra_namespaces=$(echo "$GITLAB_NAMESPACE $JENKINS_NAMESPACE $NEXUS_NAMESPACE $ARGOCD_NAMESPACE" | tr ' ' '\n' | sort -u)

    for ns in $infra_namespaces; do
        wait_for_pods "$ns" 600 "$ns"
    done

    log_info "All infrastructure pods ready"
}

# =============================================================================
# Service Configuration
# =============================================================================

run_script_if_exists() {
    local script="$1"
    local description="$2"
    local is_fatal="${3:-false}"

    if [[ ! -f "$script" ]]; then
        log_warn "$description script not found: $script"
        return 1
    fi

    log_info "Running $description..."
    if ! "$script" "$CONFIG_FILE"; then
        if [[ "$is_fatal" == "true" ]]; then
            log_error "$description failed (fatal)"
            exit 1
        else
            log_warn "$description had issues (non-fatal)"
            return 1
        fi
    fi
    return 0
}

configure_gitlab_api_token() {
    log_info "Creating GitLab token..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/create-gitlab-token.sh" "GitLab token" "true"

    # Also create the gitlab-admin-credentials K8s secret (stores username)
    # This is needed by setup-jenkins-credentials.sh to create Jenkins git credentials
    if ! kubectl get secret "$GITLAB_USER_SECRET" -n "$GITLAB_NAMESPACE" &>/dev/null; then
        log_info "Creating GitLab admin credentials secret..."
        kubectl create secret generic "$GITLAB_USER_SECRET" \
            -n "$GITLAB_NAMESPACE" \
            --from-literal="${GITLAB_USER_KEY}=root"
        log_info "  Created $GITLAB_USER_SECRET secret"
    fi
}

configure_gitlab_projects() {
    log_info "Creating GitLab projects..."
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/create-gitlab-projects.sh" "GitLab projects" "true"
}

configure_gitlab_network_settings() {
    log_info "Configuring GitLab network settings for webhooks..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/configure-gitlab-network-settings.sh" "GitLab network settings" "true"
}

setup_git_remotes() {
    log_info "Setting up git remotes for cluster: $CLUSTER_NAME..."

    # Ensure we're in the project root for git operations
    cd "$PROJECT_ROOT"

    # Get GitLab API token for authentication
    local gitlab_token
    gitlab_token=$(kubectl get secret "$GITLAB_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$gitlab_token" ]]; then
        log_error "Could not get GitLab API token for git remote setup"
        return 1
    fi

    # Determine remote names
    local app_remote="gitlab-app-${CLUSTER_NAME}"
    local deployments_remote="gitlab-deployments-${CLUSTER_NAME}"

    # Build authenticated URLs using oauth2 format (handles special chars in token)
    # Format: https://oauth2:<token>@hostname/path.git
    local gitlab_host="${GITLAB_HOST_EXTERNAL}"
    local app_url="https://oauth2:${gitlab_token}@${gitlab_host}/${APP_REPO_PATH}.git"
    local deployments_url="https://oauth2:${gitlab_token}@${gitlab_host}/${DEPLOYMENTS_REPO_PATH}.git"

    # Remove existing remotes if they exist (idempotent)
    git remote remove "$app_remote" 2>/dev/null || true
    git remote remove "$deployments_remote" 2>/dev/null || true

    # Add cluster-specific remotes with oauth2 authentication
    git remote add "$app_remote" "$app_url"
    git remote add "$deployments_remote" "$deployments_url"

    log_info "  Added remote: $app_remote -> ${GITLAB_URL_EXTERNAL}/${APP_REPO_PATH}.git"
    log_info "  Added remote: $deployments_remote -> ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"
}

sync_subtrees_to_gitlab() {
    log_info "Syncing subtrees to GitLab..."

    # Ensure we're in the project root for git operations
    cd "$PROJECT_ROOT"

    # The sync script is cluster-aware via CLUSTER_CONFIG
    if [[ -x "$SCRIPT_DIR/04-operations/sync-to-gitlab.sh" ]]; then
        # Run sync - requires clean working tree
        if ! "$SCRIPT_DIR/04-operations/sync-to-gitlab.sh" main 2>&1; then
            log_warn "Subtree sync had issues"
            return 1
        fi
    else
        log_warn "sync-to-gitlab.sh not found"
        return 1
    fi
}

setup_environment_branches() {
    log_info "Setting up environment branches..."
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-gitlab-env-branches.sh" "Environment branches" "true"
}

setup_jenkins_pipelines() {
    log_info "Setting up Jenkins pipelines and webhooks..."

    # First, create the MultiBranch Pipeline jobs (required before webhook setup)
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-multibranch-jobs.sh" "Jenkins MultiBranch jobs" "true"

    # Setup multibranch pipeline webhook trigger in Jenkins
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-multibranch-webhook.sh" "Jenkins multibranch webhook" "true"

    # Setup GitLab webhooks to trigger Jenkins MultiBranch scans
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-gitlab-jenkins-webhooks.sh" "GitLab Jenkins webhooks" "true"

    # Setup auto-promote job and webhook
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-auto-promote-job.sh" "Jenkins auto-promote job" "true"
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-auto-promote-webhook.sh" "Auto-promote webhook" "true"

    # Setup promote job
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-promote-job.sh" "Jenkins promote job" "true"
}

create_jenkins_credentials_secret() {
    log_info "Creating Jenkins admin credentials secret..."

    # Get Jenkins admin password from ConfigMap (set during bootstrap)
    local jenkins_password
    jenkins_password=$(kubectl get configmap jenkins-config -n "$JENKINS_NAMESPACE" \
        -o jsonpath='{.data.jenkins\.model\.Jenkins\.adminPassword}' 2>/dev/null) || jenkins_password="admin"

    # Create secret if it doesn't exist
    if kubectl get secret jenkins-admin-credentials -n "$JENKINS_NAMESPACE" &>/dev/null; then
        log_info "  Jenkins credentials secret already exists"
    else
        kubectl create secret generic jenkins-admin-credentials \
            -n "$JENKINS_NAMESPACE" \
            --from-literal=username=admin \
            --from-literal=password="$jenkins_password"
        log_info "  Created jenkins-admin-credentials secret"
    fi
}

install_jenkins_plugins() {
    log_info "Installing required Jenkins plugins..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/install-jenkins-plugins.sh" "Jenkins plugins" "true"
}

configure_jenkins_kubernetes_cloud() {
    log_info "Configuring Jenkins Kubernetes cloud..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/configure-jenkins-kubernetes-cloud.sh" "Jenkins Kubernetes cloud" "true"
}

configure_jenkins_global_env() {
    log_info "Configuring Jenkins global environment variables..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/configure-jenkins-global-env.sh" "Jenkins global environment" "true"
}

configure_jenkins_root_url() {
    log_info "Configuring Jenkins root URL..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/configure-jenkins-root-url.sh" "Jenkins root URL" "true"
}

configure_jenkins_script_security() {
    log_info "Configuring Jenkins script security..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/configure-jenkins-script-security.sh" "Jenkins script security" "true"
}

setup_jenkins_pipeline_credentials() {
    log_info "Setting up Jenkins pipeline credentials..."
    run_script_if_exists "$SCRIPT_DIR/01-infrastructure/setup-jenkins-credentials.sh" "Jenkins pipeline credentials" "true"
}

prompt_registry_credentials() {
    # Prompt for container registry credentials (used for Docker push)
    # Credentials are passed via env vars to child scripts
    log_info "Container registry credentials needed for image push"
    log_info "Registry: ${CONTAINER_REGISTRY_HOST}"
    echo -n "  Username: "
    read -r CONTAINER_REGISTRY_USER
    echo -n "  Password: "
    read -rs CONTAINER_REGISTRY_PASS
    echo ""
    export CONTAINER_REGISTRY_USER CONTAINER_REGISTRY_PASS
}

build_jenkins_agent_image() {
    log_info "Building Jenkins agent image..."
    run_script_if_exists "$PROJECT_ROOT/k8s/jenkins/agent/build-agent-image.sh" "Jenkins agent image" "true"
}

configure_nexus() {
    log_info "Configuring Nexus repositories..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/configure-nexus.sh" "Nexus repositories" "true"
}


configure_argocd_dns() {
    log_info "Configuring ArgoCD DNS resolution for external hostnames..."

    # ArgoCD repo-server needs to resolve external hostnames (e.g., gitlab-alpha.jmann.local)
    # to clone git repos. Cluster DNS doesn't know about these hostnames, so we add
    # hostAliases to map them to the ingress controller's node IP.

    # Get the node IP (ingress controller uses hostPort, so node IP = ingress IP)
    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    if [[ -z "$node_ip" ]]; then
        log_error "Could not determine node IP for hostAliases"
        return 1
    fi
    log_info "  Node IP: $node_ip"

    # Collect all external hostnames that ArgoCD needs to resolve
    local hostnames=("${GITLAB_HOST_EXTERNAL}")
    log_info "  Hostnames: ${hostnames[*]}"

    # Build hostAliases JSON
    local aliases_json
    aliases_json=$(printf '%s\n' "${hostnames[@]}" | jq -Rn --arg ip "$node_ip" \
        '[{"ip": $ip, "hostnames": [inputs]}]')

    # Patch argocd-repo-server (does git clone operations)
    log_info "  Patching argocd-repo-server with hostAliases..."
    kubectl patch deployment argocd-repo-server -n "$ARGOCD_NAMESPACE" \
        --type=strategic \
        -p "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":$aliases_json}}}}"

    # Add cluster CA cert to ArgoCD TLS certs ConfigMap so it trusts GitLab's TLS cert
    get_cluster_ca_paths
    if [[ -f "$CA_CERT" ]]; then
        log_info "  Adding cluster CA to ArgoCD TLS trust for ${GITLAB_HOST_EXTERNAL}..."
        local ca_cert_content
        ca_cert_content=$(cat "$CA_CERT")
        kubectl patch configmap argocd-tls-certs-cm -n "$ARGOCD_NAMESPACE" \
            --type=merge \
            -p "{\"data\":{\"${GITLAB_HOST_EXTERNAL}\":$(echo "$ca_cert_content" | jq -Rs .)}}"
    else
        log_warn "  Cluster CA cert not found, ArgoCD may not trust GitLab TLS"
    fi

    # Configure repository credentials so ArgoCD can clone from GitLab
    log_info "  Configuring ArgoCD repository credentials for GitLab..."
    local gitlab_token
    gitlab_token=$(kubectl get secret gitlab-token -n "$GITLAB_NAMESPACE" \
        -o jsonpath='{.data.token}' | base64 -d)
    if [[ -n "$gitlab_token" ]]; then
        kubectl apply -n "$ARGOCD_NAMESPACE" -f - <<REPO_CREDS_EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-creds-gitlab
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: git
  url: ${GITLAB_URL_EXTERNAL}
  username: root
  password: ${gitlab_token}
REPO_CREDS_EOF
        log_info "  ArgoCD repository credentials configured"
    else
        log_error "  Could not get GitLab API token for ArgoCD"
        return 1
    fi

    # Wait for rollout to complete
    log_info "  Waiting for argocd-repo-server rollout..."
    kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=120s

    log_info "ArgoCD DNS configuration complete"
}

setup_argocd_applications() {
    log_info "Setting up ArgoCD applications..."
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-argocd-applications.sh" "ArgoCD applications" "false"
}

configure_services() {
    log_step "Step 5: Configuring services"

    # 5a. Create GitLab API token (required for all subsequent GitLab operations)
    configure_gitlab_api_token

    # 5b. Create GitLab projects
    configure_gitlab_projects

    # 5c. Configure GitLab network settings (allow local webhook URLs)
    configure_gitlab_network_settings

    # 5d. Setup git remotes for this cluster
    setup_git_remotes

    # 5e. Sync subtrees to GitLab (pushes example-app and k8s-deployments)
    sync_subtrees_to_gitlab

    # 5f. Setup environment branches (dev/stage/prod) in k8s-deployments
    setup_environment_branches

    # 5g. Configure ArgoCD DNS (hostAliases + TLS trust for external GitLab)
    configure_argocd_dns

    # 5h. Setup ArgoCD applications (after env branches exist and DNS configured)
    setup_argocd_applications

    # 5i. Configure Nexus repositories (Docker registry needed for agent image)
    configure_nexus

    # 5j. Create Jenkins credentials secret (needed for webhook setup)
    create_jenkins_credentials_secret

    # 5k. Prompt for container registry credentials (needed for image push)
    prompt_registry_credentials

    # 5l. Build Jenkins agent image (push to external registry)
    build_jenkins_agent_image

    # 5m. Install required Jenkins plugins (must be done before job creation)
    install_jenkins_plugins

    # 5n. Configure Jenkins Kubernetes cloud (for pod-based agents)
    configure_jenkins_kubernetes_cloud

    # 5o. Configure Jenkins global environment variables (needed for pipeline env.VAR access)
    configure_jenkins_global_env

    # 5p. Configure Jenkins root URL (needed for BUILD_URL)
    configure_jenkins_root_url

    # 5q. Configure Jenkins script security (approve required signatures)
    configure_jenkins_script_security

    # 5r. Setup Jenkins pipeline credentials (gitlab-token-secret, nexus, argocd)
    setup_jenkins_pipeline_credentials

    # 5s. Setup Jenkins pipelines and webhooks
    setup_jenkins_pipelines

    # 5t. Configure merge requirements (optional)
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/configure-merge-requirements.sh" "Merge requirements" || true

    log_info "Service configuration completed successfully"
}

# =============================================================================
# Summary Output
# =============================================================================

print_summary() {
    log_step "Bootstrap Complete"

    # Try to get the cluster IP for /etc/hosts entry
    local cluster_ip
    cluster_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "CLUSTER_IP")

    echo ""
    echo "Cluster: $CLUSTER_NAME"
    echo ""
    echo "=============================================="
    echo "Add the following to /etc/hosts:"
    echo "=============================================="
    echo ""
    echo "  $cluster_ip $GITLAB_HOST_EXTERNAL $JENKINS_HOST_EXTERNAL $MAVEN_REPO_HOST_EXTERNAL $ARGOCD_HOST_EXTERNAL ${CONTAINER_REGISTRY_HOST:-}"
    echo ""
    echo "=============================================="
    echo "Verify cluster health:"
    echo "=============================================="
    echo ""
    echo "  ./scripts/cluster-ctl.sh status $CONFIG_FILE"
    echo ""
    if [[ -x "$SCRIPT_DIR/verify-cluster.sh" ]]; then
        echo "  ./scripts/verify-cluster.sh $CONFIG_FILE"
        echo ""
    fi
    echo "=============================================="
    echo "Run demo suite:"
    echo "=============================================="
    echo ""
    echo "  ./scripts/demo/run-all-demos.sh $CONFIG_FILE"
    echo ""
    echo "=============================================="
    echo "Service URLs:"
    echo "=============================================="
    echo ""
    echo "  GitLab:  https://${GITLAB_HOST_EXTERNAL}"
    echo "  Jenkins: https://${JENKINS_HOST_EXTERNAL}"
    echo "  Nexus:   https://${MAVEN_REPO_HOST_EXTERNAL}"
    echo "  ArgoCD:  https://${ARGOCD_HOST_EXTERNAL}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    local continue_only=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help|help)
                usage
                ;;
            --continue)
                continue_only=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                CONFIG_FILE="$1"
                shift
                ;;
        esac
    done

    # Validate config file argument
    if [[ -z "${CONFIG_FILE:-}" ]]; then
        log_error "Config file required"
        echo ""
        usage
    fi

    # Validate and source config
    validate_config "$CONFIG_FILE"

    # Verify host is prepared (CA exists, Docker trust configured)
    ensure_cluster_ca

    log_info "Bootstrapping cluster: $CLUSTER_NAME"
    log_info "Config file: $CONFIG_FILE"

    if $continue_only; then
        log_info "Continue mode: skipping infrastructure setup (steps 1-4)"
        log_info "Running service configuration only..."
        echo ""

        # Verify infrastructure is running
        log_step "Verifying infrastructure pods"
        wait_for_infrastructure

        # Ensure CA is provisioned (idempotent, needed for Docker registry push)
        provision_ca_to_certmanager
        export_config_for_envsubst

        # Run only configuration
        configure_services
    else
        # Execute full bootstrap steps
        check_namespace_collisions
        create_namespaces
        apply_infrastructure_manifests
        wait_for_infrastructure
        configure_services
    fi

    print_summary

    log_info "Bootstrap completed for cluster: $CLUSTER_NAME"
}

main "$@"
