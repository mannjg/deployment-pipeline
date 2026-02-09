#!/bin/bash
#
# setup-gitlab-env-branches.sh
# Initial Bootstrap: Create environment branches in GitLab k8s-deployments repo
#
# This script creates dev, stage, and prod branches from main ONLY if they
# don't exist or have empty env.cue files. It transforms example-env.cue into
# env.cue with environment-specific placeholder values.
#
# IMPORTANT: This is for INITIAL BOOTSTRAP only. Once branches have valid
# CI/CD-managed images (from Jenkins builds), do NOT use this script.
# Use reset-demo-state.sh instead to clean up MRs for fresh validation runs.
#
# Prerequisites:
# 1. GitLab k8s-deployments repo exists with main branch
# 2. main branch has example-env.cue template
# 3. GITLAB_TOKEN env var set, or gitlab-api-token K8s secret exists
#
# Usage:
#   ./scripts/03-pipelines/setup-gitlab-env-branches.sh <config-file>
#
# For demo reset (preserves valid images):
#   ./scripts/03-pipelines/reset-demo-state.sh <config-file>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[→]${NC} $1"; }

# Source infrastructure config via lib/infra.sh
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

# Note: --reset flag has been removed. Use reset-demo-state.sh instead.
# This script ONLY does initial bootstrap (creates branches if they don't exist
# or have empty env.cue files).

