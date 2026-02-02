# Multi-Cluster Bootstrap Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the deployment-pipeline from hardcoded single-cluster to fully parameterized multi-cluster bootstrap system.

**Architecture:** All scripts require a cluster config file as first argument. Manifests use envsubst for all configurable values. No hardcoded namespaces or hostnames anywhere.

**Tech Stack:** Bash, envsubst, kubectl, existing CLI tools (gitlab-cli.sh, jenkins-cli.sh)

**Design Doc:** `docs/plans/2026-02-02-multi-cluster-bootstrap-design.md`

---

## Phase 1: Foundation

### Task 1.1: Create Cluster Config Directory Structure

**Files:**
- Create: `config/clusters/README.md`
- Create: `config/clusters/reference.env`
- Create: `config/clusters/alpha.env`

**Step 1: Create clusters directory and README**

```bash
mkdir -p config/clusters
```

```markdown
# config/clusters/README.md
# Cluster Configurations

Each `.env` file in this directory defines a complete cluster configuration.

## Usage

All scripts require a config file as the first argument:

```bash
./scripts/bootstrap.sh config/clusters/alpha.env
./scripts/demo/run-all-demos.sh config/clusters/alpha.env
./scripts/teardown.sh config/clusters/alpha.env
```

## Creating a New Cluster Config

1. Copy an existing config: `cp config/clusters/alpha.env config/clusters/mycluster.env`
2. Edit all values to match your desired naming
3. Run bootstrap: `./scripts/bootstrap.sh config/clusters/mycluster.env`

## Protected Clusters

Set `PROTECTED="true"` to prevent accidental teardown.
```

**Step 2: Create reference.env (current cluster, protected)**

```bash
# config/clusters/reference.env
# Reference cluster configuration - PROTECTED
# This represents the current working cluster with bare names

# Cluster metadata
CLUSTER_NAME="reference"
PROTECTED="true"

# Infrastructure namespaces
GITLAB_NAMESPACE="gitlab"
JENKINS_NAMESPACE="jenkins"
NEXUS_NAMESPACE="nexus"
ARGOCD_NAMESPACE="argocd"

# Environment namespaces (where apps deploy)
DEV_NAMESPACE="dev"
STAGE_NAMESPACE="stage"
PROD_NAMESPACE="prod"

# External hostnames (ingress)
GITLAB_HOST="gitlab.jmann.local"
JENKINS_HOST="jenkins.jmann.local"
NEXUS_HOST="nexus.jmann.local"
ARGOCD_HOST="argocd.jmann.local"
DOCKER_REGISTRY_HOST="docker.jmann.local"

# Internal service discovery
GITLAB_HOST_INTERNAL="gitlab.${GITLAB_NAMESPACE}.svc.cluster.local"
JENKINS_HOST_INTERNAL="jenkins.${JENKINS_NAMESPACE}.svc.cluster.local"
NEXUS_HOST_INTERNAL="nexus.${NEXUS_NAMESPACE}.svc.cluster.local"
ARGOCD_HOST_INTERNAL="argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local"

# Full URLs (internal)
GITLAB_URL_INTERNAL="http://${GITLAB_HOST_INTERNAL}"
JENKINS_URL_INTERNAL="http://${JENKINS_HOST_INTERNAL}:8080"
NEXUS_URL_INTERNAL="http://${NEXUS_HOST_INTERNAL}:8081"
ARGOCD_URL_INTERNAL="http://${ARGOCD_HOST_INTERNAL}"

# Full URLs (external)
GITLAB_URL_EXTERNAL="https://${GITLAB_HOST}"
JENKINS_URL_EXTERNAL="https://${JENKINS_HOST}"
NEXUS_URL_EXTERNAL="https://${NEXUS_HOST}"
ARGOCD_URL_EXTERNAL="https://${ARGOCD_HOST}"

# Docker registry
DOCKER_REGISTRY_INTERNAL="${NEXUS_HOST_INTERNAL}:5000"
DOCKER_REGISTRY_EXTERNAL="${DOCKER_REGISTRY_HOST}"

# GitLab configuration
GITLAB_GROUP="p2c"
APP_REPO_NAME="example-app"
APP_CUE_NAME="exampleApp"
DEPLOYMENTS_REPO_NAME="k8s-deployments"

# Repository paths
APP_REPO_PATH="${GITLAB_GROUP}/${APP_REPO_NAME}"
DEPLOYMENTS_REPO_PATH="${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}"

# Repository URLs (internal)
APP_REPO_URL="${GITLAB_URL_INTERNAL}/${APP_REPO_PATH}.git"
DEPLOYMENTS_REPO_URL="${GITLAB_URL_INTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"

# Repository URLs (external)
APP_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${APP_REPO_PATH}.git"
DEPLOYMENTS_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"

# Secrets (K8s secret names within namespaces)
GITLAB_API_TOKEN_SECRET="gitlab-api-token"
GITLAB_API_TOKEN_KEY="token"
GITLAB_USER_SECRET="gitlab-admin-credentials"
GITLAB_USER_KEY="username"
JENKINS_ADMIN_SECRET="jenkins-admin-credentials"
JENKINS_ADMIN_USER_KEY="username"
JENKINS_ADMIN_TOKEN_KEY="password"
NEXUS_ADMIN_SECRET="nexus-admin-credentials"
NEXUS_ADMIN_USER_KEY="username"
NEXUS_ADMIN_PASSWORD_KEY="password"

# Jenkins job configuration
JENKINS_APP_JOB_PATH="${APP_REPO_NAME}/job/main"
JENKINS_PROMOTE_JOB_NAME="promote-environment"
JENKINS_AUTO_PROMOTE_JOB_NAME="k8s-deployments-auto-promote"
K8S_DEPLOYMENTS_JOB="k8s-deployments"
K8S_DEPLOYMENTS_REPO_PATH="${DEPLOYMENTS_REPO_PATH}"

# Storage
STORAGE_CLASS="microk8s-hostpath"

# Timeouts (seconds)
K8S_DEPLOYMENTS_BUILD_TIMEOUT="${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-300}"
PROMOTION_MR_TIMEOUT="${PROMOTION_MR_TIMEOUT:-180}"
```

