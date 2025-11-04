#!/bin/bash
# E2E Pipeline Test Configuration
# Auto-configured from ACCESS.md

# =============================================================================
# Jenkins Configuration
# =============================================================================

export JENKINS_URL="http://jenkins.local"
export JENKINS_USER="admin"
# Note: For API token, create one at Jenkins → User → Configure → API Token
# For now using password for basic auth (works with Jenkins API)
export JENKINS_TOKEN="admin"
export JENKINS_JOB_NAME="example-app-ci"

# Optional: Jenkins build parameters
export JENKINS_BUILD_PARAMS=""

# Build timeout in seconds (default: 600 = 10 minutes)
export JENKINS_BUILD_TIMEOUT="600"

# =============================================================================
# GitLab Configuration
# =============================================================================

export GITLAB_URL="http://gitlab.local"
export GITLAB_TOKEN="glpat-9m86y9YHyGf77Kr8bRjX"

# Require approvals for merge requests
export REQUIRE_APPROVALS="false"

# =============================================================================
# Git Branch Configuration
# =============================================================================

export DEV_BRANCH="dev"
export STAGE_BRANCH="stage"
export PROD_BRANCH="prod"

# =============================================================================
# Repository Configuration
# =============================================================================

# Which repository to test (example-app or k8s-deployments)
# Both trigger the same promotion pipeline
export TEST_REPO="${TEST_REPO:-example-app}"

# Repository paths (relative to deployment-pipeline root)
export EXAMPLE_APP_PATH="example-app"
export K8S_DEPLOYMENTS_PATH="k8s-deployments"

# =============================================================================
# Application Configuration
# =============================================================================

export APP_NAME="example-app"
export DEPLOYMENT_NAME="example-app"
export SERVICE_NAME="example-app"
export APP_SELECTOR="example-app"

# ArgoCD application name prefix
export ARGOCD_APP_PREFIX="example-app"

# =============================================================================
# ArgoCD Configuration
# =============================================================================

# How long to wait after a commit before checking ArgoCD sync status
export ARGOCD_SYNC_WAIT="30"

# Timeout for ArgoCD sync operations (seconds)
export ARGOCD_SYNC_TIMEOUT="300"

# Timeout for ArgoCD health checks (seconds)
export ARGOCD_HEALTH_TIMEOUT="300"

# =============================================================================
# Kubernetes Configuration
# =============================================================================

# Timeout for pod readiness checks (seconds)
export POD_READY_TIMEOUT="300"

# =============================================================================
# Version Tracking (Optional)
# =============================================================================

# File used for version bumps in test commits
export E2E_VERSION_FILE="VERSION.txt"

# Command to check deployed version (optional)
export VERSION_CHECK_COMMAND=""

# =============================================================================
# Health Check Endpoints (Optional)
# =============================================================================

# Health check endpoints - these are internal cluster URLs
# Uncomment if you want to test them (requires cluster network access)
# export DEV_HEALTH_ENDPOINT="http://example-app.dev.svc.cluster.local:8080/api/greetings"
# export STAGE_HEALTH_ENDPOINT="http://example-app.stage.svc.cluster.local:8080/api/greetings"
# export PROD_HEALTH_ENDPOINT="http://example-app.prod.svc.cluster.local:8080/api/greetings"

# =============================================================================
# Safety Features
# =============================================================================

# Enable production safety check
export PROD_SAFETY_CHECK="true"

# How long to wait before merging to production (seconds)
export PROD_SAFETY_WAIT="30"

# =============================================================================
# Test State and Artifacts
# =============================================================================

# Directory for storing test state and artifacts
export E2E_STATE_DIR="${SCRIPT_DIR:-/tmp}/state/$(date +%Y%m%d-%H%M%S)"

# =============================================================================
# Debugging and Logging
# =============================================================================

export VERBOSE=0
export DEBUG=0

# =============================================================================
# Configuration validated
# =============================================================================

echo "✓ E2E configuration loaded"
echo "  Jenkins: $JENKINS_URL"
echo "  GitLab: $GITLAB_URL"
echo "  Job: $JENKINS_JOB_NAME"
echo "  Branches: $DEV_BRANCH → $STAGE_BRANCH → $PROD_BRANCH"