# =============================================================================
# Preflight Checks - Validate all required parameters before starting
# =============================================================================
preflight_checks() {
    log_step "Running preflight checks..."
    local failed=0

    # Check required infra.env variables
    if [[ -z "${GITLAB_HOST_EXTERNAL:-}" ]]; then
        log_error "GITLAB_HOST_EXTERNAL not set in cluster config"
        failed=1
    fi

    if [[ -z "${GITLAB_NAMESPACE:-}" ]]; then
        log_error "GITLAB_NAMESPACE not set in cluster config"
        failed=1
    fi

    if [[ -z "${DEPLOYMENTS_REPO_PATH:-}" ]]; then
        log_error "DEPLOYMENTS_REPO_PATH not set in cluster config"
        failed=1
    fi

    if [[ -z "${GITLAB_API_TOKEN_SECRET:-}" ]]; then
        log_error "GITLAB_API_TOKEN_SECRET not set in cluster config"
        failed=1
    fi

    if [[ -z "${GITLAB_API_TOKEN_KEY:-}" ]]; then
        log_error "GITLAB_API_TOKEN_KEY not set in cluster config"
        failed=1
    fi

    if [[ -z "${GITLAB_USER_SECRET:-}" ]]; then
        log_error "GITLAB_USER_SECRET not set in cluster config"
        failed=1
    fi

    if [[ -z "${GITLAB_USER_KEY:-}" ]]; then
        log_error "GITLAB_USER_KEY not set in cluster config"
        failed=1
    fi

    # Get GITLAB_USER (env var or K8s secret)
    GITLAB_USER="${GITLAB_USER:-}"
    if [[ -z "$GITLAB_USER" ]]; then
        GITLAB_USER=$(kubectl get secret "${GITLAB_USER_SECRET}" -n "${GITLAB_NAMESPACE}" -o jsonpath="{.data.${GITLAB_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "$GITLAB_USER" ]]; then
        log_error "GITLAB_USER not set and could not retrieve from K8s secret '${GITLAB_USER_SECRET}'"
        echo "  Set it with: export GITLAB_USER='your-gitlab-username'"
        echo "  Or ensure K8s secret exists: kubectl get secret ${GITLAB_USER_SECRET} -n ${GITLAB_NAMESPACE}"
        failed=1
    fi

    # Get GITLAB_TOKEN (env var or K8s secret)
    GITLAB_TOKEN="${GITLAB_TOKEN:-}"
    if [[ -z "$GITLAB_TOKEN" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "${GITLAB_API_TOKEN_SECRET}" -n "${GITLAB_NAMESPACE}" -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "$GITLAB_TOKEN" ]]; then
        log_error "GITLAB_TOKEN not set and could not retrieve from K8s secret '${GITLAB_API_TOKEN_SECRET}'"
        echo "  Set it with: export GITLAB_TOKEN='your-token'"
        echo "  Or ensure K8s secret exists: kubectl get secret ${GITLAB_API_TOKEN_SECRET} -n ${GITLAB_NAMESPACE}"
        failed=1
    fi

    # Check required tools
    if ! command -v git &> /dev/null; then
        log_error "git command not found"
        failed=1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl command not found (needed for K8s secret retrieval)"
        failed=1
    fi

    if [[ $failed -eq 1 ]]; then
        echo ""
        log_error "Preflight checks failed - fix the above issues and retry"
        exit 1
    fi

    log_info "Preflight checks passed"
    echo ""
}

# Run preflight checks
preflight_checks

# Validate required cluster configuration
: "${DEV_NAMESPACE:?DEV_NAMESPACE must be set in cluster config}"
: "${STAGE_NAMESPACE:?STAGE_NAMESPACE must be set in cluster config}"
: "${PROD_NAMESPACE:?PROD_NAMESPACE must be set in cluster config}"
: "${CONTAINER_REGISTRY_HOST:?CONTAINER_REGISTRY_HOST must be set in cluster config}"

# Environment-specific configurations
declare -A ENV_REPLICAS=( ["dev"]="1" ["stage"]="2" ["prod"]="3" )
declare -A ENV_DEBUG=( ["dev"]="true" ["stage"]="false" ["prod"]="false" )
declare -A ENV_LOG_LEVEL=( ["dev"]="DEBUG" ["stage"]="INFO" ["prod"]="WARN" )
declare -A ENV_CPU_REQUEST=( ["dev"]="100m" ["stage"]="200m" ["prod"]="500m" )
declare -A ENV_CPU_LIMIT=( ["dev"]="500m" ["stage"]="1000m" ["prod"]="2000m" )
declare -A ENV_MEM_REQUEST=( ["dev"]="256Mi" ["stage"]="512Mi" ["prod"]="1Gi" )
declare -A ENV_MEM_LIMIT=( ["dev"]="512Mi" ["stage"]="1Gi" ["prod"]="2Gi" )
declare -A ENV_STORAGE=( ["dev"]="5Gi" ["stage"]="10Gi" ["prod"]="50Gi" )

# Cluster-specific namespace mapping
declare -A ENV_NAMESPACE=(
    ["dev"]="${DEV_NAMESPACE}"
    ["stage"]="${STAGE_NAMESPACE}"
    ["prod"]="${PROD_NAMESPACE}"
)

# Docker registry URL for images (external registry via HTTPS, no port needed)
CONTAINER_REGISTRY="${CONTAINER_REGISTRY_HOST}"

# Initial placeholder image tag - deliberately non-existent to signal that CI/CD
# hasn't built a real image yet. The Jenkinsfile detects this tag and skips ArgoCD
# health checks, since there's nothing deployable until the first app build completes.
SEED_IMAGE_TAG="does-not-exist"

# Temp directory for operations
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo ""
echo "=== GitLab Environment Branches Setup ==="
echo ""
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Repo:   ${DEPLOYMENTS_REPO_PATH}"
log_info "Work:   ${WORK_DIR}"
echo ""

# Clone repository
log_step "Cloning k8s-deployments from GitLab..."
REPO_URL="https://${GITLAB_USER}:${GITLAB_TOKEN}@${GITLAB_HOST_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"
GIT_SSL_NO_VERIFY=true git clone "$REPO_URL" "$WORK_DIR/k8s-deployments" 2>&1 | grep -v "^Cloning\|^remote:" || true
cd "$WORK_DIR/k8s-deployments"

# Configure git
git config user.name "Setup Script"
git config user.email "setup@local"

# Verify example-env.cue exists on main
if [[ ! -f "example-env.cue" ]]; then
    log_error "example-env.cue not found on main branch"
    log_error "Ensure the template file exists before running this script"
    exit 1
fi

log_info "Found example-env.cue on main branch"

# Transform example-env.cue into env.cue for an environment
transform_env_config() {
    local env=$1
    local source_file=$2
    local target_file=$3

    log_info "Transforming ${source_file} → ${target_file} for ${env}"

    # Read source and transform
    # 1. Replace environment name (dev: → stage:, etc.)
    # 2. Replace namespace values
    # 3. Replace environment labels
    # 4. Update replicas
    # 5. Update debug setting
    # 6. Update log level
    # 7. Update resource limits

    # Get cluster-specific namespace for this environment
    local target_namespace="${ENV_NAMESPACE[$env]}"

    sed -e "s/^dev:/${env}:/g" \
        -e "s/namespace: \"dev\"/namespace: \"${target_namespace}\"/g" \
        -e "s/environment: \"dev\"/environment: \"${env}\"/g" \
        -e "s/value: \"dev\"/value: \"${env}\"/g" \
        -e "s/replicas: 1/replicas: ${ENV_REPLICAS[$env]}/g" \
        -e "s/debug: true/debug: ${ENV_DEBUG[$env]}/g" \
        -e "s/value: \"DEBUG\"/value: \"${ENV_LOG_LEVEL[$env]}\"/g" \
        -e "s/cpu:    \"500m\"/cpu:    \"${ENV_CPU_LIMIT[$env]}\"/g" \
        -e "s/cpu:    \"100m\"/cpu:    \"${ENV_CPU_REQUEST[$env]}\"/g" \
        -e "s/memory: \"512Mi\"/memory: \"${ENV_MEM_LIMIT[$env]}\"/g" \
        -e "s/memory: \"256Mi\"/memory: \"${ENV_MEM_REQUEST[$env]}\"/g" \
        -e "s/storageSize: \"5Gi\"/storageSize: \"${ENV_STORAGE[$env]}\"/g" \
        -e "s|// Example environment configuration|// ${env^} environment configuration|g" \
        -e "s|// Example:|// ${env^}:|g" \
        -e "s|log-level\":     \"debug\"|log-level\":     \"${ENV_LOG_LEVEL[$env],,}\"|g" \
        -e "s|REGISTRY_URL_NOT_SET|${CONTAINER_REGISTRY}|g" \
        -e "s|IMAGE_TAG_NOT_SET|${SEED_IMAGE_TAG}|g" \
        "$source_file" > "$target_file"

    # Update comment header for non-dev environments
    if [[ "$env" != "dev" ]]; then
        sed -i "s|Development environment settings|${env^} environment settings|g" "$target_file"
        sed -i "s|// Change \"dev\" to your environment|// ${env^} environment|g" "$target_file"
    fi
}

# Setup an environment branch
setup_env_branch() {
    local env=$1
    local parent_branch=$2

    log_step "Setting up ${env} branch (from ${parent_branch})..."

    # Check if branch exists remotely
    local branch_exists=false
    if GIT_SSL_NO_VERIFY=true git ls-remote --heads origin "$env" | grep -q "$env"; then
        branch_exists=true
    fi

    if $branch_exists; then
        # Check if env.cue already has content - if so, skip (preserve CI/CD-managed images)
        GIT_SSL_NO_VERIFY=true git fetch origin "$env" 2>/dev/null || true
        local env_cue_size=$(git cat-file -s "origin/${env}:env.cue" 2>/dev/null || echo "0")
        if [[ "$env_cue_size" -gt 100 ]]; then
            log_info "${env} branch already has populated env.cue (${env_cue_size} bytes), skipping"
            log_info "  (Use reset-demo-state.sh to clean up MRs without destroying branches)"
            return 0
        fi
        log_warn "${env} branch exists but env.cue is empty/small, will populate"
    fi

    # Checkout parent and create/checkout env branch
    git checkout "$parent_branch" 2>/dev/null || git checkout "origin/${parent_branch}" -b "$parent_branch"
    git pull origin "$parent_branch" 2>/dev/null || true

    if $branch_exists; then
        git checkout "$env" 2>/dev/null || git checkout -b "$env" "origin/${env}"
        git pull origin "$env" 2>/dev/null || true
    else
        git checkout -b "$env" 2>/dev/null || git checkout "$env"
    fi

    # Transform example-env.cue to env.cue
    # Always extract from main branch - env branches don't have example-env.cue
    log_info "Extracting example-env.cue from main branch..."
    git show main:example-env.cue > /tmp/example-env.cue.tmp
    transform_env_config "$env" "/tmp/example-env.cue.tmp" "env.cue"
    rm -f /tmp/example-env.cue.tmp

    # Validate CUE
    if command -v cue &> /dev/null; then
        log_info "Validating CUE configuration..."
        if ! cue vet ./env.cue 2>&1; then
            log_error "CUE validation failed for ${env}"
            cat env.cue
            exit 1
        fi
        log_info "CUE validation passed"
    else
        log_warn "CUE not installed, skipping validation"
    fi

    # Generate manifests if script exists
    if [[ -x "./scripts/generate-manifests.sh" ]]; then
        log_info "Generating manifests for ${env}..."
        ./scripts/generate-manifests.sh "$env" 2>&1 || {
            log_warn "Manifest generation failed (may need CUE setup), continuing..."
        }
    fi

    # Commit and push
    git add env.cue manifests/ 2>/dev/null || git add env.cue

    if git diff --cached --quiet; then
        log_info "No changes to commit for ${env}"
    else
        git commit -m "chore: setup ${env} environment configuration

Transformed from example-env.cue with ${env}-specific values:
- Namespace: ${env}
- Replicas: ${ENV_REPLICAS[$env]}
- Debug: ${ENV_DEBUG[$env]}
- Log level: ${ENV_LOG_LEVEL[$env]}

Generated by setup-gitlab-env-branches.sh"
    fi

    log_info "Pushing ${env} branch to GitLab..."
    GIT_SSL_NO_VERIFY=true git push -u origin "$env" --force-with-lease 2>&1 || \
        GIT_SSL_NO_VERIFY=true git push -u origin "$env" --force 2>&1

    log_info "✓ ${env} branch setup complete"
    echo ""
}

# Setup all environment branches
setup_env_branch "dev" "main"
setup_env_branch "stage" "main"
setup_env_branch "prod" "main"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
log_info "Environment branches in GitLab:"
log_info "  - dev:   ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}/-/tree/dev"
log_info "  - stage: ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}/-/tree/stage"
log_info "  - prod:  ${GITLAB_URL_EXTERNAL}/${DEPLOYMENTS_REPO_PATH}/-/tree/prod"
echo ""
log_info "Next steps:"
echo "  1. Run pipeline validation: ./scripts/test/validate-pipeline.sh"
echo "  2. After validation succeeds, branches will have valid CI/CD-managed images"
echo ""
log_warn "For future demo resets (preserves valid images):"
echo "  ./scripts/03-pipelines/reset-demo-state.sh"
echo ""