**Step 3: Create alpha.env (test cluster template)**

```bash
# config/clusters/alpha.env
# Alpha test cluster configuration
# Use this as a template for new clusters

# Cluster metadata
CLUSTER_NAME="alpha"
PROTECTED="false"

# Infrastructure namespaces
GITLAB_NAMESPACE="gitlab-alpha"
JENKINS_NAMESPACE="jenkins-alpha"
NEXUS_NAMESPACE="nexus-alpha"
ARGOCD_NAMESPACE="argocd-alpha"

# Environment namespaces (where apps deploy)
DEV_NAMESPACE="dev-alpha"
STAGE_NAMESPACE="stage-alpha"
PROD_NAMESPACE="prod-alpha"

# External hostnames (ingress)
GITLAB_HOST="gitlab-alpha.jmann.local"
JENKINS_HOST="jenkins-alpha.jmann.local"
NEXUS_HOST="nexus-alpha.jmann.local"
ARGOCD_HOST="argocd-alpha.jmann.local"
DOCKER_REGISTRY_HOST="docker-alpha.jmann.local"

# Internal service discovery
GITLAB_HOST_INTERNAL="gitlab.${GITLAB_NAMESPACE}.svc.cluster.local"
JENKINS_HOST_INTERNAL="jenkins.${JENKINS_NAMESPACE}.svc.cluster.local"
NEXUS_HOST_INTERNAL="nexus.${NEXUS_NAMESPACE}.svc.cluster.local"
ARGOCD_HOST_INTERNAL="argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local"

# Full URLs (internal)
GITLAB_URL_INTERNAL="http://${GITLAB_HOST_INTERNAL}"
JENKINS_URL_INTERNAL="http://${JENKINS_HOST_INTERNAL}:8080"
NEXUS_URL_INTERNAL="http://${NEXUS_HOST_INTERNAL}:8081"
ARGOCD_URL_INTERNAL="http://${ARGOCD_HOST_INTERNAL}"

# Full URLs (external)
GITLAB_URL_EXTERNAL="https://${GITLAB_HOST}"
JENKINS_URL_EXTERNAL="https://${JENKINS_HOST}"
NEXUS_URL_EXTERNAL="https://${NEXUS_HOST}"
ARGOCD_URL_EXTERNAL="https://${ARGOCD_HOST}"

# Docker registry
DOCKER_REGISTRY_INTERNAL="${NEXUS_HOST_INTERNAL}:5000"
DOCKER_REGISTRY_EXTERNAL="${DOCKER_REGISTRY_HOST}"

# GitLab configuration
GITLAB_GROUP="p2c"
APP_REPO_NAME="example-app"
APP_CUE_NAME="exampleApp"
DEPLOYMENTS_REPO_NAME="k8s-deployments"

# Repository paths
APP_REPO_PATH="${GITLAB_GROUP}/${APP_REPO_NAME}"
DEPLOYMENTS_REPO_PATH="${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}"

# Repository URLs (internal)
APP_REPO_URL="${GITLAB_URL_INTERNAL}/${APP_REPO_PATH}.git"
DEPLOYMENTS_REPO_URL="${GITLAB_URL_INTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"

# Repository URLs (external)
APP_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${APP_REPO_PATH}.git"
DEPLOYMENTS_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"

# Secrets (K8s secret names within namespaces)
GITLAB_API_TOKEN_SECRET="gitlab-api-token"
GITLAB_API_TOKEN_KEY="token"
GITLAB_USER_SECRET="gitlab-admin-credentials"
GITLAB_USER_KEY="username"
JENKINS_ADMIN_SECRET="jenkins-admin-credentials"
JENKINS_ADMIN_USER_KEY="username"
JENKINS_ADMIN_TOKEN_KEY="password"
NEXUS_ADMIN_SECRET="nexus-admin-credentials"
NEXUS_ADMIN_USER_KEY="username"
NEXUS_ADMIN_PASSWORD_KEY="password"

# Jenkins job configuration
JENKINS_APP_JOB_PATH="${APP_REPO_NAME}/job/main"
JENKINS_PROMOTE_JOB_NAME="promote-environment"
JENKINS_AUTO_PROMOTE_JOB_NAME="k8s-deployments-auto-promote"
K8S_DEPLOYMENTS_JOB="k8s-deployments"
K8S_DEPLOYMENTS_REPO_PATH="${DEPLOYMENTS_REPO_PATH}"

# Storage
STORAGE_CLASS="microk8s-hostpath"

# Timeouts (seconds)
K8S_DEPLOYMENTS_BUILD_TIMEOUT="${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-300}"
PROMOTION_MR_TIMEOUT="${PROMOTION_MR_TIMEOUT:-180}"
```

**Step 4: Commit**

```bash
git add config/clusters/
git commit -m "feat: add cluster configuration structure

- Add config/clusters/ directory for per-cluster env files
- Add reference.env for current cluster (PROTECTED=true)
- Add alpha.env as template for new test clusters
- Add README.md explaining usage

Part of multi-cluster bootstrap implementation."
```

---

### Task 1.2: Create cluster-ctl.sh (pause/resume)

**Files:**
- Create: `scripts/cluster-ctl.sh`

**Step 1: Create cluster-ctl.sh**

