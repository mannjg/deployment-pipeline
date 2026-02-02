#!/bin/bash
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
Usage: $(basename "$0") <config-file>

Bootstrap a complete cluster from nothing.

This script creates all namespaces, applies infrastructure manifests,
waits for pods to be ready, and runs configuration scripts.

Arguments:
  config-file  Path to cluster configuration file (e.g., config/clusters/alpha.env)

Examples:
  $(basename "$0") config/clusters/alpha.env
  $(basename "$0") config/clusters/reference.env

Notes:
  - This script will FAIL if any namespaces already exist
  - Use teardown.sh to clean up before re-running bootstrap
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
        "NEXUS_HOST_EXTERNAL"
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
    echo "$GITLAB_NAMESPACE $JENKINS_NAMESPACE $NEXUS_NAMESPACE $ARGOCD_NAMESPACE $DEV_NAMESPACE $STAGE_NAMESPACE $PROD_NAMESPACE"
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

export_config_for_envsubst() {
    # Export all config variables for envsubst
    # envsubst only substitutes exported variables
    export CLUSTER_NAME
    export GITLAB_NAMESPACE JENKINS_NAMESPACE NEXUS_NAMESPACE ARGOCD_NAMESPACE
    export DEV_NAMESPACE STAGE_NAMESPACE PROD_NAMESPACE
    export GITLAB_HOST_EXTERNAL JENKINS_HOST_EXTERNAL NEXUS_HOST_EXTERNAL ARGOCD_HOST_EXTERNAL
    export DOCKER_REGISTRY_HOST
    export STORAGE_CLASS
    export GITLAB_URL_EXTERNAL GITLAB_URL_INTERNAL
    export GITLAB_GROUP APP_REPO_NAME DEPLOYMENTS_REPO_NAME
    export APP_REPO_PATH DEPLOYMENTS_REPO_PATH

    # Short aliases for manifests that use simplified variable names
    # Manifests use ${GITLAB_HOST} but config defines GITLAB_HOST_EXTERNAL
    export GITLAB_HOST="${GITLAB_HOST_EXTERNAL}"
    export JENKINS_HOST="${JENKINS_HOST_EXTERNAL}"
    export NEXUS_HOST="${NEXUS_HOST_EXTERNAL}"
    export ARGOCD_HOST="${ARGOCD_HOST_EXTERNAL}"

    # Generate passwords if not already set
    export GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-$(generate_password)}"
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

apply_infrastructure_manifests() {
    log_step "Step 3: Applying infrastructure manifests"

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

    # Nexus
    apply_manifest "$PROJECT_ROOT/k8s/nexus/nexus-lightweight.yaml" "Nexus"
    if [[ -f "$PROJECT_ROOT/k8s/nexus/nexus-docker-nodeport.yaml" ]]; then
        apply_manifest "$PROJECT_ROOT/k8s/nexus/nexus-docker-nodeport.yaml" "Nexus Docker NodePort"
    fi

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

    # Now wait for pods to be ready
    if ! kubectl wait --for=condition=ready pod --all -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        log_warn "Some pods in $namespace may not be ready. Current status:"
        kubectl get pods -n "$namespace" 2>/dev/null || true
        return 1
    fi

    log_info "Pods ready in $description"
}

wait_for_infrastructure() {
    log_step "Step 4: Waiting for infrastructure pods"

    local errors=0

    # GitLab takes longer due to initialization
    wait_for_pods "$GITLAB_NAMESPACE" 600 "GitLab" || ((errors++))

    # Jenkins
    wait_for_pods "$JENKINS_NAMESPACE" 300 "Jenkins" || ((errors++))

    # Nexus
    wait_for_pods "$NEXUS_NAMESPACE" 180 "Nexus" || ((errors++))

    # ArgoCD
    wait_for_pods "$ARGOCD_NAMESPACE" 180 "ArgoCD" || ((errors++))

    if [[ $errors -gt 0 ]]; then
        log_warn "$errors namespace(s) had pod readiness issues"
    else
        log_info "All infrastructure pods ready"
    fi
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
    log_info "Creating GitLab API token..."
    run_script_if_exists "$SCRIPT_DIR/02-configure/create-gitlab-api-token.sh" "GitLab API token" "true"
}

configure_gitlab_projects() {
    log_info "Creating GitLab projects..."
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/create-gitlab-projects.sh" "GitLab projects" "true"
}