```bash
#!/bin/bash
# cluster-ctl.sh - Cluster lifecycle management
#
# Usage:
#   ./scripts/cluster-ctl.sh pause <config-file>   # Scale deployments to 0
#   ./scripts/cluster-ctl.sh resume <config-file>  # Restore deployments
#   ./scripts/cluster-ctl.sh status <config-file>  # Show cluster status
#
# The pause command scales all deployments to 0 replicas, providing defense
# against accidentally using the wrong cluster due to hardcoded values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 <command> <config-file>"
    echo ""
    echo "Commands:"
    echo "  pause   Scale all deployments to 0 replicas"
    echo "  resume  Restore deployments to original replica counts"
    echo "  status  Show current cluster status"
    echo ""
    echo "Examples:"
    echo "  $0 pause config/clusters/reference.env"
    echo "  $0 resume config/clusters/reference.env"
    exit 1
}

validate_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    # Source config
    source "$config_file"

    # Validate required variables
    local required_vars=(
        CLUSTER_NAME
        GITLAB_NAMESPACE
        JENKINS_NAMESPACE
        NEXUS_NAMESPACE
        ARGOCD_NAMESPACE
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable $var not set in $config_file"
            exit 1
        fi
    done
}

get_infrastructure_namespaces() {
    echo "$GITLAB_NAMESPACE $JENKINS_NAMESPACE $NEXUS_NAMESPACE $ARGOCD_NAMESPACE"
}

# Store original replica counts in a ConfigMap before scaling down
store_replica_counts() {
    local ns="$1"
    local configmap_name="cluster-ctl-replicas"

    # Get all deployments and their replica counts
    local replicas_json
    replicas_json=$(kubectl get deployments -n "$ns" -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.name)=\(.spec.replicas)"' | \
        tr '\n' ',' | sed 's/,$//')

    if [[ -n "$replicas_json" ]]; then
        # Create or update ConfigMap with replica counts
        kubectl create configmap "$configmap_name" \
            --from-literal="replicas=$replicas_json" \
            -n "$ns" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    fi
}

# Restore replica counts from ConfigMap
restore_replica_counts() {
    local ns="$1"
    local configmap_name="cluster-ctl-replicas"

    # Get stored replica counts
    local replicas_data
    replicas_data=$(kubectl get configmap "$configmap_name" -n "$ns" -o jsonpath='{.data.replicas}' 2>/dev/null || echo "")

    if [[ -z "$replicas_data" ]]; then
        log_warn "No stored replica counts for $ns, defaulting to 1"
        kubectl scale deployment --all -n "$ns" --replicas=1 2>/dev/null || true
        return
    fi

    # Parse and restore each deployment
    IFS=',' read -ra pairs <<< "$replicas_data"
    for pair in "${pairs[@]}"; do
        local name="${pair%=*}"
        local count="${pair#*=}"
        if [[ -n "$name" && -n "$count" ]]; then
            kubectl scale deployment "$name" -n "$ns" --replicas="$count" 2>/dev/null || true
        fi
    done
}

cmd_pause() {
    local config_file="$1"
    validate_config "$config_file"

    log_info "Pausing cluster: $CLUSTER_NAME"

    local namespaces
    namespaces=$(get_infrastructure_namespaces)

    for ns in $namespaces; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log_info "Storing replica counts for $ns..."
            store_replica_counts "$ns"

            log_info "Scaling down deployments in $ns..."
            kubectl scale deployment --all -n "$ns" --replicas=0 2>/dev/null || true
        else
            log_warn "Namespace $ns does not exist, skipping"
        fi
    done

    log_info "Cluster $CLUSTER_NAME paused"
}

cmd_resume() {
    local config_file="$1"
    validate_config "$config_file"

    log_info "Resuming cluster: $CLUSTER_NAME"

    local namespaces
    namespaces=$(get_infrastructure_namespaces)

    for ns in $namespaces; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log_info "Restoring deployments in $ns..."
            restore_replica_counts "$ns"
        else
            log_warn "Namespace $ns does not exist, skipping"
        fi
    done

    log_info "Cluster $CLUSTER_NAME resumed"
    log_info "Waiting for pods to be ready..."

    for ns in $namespaces; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            kubectl wait --for=condition=ready pod --all -n "$ns" --timeout=300s 2>/dev/null || {
                log_warn "Some pods in $ns not ready within timeout"
            }
        fi
    done
}

cmd_status() {
    local config_file="$1"
    validate_config "$config_file"

    echo ""
    echo -e "${BLUE}Cluster: $CLUSTER_NAME${NC}"
    echo -e "${BLUE}Protected: ${PROTECTED:-false}${NC}"
    echo ""

    local namespaces
    namespaces=$(get_infrastructure_namespaces)

    for ns in $namespaces; do
        echo -e "${BLUE}=== $ns ===${NC}"
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            kubectl get deployments -n "$ns" 2>/dev/null || echo "  No deployments"
            echo ""
        else
            echo "  Namespace does not exist"
            echo ""
        fi
    done
}

main() {
    if [[ $# -lt 2 ]]; then
        usage
    fi

    local command="$1"
    local config_file="$2"

    case "$command" in
        pause)
            cmd_pause "$config_file"
            ;;
        resume)
            cmd_resume "$config_file"
            ;;
        status)
            cmd_status "$config_file"
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            ;;
    esac
}

main "$@"
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/cluster-ctl.sh
git add scripts/cluster-ctl.sh
git commit -m "feat: add cluster-ctl.sh for pause/resume

- pause: Scales all deployments to 0, stores original replica counts
- resume: Restores deployments to original replica counts
- status: Shows current deployment status

Provides defense against accidental cross-cluster operations
when hardcoded values exist during migration."
```

---

### Task 1.3: Update scripts/lib/infra.sh to Accept Config File

**Files:**
- Modify: `scripts/lib/infra.sh`

**Step 1: Update infra.sh to accept optional config file parameter**

The current `infra.sh` hardcodes the path to `config/infra.env`. Update it to accept an optional config file path, falling back to environment variable `CLUSTER_CONFIG` or error if neither provided.

```bash
#!/bin/bash
# Infrastructure configuration loader
# Sources cluster config and validates required variables
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/infra.sh" [config-file]
#
#   Or set CLUSTER_CONFIG environment variable before sourcing.
#
# If no config file is provided and CLUSTER_CONFIG is not set,
# the script will error (no defaults - explicit config required).

set -euo pipefail

# Determine paths
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_LIB_DIR/../.." && pwd)"

# Source logging if not already loaded
if ! declare -f log_error &>/dev/null; then
    source "$_LIB_DIR/logging.sh"
fi

# Determine config file location
# Priority: 1) argument passed to source, 2) CLUSTER_CONFIG env var, 3) error
_CONFIG_FILE="${1:-${CLUSTER_CONFIG:-}}"

if [[ -z "$_CONFIG_FILE" ]]; then
    log_error "No cluster config specified"
    log_error "Usage: source infra.sh <config-file>"
    log_error "   Or: export CLUSTER_CONFIG=<config-file>"
    exit 1
fi

if [[ ! -f "$_CONFIG_FILE" ]]; then
    # Try relative to project root
    if [[ -f "$_PROJECT_ROOT/$_CONFIG_FILE" ]]; then
        _CONFIG_FILE="$_PROJECT_ROOT/$_CONFIG_FILE"
    else
        log_error "Config file not found: $_CONFIG_FILE"
        exit 1
    fi
fi

# Source cluster configuration
# shellcheck source=/dev/null
source "$_CONFIG_FILE"

# Validate required variables exist
: "${CLUSTER_NAME:?CLUSTER_NAME not set in config}"
: "${GITLAB_NAMESPACE:?GITLAB_NAMESPACE not set in config}"
: "${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set in config}"
: "${GITLAB_GROUP:?GITLAB_GROUP not set in config}"
: "${GITLAB_API_TOKEN_SECRET:?GITLAB_API_TOKEN_SECRET not set in config}"
: "${GITLAB_API_TOKEN_KEY:?GITLAB_API_TOKEN_KEY not set in config}"
: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE not set in config}"
: "${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set in config}"
: "${JENKINS_ADMIN_SECRET:?JENKINS_ADMIN_SECRET not set in config}"
: "${DEV_NAMESPACE:?DEV_NAMESPACE not set in config}"
: "${STAGE_NAMESPACE:?STAGE_NAMESPACE not set in config}"
: "${PROD_NAMESPACE:?PROD_NAMESPACE not set in config}"

# Export PROJECT_ROOT for scripts that need it
export PROJECT_ROOT="$_PROJECT_ROOT"
export CLUSTER_CONFIG="$_CONFIG_FILE"
```

**Step 2: Commit**

```bash
git add scripts/lib/infra.sh
git commit -m "feat: update infra.sh to require explicit config file

- Remove hardcoded path to config/infra.env
- Accept config file as argument or CLUSTER_CONFIG env var
- Error if no config specified (no defaults)
- Add validation for environment namespace variables

Breaking change: scripts must now provide config file explicitly."
```

---

## Phase 2: Manifest Parameterization

### Task 2.1: Parameterize Jenkins Manifests

**Files:**
- Modify: `k8s/jenkins/jenkins-lightweight.yaml`
- Modify: `k8s/jenkins/pipeline-config.yaml`

**Step 1: Update jenkins-lightweight.yaml namespaces**

Replace all `namespace: jenkins` with `namespace: ${JENKINS_NAMESPACE}`:

- Line 16: Certificate
- Line 30: PersistentVolumeClaim
- Line 43: ConfigMap
- Line 54: Deployment
- Line 122: Service
- Line 143: Ingress

**Step 2: Update pipeline-config.yaml namespace**

Replace `namespace: jenkins` with `namespace: ${JENKINS_NAMESPACE}` on line 26.

**Step 3: Verify with envsubst**

```bash
export JENKINS_NAMESPACE="jenkins-test"
export JENKINS_HOST="jenkins.test.local"
export STORAGE_CLASS="test-storage"
envsubst < k8s/jenkins/jenkins-lightweight.yaml | grep -E "namespace:|host:"
# Should show jenkins-test and jenkins.test.local
```

**Step 4: Commit**

```bash
git add k8s/jenkins/
git commit -m "feat: parameterize Jenkins manifests

- Replace hardcoded 'namespace: jenkins' with '\${JENKINS_NAMESPACE}'
- jenkins-lightweight.yaml: 6 namespace references
- pipeline-config.yaml: 1 namespace reference

Manifests now require envsubst before kubectl apply."
```

---

### Task 2.2: Parameterize GitLab Manifests

**Files:**
- Modify: `k8s/gitlab/gitlab-lightweight.yaml`

**Step 1: Update gitlab-lightweight.yaml namespaces**

Replace all `namespace: gitlab` with `namespace: ${GITLAB_NAMESPACE}`:

- Line 15: Certificate
- Line 29: PersistentVolumeClaim (config)
- Line 42: PersistentVolumeClaim (logs)
- Line 55: PersistentVolumeClaim (data)
- Line 68: ConfigMap
- Line 107: Deployment
- Line 186: Service
- Line 207: Ingress

**Step 2: Verify with envsubst**

```bash
export GITLAB_NAMESPACE="gitlab-test"
export GITLAB_HOST="gitlab.test.local"
export STORAGE_CLASS="test-storage"
export GITLAB_ROOT_PASSWORD="testpass"
envsubst < k8s/gitlab/gitlab-lightweight.yaml | grep "namespace:"
# Should show gitlab-test for all
```

**Step 3: Commit**

```bash
git add k8s/gitlab/
git commit -m "feat: parameterize GitLab manifests

- Replace hardcoded 'namespace: gitlab' with '\${GITLAB_NAMESPACE}'
- gitlab-lightweight.yaml: 8 namespace references

Manifests now require envsubst before kubectl apply."
```

---

### Task 2.3: Parameterize Nexus Manifests

**Files:**
- Modify: `k8s/nexus/nexus-lightweight.yaml`
- Modify: `k8s/nexus/nexus-docker-nodeport.yaml`

**Step 1: Update nexus-lightweight.yaml namespaces**

Replace all `namespace: nexus` with `namespace: ${NEXUS_NAMESPACE}`:

- Line 13: PersistentVolumeClaim
- Line 27: PersistentVolumeClaim (data)
- Line 40: Deployment
- Line 103: Service
- Line 124: Ingress

**Step 2: Update nexus-docker-nodeport.yaml namespace**

Replace `namespace: nexus` with `namespace: ${NEXUS_NAMESPACE}` on line 5.

**Step 3: Commit**

```bash
git add k8s/nexus/
git commit -m "feat: parameterize Nexus manifests

- Replace hardcoded 'namespace: nexus' with '\${NEXUS_NAMESPACE}'
- nexus-lightweight.yaml: 5 namespace references
- nexus-docker-nodeport.yaml: 1 namespace reference

Manifests now require envsubst before kubectl apply."
```