setup_git_remotes() {
    log_info "Setting up git remotes for cluster: $CLUSTER_NAME..."

    # Ensure we're in the project root for git operations
    cd "$PROJECT_ROOT"

    # Determine remote names
    local app_remote="gitlab-app-${CLUSTER_NAME}"
    local deployments_remote="gitlab-deployments-${CLUSTER_NAME}"

    # Remove existing remotes if they exist (idempotent)
    git remote remove "$app_remote" 2>/dev/null || true
    git remote remove "$deployments_remote" 2>/dev/null || true

    # Add cluster-specific remotes
    git remote add "$app_remote" "${GITLAB_URL_EXTERNAL}/${APP_REPO_PATH}.git"
    git remote add "$deployments_remote" "${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"

    log_info "  Added remote: $app_remote -> ${GITLAB_URL_EXTERNAL}/${APP_REPO_PATH}.git"
    log_info "  Added remote: $deployments_remote -> ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"
}

sync_subtrees_to_gitlab() {
    log_info "Syncing subtrees to GitLab..."

    # Ensure we're in the project root for git operations
    cd "$PROJECT_ROOT"

    # The sync script is cluster-aware via CLUSTER_CONFIG
    if [[ -x "$SCRIPT_DIR/04-operations/sync-to-gitlab.sh" ]]; then
        # Run non-interactively (skip uncommitted changes prompt)
        if ! yes | "$SCRIPT_DIR/04-operations/sync-to-gitlab.sh" main 2>&1; then
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
    local errors=0

    # Setup multibranch pipeline webhook for example-app
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-multibranch-webhook.sh" "Jenkins multibranch webhook" || ((errors++))

    # Setup auto-promote job and webhook
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-auto-promote-job.sh" "Jenkins auto-promote job" || ((errors++))
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-auto-promote-webhook.sh" "Auto-promote webhook" || ((errors++))

    # Setup promote job
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/setup-jenkins-promote-job.sh" "Jenkins promote job" || ((errors++))

    return $errors
}

configure_services() {
    log_step "Step 5: Configuring services"

    local errors=0

    # 5a. Create GitLab API token (required for all subsequent GitLab operations)
    configure_gitlab_api_token || ((errors++))

    # 5b. Create GitLab projects
    configure_gitlab_projects || ((errors++))

    # 5c. Setup git remotes for this cluster
    setup_git_remotes || ((errors++))

    # 5d. Sync subtrees to GitLab (pushes example-app and k8s-deployments)
    sync_subtrees_to_gitlab || ((errors++))

    # 5e. Setup environment branches (dev/stage/prod) in k8s-deployments
    setup_environment_branches || ((errors++))

    # 5f. Setup Jenkins pipelines and webhooks
    setup_jenkins_pipelines || ((errors++))

    # 5g. Configure merge requirements (optional)
    run_script_if_exists "$SCRIPT_DIR/03-pipelines/configure-merge-requirements.sh" "Merge requirements" || true

    if [[ $errors -gt 0 ]]; then
        log_warn "Service configuration completed with $errors warning(s)"
        log_warn "Some features may not work correctly until issues are resolved"
    else
        log_info "Service configuration completed successfully"
    fi
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
    echo "  $cluster_ip $GITLAB_HOST_EXTERNAL $JENKINS_HOST_EXTERNAL $NEXUS_HOST_EXTERNAL $ARGOCD_HOST_EXTERNAL ${DOCKER_REGISTRY_HOST:-}"
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
    echo "  Nexus:   https://${NEXUS_HOST_EXTERNAL}"
    echo "  ArgoCD:  https://${ARGOCD_HOST_EXTERNAL}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        usage
    fi

    # Validate config file argument
    CONFIG_FILE="${1:-}"
    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "Config file required"
        echo ""
        usage
    fi

    # Validate and source config
    validate_config "$CONFIG_FILE"

    log_info "Bootstrapping cluster: $CLUSTER_NAME"
    log_info "Config file: $CONFIG_FILE"

    # Execute bootstrap steps
    check_namespace_collisions
    create_namespaces
    apply_infrastructure_manifests
    wait_for_infrastructure
    configure_services
    print_summary

    log_info "Bootstrap completed for cluster: $CLUSTER_NAME"
}

main "$@"