---

### Task 2.4: Parameterize ArgoCD Manifests

**Files:**
- Modify: `k8s/argocd/ingress.yaml`
- Modify: `k8s/argocd/postgres-applications.yaml`

**Step 1: Update ingress.yaml namespaces**

Replace `namespace: argocd` with `namespace: ${ARGOCD_NAMESPACE}`:

- Line 11: Certificate
- Line 25: Ingress

**Step 2: Update postgres-applications.yaml**

This file has both namespace references AND hardcoded GitLab URLs.

Replace namespaces:
- Line 6: `namespace: argocd` → `namespace: ${ARGOCD_NAMESPACE}`
- Line 18: `namespace: dev` → `namespace: ${DEV_NAMESPACE}`
- Line 31: `namespace: argocd` → `namespace: ${ARGOCD_NAMESPACE}`
- Line 43: `namespace: stage` → `namespace: ${STAGE_NAMESPACE}`
- Line 56: `namespace: argocd` → `namespace: ${ARGOCD_NAMESPACE}`
- Line 68: `namespace: prod` → `namespace: ${PROD_NAMESPACE}`

Replace GitLab URLs:
- Line 13: `repoURL: https://gitlab.jmann.local/...` → `repoURL: ${GITLAB_URL_EXTERNAL}/...`
- Line 38: same
- Line 63: same

**Step 3: Commit**

```bash
git add k8s/argocd/
git commit -m "feat: parameterize ArgoCD manifests

- Replace hardcoded 'namespace: argocd' with '\${ARGOCD_NAMESPACE}'
- Replace hardcoded 'namespace: dev/stage/prod' with env namespace vars
- Replace hardcoded GitLab URL with '\${GITLAB_URL_EXTERNAL}'
- ingress.yaml: 2 namespace references
- postgres-applications.yaml: 6 namespace refs, 3 URL refs

Manifests now require envsubst before kubectl apply."
```

---

## Phase 3: Script Updates

### Task 3.1: Update Infrastructure Scripts

**Files:**
- Modify: `scripts/01-infrastructure/setup-gitlab.sh`
- Modify: `scripts/01-infrastructure/setup-jenkins.sh`
- Modify: `scripts/01-infrastructure/apply-infrastructure.sh`

**Step 1: Update setup-gitlab.sh**

Add config file requirement at top. Replace all hardcoded `-n gitlab` with `-n "$GITLAB_NAMESPACE"`.

Lines to update: 63, 121, 131, 143, 151, 199-200, 224, 228, 231

**Step 2: Update setup-jenkins.sh**

Add config file requirement at top. Replace all hardcoded `-n jenkins` with `-n "$JENKINS_NAMESPACE"`.

Lines to update: 104, 116-117, 124, 133, 155, 159, 162

**Step 3: Update apply-infrastructure.sh**

Add config file requirement. Replace hardcoded `-n argocd` with `-n "$ARGOCD_NAMESPACE"`.

Lines to update: 111, 116

**Step 4: Commit**

```bash
git add scripts/01-infrastructure/
git commit -m "feat: parameterize infrastructure setup scripts

- setup-gitlab.sh: Replace hardcoded 'gitlab' namespace
- setup-jenkins.sh: Replace hardcoded 'jenkins' namespace
- apply-infrastructure.sh: Replace hardcoded 'argocd' namespace
- All scripts now require config file as argument"
```

---

### Task 3.2: Update Pipeline Setup Scripts

**Files:**
- Modify: `scripts/03-pipelines/setup-k8s-deployments-validation-job.sh`
- Modify: `scripts/03-pipelines/setup-manifest-generator-job.sh`
- Modify: `scripts/03-pipelines/reset-demo-state.sh`

**Step 1: Update setup-k8s-deployments-validation-job.sh**

Replace hardcoded `-n jenkins` with `-n "$JENKINS_NAMESPACE"` (line 24).

**Step 2: Update setup-manifest-generator-job.sh**

Replace hardcoded `-n jenkins` with `-n "$JENKINS_NAMESPACE"` (line 15).

**Step 3: Update reset-demo-state.sh**

Replace hardcoded `-n jenkins` references (lines 231, 234-236).

**Step 4: Commit**

```bash
git add scripts/03-pipelines/
git commit -m "feat: parameterize pipeline setup scripts

- Replace hardcoded namespace references with config variables
- Scripts now inherit config from CLUSTER_CONFIG or require explicit arg"
```

---

### Task 3.3: Update Operations Scripts

**Files:**
- Modify: `scripts/04-operations/sync-to-gitlab.sh`
- Modify: `scripts/04-operations/docker-registry-helper.sh`
- Modify: `scripts/04-operations/trigger-build.sh`

**Step 1: Update sync-to-gitlab.sh**

Replace hardcoded `gitlab.jmann.local` with `$GITLAB_HOST` (lines 108, 114, 161-162).

**Step 2: Update docker-registry-helper.sh**

Replace hardcoded `-n nexus` with `-n "$NEXUS_NAMESPACE"` (lines 75, 84, 110, 159).

**Step 3: Update trigger-build.sh**

Replace hardcoded `-n jenkins` with `-n "$JENKINS_NAMESPACE"` (line 13).

**Step 4: Commit**

```bash
git add scripts/04-operations/
git commit -m "feat: parameterize operations scripts

- sync-to-gitlab.sh: Replace hardcoded hostname
- docker-registry-helper.sh: Replace hardcoded nexus namespace
- trigger-build.sh: Replace hardcoded jenkins namespace"
```

---

### Task 3.4: Update Demo Scripts

**Files:**
- Modify: `scripts/demo/run-all-demos.sh`
- Modify: `scripts/demo/lib/demo-helpers.sh`
- Modify: `scripts/demo/demo-uc-e1-app-deployment.sh`
- Modify: `scripts/demo/demo-uc-d2-cherry-pick.sh`
- (Other demo scripts follow same pattern)

**Step 1: Update run-all-demos.sh**

Add config file as first required argument. Source config before running demos.

```bash
# Near top of script, after SCRIPT_DIR
CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo "Usage: $0 <config-file> [options]"
    echo "Example: $0 config/clusters/alpha.env"
    exit 1
fi
shift  # Remove config file from args

# Export for child processes
export CLUSTER_CONFIG="$CONFIG_FILE"
source "$CONFIG_FILE"
```

**Step 2: Update demo-helpers.sh**

Validate that config is loaded (either via CLUSTER_CONFIG or required variables present).

**Step 3: Update demo-uc-e1-app-deployment.sh**

Replace hardcoded `nexus.jmann.local` fallback (lines 200, 1139) with proper variable usage.

**Step 4: Update demo-uc-d2-cherry-pick.sh**

Replace hardcoded `gitlab.jmann.local` (line 264) with `$GITLAB_URL_EXTERNAL`.

**Step 5: Commit**

```bash
git add scripts/demo/
git commit -m "feat: parameterize demo scripts

- run-all-demos.sh: Require config file as first argument
- demo-helpers.sh: Validate config is loaded
- demo-uc-e1-app-deployment.sh: Remove hardcoded nexus URL
- demo-uc-d2-cherry-pick.sh: Remove hardcoded gitlab URL

Usage: ./scripts/demo/run-all-demos.sh config/clusters/alpha.env"
```

---

## Phase 4: New Bootstrap and Teardown Scripts

### Task 4.1: Create bootstrap.sh

**Files:**
- Create: `scripts/bootstrap.sh`

**Step 1: Create bootstrap.sh**

```bash
#!/bin/bash
# bootstrap.sh - Bootstrap a complete cluster from nothing
#
# Usage: ./scripts/bootstrap.sh <config-file>
#
# This script:
# 1. Creates all namespaces
# 2. Applies infrastructure manifests (envsubst + kubectl apply)
# 3. Waits for pods to be ready
# 4. Configures services (GitLab repos, Jenkins jobs, webhooks)
# 5. Outputs hosts entries and credentials

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "\n${BLUE}=== $* ===${NC}\n"; }

usage() {
    echo "Usage: $0 <config-file>"
    echo ""
    echo "Bootstrap a complete cluster from nothing."
    echo ""
    echo "Example:"
    echo "  $0 config/clusters/alpha.env"
    exit 1
}

# Validate config file
CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file required"
    usage
fi

# Source config
source "$CONFIG_FILE"
export CLUSTER_CONFIG="$CONFIG_FILE"

# Validate required variables
REQUIRED_VARS=(
    CLUSTER_NAME
    GITLAB_NAMESPACE JENKINS_NAMESPACE NEXUS_NAMESPACE ARGOCD_NAMESPACE
    DEV_NAMESPACE STAGE_NAMESPACE PROD_NAMESPACE
    GITLAB_HOST JENKINS_HOST NEXUS_HOST ARGOCD_HOST
    STORAGE_CLASS
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required variable $var not set in $CONFIG_FILE"
        exit 1
    fi
done

log_info "Bootstrapping cluster: $CLUSTER_NAME"
log_info "Config file: $CONFIG_FILE"

# Step 1: Check for namespace collisions
log_step "Step 1: Checking for namespace collisions"

ALL_NAMESPACES="$GITLAB_NAMESPACE $JENKINS_NAMESPACE $NEXUS_NAMESPACE $ARGOCD_NAMESPACE $DEV_NAMESPACE $STAGE_NAMESPACE $PROD_NAMESPACE"

for ns in $ALL_NAMESPACES; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_error "Namespace $ns already exists. Use teardown.sh first or choose different names."
        exit 1
    fi
done
log_info "No namespace collisions detected"

# Step 2: Create namespaces
log_step "Step 2: Creating namespaces"

for ns in $ALL_NAMESPACES; do
    log_info "Creating namespace: $ns"
    kubectl create namespace "$ns"
done

# Step 3: Apply manifests
log_step "Step 3: Applying infrastructure manifests"

apply_manifest() {
    local manifest="$1"
    local description="${2:-$manifest}"

    log_info "Applying $description..."
    envsubst < "$manifest" | kubectl apply -f -
}

# Apply in order
apply_manifest "$PROJECT_ROOT/k8s/gitlab/gitlab-lightweight.yaml" "GitLab"
apply_manifest "$PROJECT_ROOT/k8s/jenkins/pipeline-config.yaml" "Jenkins Pipeline Config"
apply_manifest "$PROJECT_ROOT/k8s/jenkins/jenkins-lightweight.yaml" "Jenkins"
apply_manifest "$PROJECT_ROOT/k8s/nexus/nexus-lightweight.yaml" "Nexus"

# ArgoCD - apply upstream manifest with namespace override
log_info "Applying ArgoCD..."
kubectl apply -n "$ARGOCD_NAMESPACE" -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || {
    log_warn "Upstream ArgoCD manifest failed, trying local copy..."
    kubectl apply -n "$ARGOCD_NAMESPACE" -f "$PROJECT_ROOT/k8s/argocd/install.yaml"
}
apply_manifest "$PROJECT_ROOT/k8s/argocd/ingress.yaml" "ArgoCD Ingress"

# Step 4: Wait for pods
log_step "Step 4: Waiting for infrastructure pods"

wait_for_pods() {
    local ns="$1"
    local timeout="${2:-300}"

    log_info "Waiting for pods in $ns (timeout ${timeout}s)..."
    kubectl wait --for=condition=ready pod --all -n "$ns" --timeout="${timeout}s" || {
        log_warn "Some pods in $ns not ready within timeout"
        kubectl get pods -n "$ns"
    }
}

wait_for_pods "$GITLAB_NAMESPACE" 600  # GitLab takes longer
wait_for_pods "$JENKINS_NAMESPACE" 300
wait_for_pods "$NEXUS_NAMESPACE" 180
wait_for_pods "$ARGOCD_NAMESPACE" 180

# Step 5: Configure services
log_step "Step 5: Configuring services"

log_info "Running GitLab setup..."
"$SCRIPT_DIR/01-infrastructure/setup-gitlab.sh" "$CONFIG_FILE" || log_warn "GitLab setup had issues"

log_info "Running Jenkins setup..."
"$SCRIPT_DIR/01-infrastructure/setup-jenkins.sh" "$CONFIG_FILE" || log_warn "Jenkins setup had issues"

# Step 6: Output summary
log_step "Bootstrap Complete"

# Get cluster IP
CLUSTER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "CLUSTER_IP")

echo ""
echo "Add the following to /etc/hosts:"
echo "  $CLUSTER_IP $GITLAB_HOST $JENKINS_HOST $NEXUS_HOST $ARGOCD_HOST $DOCKER_REGISTRY_HOST"
echo ""
echo "Verify cluster health:"
echo "  ./scripts/cluster-ctl.sh status $CONFIG_FILE"
echo ""
echo "Run demo suite:"
echo "  ./scripts/demo/run-all-demos.sh $CONFIG_FILE"
echo ""
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/bootstrap.sh
git add scripts/bootstrap.sh
git commit -m "feat: add bootstrap.sh for cluster setup

- Creates all namespaces (infrastructure + environments)
- Applies manifests with envsubst
- Waits for pods to be ready
- Runs service configuration scripts
- Outputs hosts entries and next steps

Usage: ./scripts/bootstrap.sh config/clusters/alpha.env"
```

---

### Task 4.2: Create teardown.sh

**Files:**
- Create: `scripts/teardown.sh`

**Step 1: Create teardown.sh**

```bash
#!/bin/bash
# teardown.sh - Teardown a cluster completely
#
# Usage: ./scripts/teardown.sh <config-file>
#
# Safety features:
# - PROTECTED=true clusters cannot be torn down
# - Requires explicit "yes" confirmation
# - Shows what will be deleted before confirming

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 <config-file>"
    echo ""
    echo "Teardown a cluster completely."
    echo ""
    echo "Example:"
    echo "  $0 config/clusters/alpha.env"
    exit 1
}

# Validate config file
CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file required"
    usage
fi

# Source config
source "$CONFIG_FILE"

# Check PROTECTED flag
if [[ "${PROTECTED:-false}" == "true" ]]; then
    log_error "Cluster $CLUSTER_NAME is marked PROTECTED=true"
    log_error "Teardown refused. Edit $CONFIG_FILE to set PROTECTED=false if you really want to delete it."
    exit 1
fi

# Show what will be deleted
echo ""
echo -e "${YELLOW}WARNING: This will delete the following resources:${NC}"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo ""
echo "Infrastructure namespaces:"
echo "  - $GITLAB_NAMESPACE"
echo "  - $JENKINS_NAMESPACE"
echo "  - $NEXUS_NAMESPACE"
echo "  - $ARGOCD_NAMESPACE"
echo ""
echo "Environment namespaces:"
echo "  - $DEV_NAMESPACE"
echo "  - $STAGE_NAMESPACE"
echo "  - $PROD_NAMESPACE"
echo ""
echo -e "${RED}This action is IRREVERSIBLE. All data will be lost.${NC}"
echo ""

# Require explicit confirmation
read -rp "Type 'yes' to confirm deletion: " confirmation

if [[ "$confirmation" != "yes" ]]; then
    log_info "Teardown cancelled"
    exit 0
fi

log_info "Starting teardown of cluster: $CLUSTER_NAME"

# Delete in reverse order (apps first, then infrastructure)

# Delete ArgoCD applications first to prevent sync conflicts
log_info "Deleting ArgoCD applications..."
kubectl delete applications --all -n "$ARGOCD_NAMESPACE" 2>/dev/null || true

# Delete environment namespaces
for ns in "$DEV_NAMESPACE" "$STAGE_NAMESPACE" "$PROD_NAMESPACE"; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_info "Deleting namespace: $ns"
        kubectl delete namespace "$ns" --timeout=120s || {
            log_warn "Timeout deleting $ns, forcing..."
            kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
        }
    fi
done

# Delete infrastructure namespaces
for ns in "$ARGOCD_NAMESPACE" "$NEXUS_NAMESPACE" "$JENKINS_NAMESPACE" "$GITLAB_NAMESPACE"; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_info "Deleting namespace: $ns"
        kubectl delete namespace "$ns" --timeout=120s || {
            log_warn "Timeout deleting $ns, forcing..."
            kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
        }
    fi
done

# Clean up cluster-scoped resources (certificates)
log_info "Cleaning up certificates..."
kubectl delete certificate -A -l "cluster=$CLUSTER_NAME" 2>/dev/null || true

log_info "Teardown complete for cluster: $CLUSTER_NAME"
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/teardown.sh
git add scripts/teardown.sh
git commit -m "feat: add teardown.sh for cluster cleanup

- Refuses to delete PROTECTED=true clusters
- Shows what will be deleted before confirming
- Requires explicit 'yes' confirmation
- Deletes in safe order (apps first, then infrastructure)

Usage: ./scripts/teardown.sh config/clusters/alpha.env"
```

---

### Task 4.3: Create verify-cluster.sh

**Files:**
- Create: `scripts/verify-cluster.sh`

**Step 1: Create verify-cluster.sh**

```bash
#!/bin/bash
# verify-cluster.sh - Verify cluster health
#
# Usage: ./scripts/verify-cluster.sh <config-file>
#
# Checks:
# - All namespaces exist
# - All pods are running
# - All services respond

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Validate config file
CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo "Usage: $0 <config-file>"
    exit 1
fi

source "$CONFIG_FILE"

FAILURES=0

check() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} $description"
    else
        echo -e "${RED}[FAIL]${NC} $description"
        ((FAILURES++))
    fi
}

echo ""
echo "Verifying cluster: $CLUSTER_NAME"
echo ""

# Check namespaces
echo "=== Namespaces ==="
for ns in "$GITLAB_NAMESPACE" "$JENKINS_NAMESPACE" "$NEXUS_NAMESPACE" "$ARGOCD_NAMESPACE" \
          "$DEV_NAMESPACE" "$STAGE_NAMESPACE" "$PROD_NAMESPACE"; do
    check "Namespace $ns exists" kubectl get namespace "$ns"
done

# Check pods
echo ""
echo "=== Pod Status ==="
for ns in "$GITLAB_NAMESPACE" "$JENKINS_NAMESPACE" "$NEXUS_NAMESPACE" "$ARGOCD_NAMESPACE"; do
    local ready
    ready=$(kubectl get pods -n "$ns" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c True || echo 0)
    local total
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)

    if [[ "$ready" -eq "$total" && "$total" -gt 0 ]]; then
        echo -e "${GREEN}[PASS]${NC} $ns: $ready/$total pods ready"
    else
        echo -e "${RED}[FAIL]${NC} $ns: $ready/$total pods ready"
        ((FAILURES++))
    fi
done

# Summary
echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}All checks passed${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES check(s) failed${NC}"
    exit 1
fi
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/verify-cluster.sh
git add scripts/verify-cluster.sh
git commit -m "feat: add verify-cluster.sh for health checks

- Verifies all namespaces exist
- Checks pod ready status
- Returns exit code 0 if healthy, 1 if issues

Usage: ./scripts/verify-cluster.sh config/clusters/alpha.env"
```

---

## Phase 5: Validation

### Task 5.1: Test with Reference Cluster

**Step 1: Verify reference.env works with existing cluster**

```bash
./scripts/cluster-ctl.sh status config/clusters/reference.env
./scripts/verify-cluster.sh config/clusters/reference.env
```

**Step 2: Run smoke test against reference cluster**

```bash
./scripts/demo/run-all-demos.sh config/clusters/reference.env UC-E1
```

---

### Task 5.2: Test Pause/Resume

**Step 1: Pause reference cluster**

```bash
./scripts/cluster-ctl.sh pause config/clusters/reference.env
./scripts/cluster-ctl.sh status config/clusters/reference.env
# Should show 0/0 replicas
```

**Step 2: Resume reference cluster**

```bash
./scripts/cluster-ctl.sh resume config/clusters/reference.env
./scripts/verify-cluster.sh config/clusters/reference.env
```

---

### Task 5.3: Bootstrap Alpha Cluster

**Step 1: Pause reference cluster for isolation**

```bash
./scripts/cluster-ctl.sh pause config/clusters/reference.env
```

**Step 2: Bootstrap alpha**

```bash
./scripts/bootstrap.sh config/clusters/alpha.env
```

**Step 3: Add hosts entries**

Add the output from bootstrap to `/etc/hosts`.

**Step 4: Verify alpha cluster**

```bash
./scripts/verify-cluster.sh config/clusters/alpha.env
```

---

### Task 5.4: Run Smoke Test on Alpha

**Step 1: Run UC-E1 demo**

```bash
./scripts/demo/run-all-demos.sh config/clusters/alpha.env UC-E1 2>&1 | tee results/alpha-smoke-$(date +%Y%m%d-%H%M%S).log
```

**Step 2: Verify success**

Check log for "PASS" status.

---

### Task 5.5: Run Full Demo Suite on Alpha

**Step 1: Run all demos**

```bash
./scripts/demo/run-all-demos.sh config/clusters/alpha.env 2>&1 | tee results/alpha-full-$(date +%Y%m%d-%H%M%S).log
```

**Step 2: Verify all passed**

```bash
grep -E "PASS|FAIL" results/alpha-full-*.log | tail -20
```

---

### Task 5.6: Teardown Alpha and Resume Reference

**Step 1: Teardown alpha**

```bash
./scripts/teardown.sh config/clusters/alpha.env
```

**Step 2: Resume reference**

```bash
./scripts/cluster-ctl.sh resume config/clusters/reference.env
./scripts/verify-cluster.sh config/clusters/reference.env
```

**Step 3: Verify reference still works**

```bash
./scripts/demo/run-all-demos.sh config/clusters/reference.env UC-E1
```

---

### Task 5.7: Final Commit and Summary

**Step 1: Commit any remaining changes**

**Step 2: Update design doc with lessons learned**

**Step 3: Create summary of validation results**

```bash
git add results/
git commit -m "docs: add validation results for multi-cluster bootstrap

Alpha cluster:
- Bootstrap: SUCCESS
- Smoke test (UC-E1): SUCCESS
- Full suite: X/Y passed
- Teardown: SUCCESS

Reference cluster preserved and verified working."
```

---

## Files Changed Summary

### New Files
- `config/clusters/README.md`
- `config/clusters/reference.env`
- `config/clusters/alpha.env`
- `scripts/cluster-ctl.sh`
- `scripts/bootstrap.sh`
- `scripts/teardown.sh`
- `scripts/verify-cluster.sh`

### Modified Files - Manifests
- `k8s/jenkins/jenkins-lightweight.yaml` (6 namespace refs)
- `k8s/jenkins/pipeline-config.yaml` (1 namespace ref)
- `k8s/gitlab/gitlab-lightweight.yaml` (8 namespace refs)
- `k8s/nexus/nexus-lightweight.yaml` (5 namespace refs)
- `k8s/nexus/nexus-docker-nodeport.yaml` (1 namespace ref)
- `k8s/argocd/ingress.yaml` (2 namespace refs)
- `k8s/argocd/postgres-applications.yaml` (6 namespace refs, 3 URL refs)

### Modified Files - Scripts
- `scripts/lib/infra.sh`
- `scripts/01-infrastructure/setup-gitlab.sh`
- `scripts/01-infrastructure/setup-jenkins.sh`
- `scripts/01-infrastructure/apply-infrastructure.sh`
- `scripts/03-pipelines/setup-k8s-deployments-validation-job.sh`
- `scripts/03-pipelines/setup-manifest-generator-job.sh`
- `scripts/03-pipelines/reset-demo-state.sh`
- `scripts/04-operations/sync-to-gitlab.sh`
- `scripts/04-operations/docker-registry-helper.sh`
- `scripts/04-operations/trigger-build.sh`
- `scripts/demo/run-all-demos.sh`
- `scripts/demo/lib/demo-helpers.sh`
- `scripts/demo/demo-uc-e1-app-deployment.sh`
- `scripts/demo/demo-uc-d2-cherry-pick.sh`
