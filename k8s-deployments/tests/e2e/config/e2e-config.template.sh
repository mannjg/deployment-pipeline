#!/bin/bash
# E2E Pipeline Test Configuration Template
# Copy this file to e2e-config.sh and fill in your values

# =============================================================================
# Jenkins Configuration
# =============================================================================

# Jenkins API URL (e.g., http://jenkins.jenkins.svc.cluster.local or https://jenkins.example.com)
export JENKINS_URL="${JENKINS_URL:-http://jenkins.jenkins.svc.cluster.local}"

# Jenkins authentication
export JENKINS_USER="${JENKINS_USER:-admin}"
export JENKINS_TOKEN="${JENKINS_TOKEN:-}"  # Set this to your Jenkins API token

# Jenkins job to trigger
export JENKINS_JOB_NAME="${JENKINS_JOB_NAME:-example-app-build}"

# Optional: Jenkins build parameters (space-separated, e.g., "PARAM1=value1 PARAM2=value2")
export JENKINS_BUILD_PARAMS="${JENKINS_BUILD_PARAMS:-}"

# Build timeout in seconds (default: 600 = 10 minutes)
export JENKINS_BUILD_TIMEOUT="${JENKINS_BUILD_TIMEOUT:-600}"

# =============================================================================
# GitLab Configuration
# =============================================================================

# GitLab API URL (e.g., http://gitlab.gitlab.svc.cluster.local or https://gitlab.example.com)
export GITLAB_URL="${GITLAB_URL:-http://gitlab.gitlab.svc.cluster.local}"

# GitLab API token (personal access token or project access token)
export GITLAB_TOKEN="${GITLAB_TOKEN:-}"  # Set this to your GitLab token

# GitLab project URL will be determined from git remote, but you can override it
# export GITLAB_PROJECT_ID="group%2Fproject"

# Require approvals for merge requests (true/false)
export REQUIRE_APPROVALS="${REQUIRE_APPROVALS:-false}"

# =============================================================================
# Git Branch Configuration
# =============================================================================

# Branch names for each environment
export DEV_BRANCH="${DEV_BRANCH:-dev}"
export STAGE_BRANCH="${STAGE_BRANCH:-stage}"
export PROD_BRANCH="${PROD_BRANCH:-main}"

# =============================================================================
# Application Configuration
# =============================================================================

# Application/service name as it appears in Kubernetes
export APP_NAME="${APP_NAME:-example-app}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-example-app}"
export SERVICE_NAME="${SERVICE_NAME:-example-app}"
export APP_SELECTOR="${APP_SELECTOR:-example-app}"

# ArgoCD application name prefix (actual names will be {PREFIX}-{env})
export ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-example-app}"

# =============================================================================
# ArgoCD Configuration
# =============================================================================

# How long to wait after a commit before checking ArgoCD sync status
export ARGOCD_SYNC_WAIT="${ARGOCD_SYNC_WAIT:-30}"

# Timeout for ArgoCD sync operations (seconds)
export ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-300}"

# Timeout for ArgoCD health checks (seconds)
export ARGOCD_HEALTH_TIMEOUT="${ARGOCD_HEALTH_TIMEOUT:-300}"

# =============================================================================
# Kubernetes Configuration
# =============================================================================

# Timeout for pod readiness checks (seconds)
export POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-300}"

# =============================================================================
# Version Tracking (Optional)
# =============================================================================

# File used for version bumps in test commits
export E2E_VERSION_FILE="${E2E_VERSION_FILE:-VERSION.txt}"

# Command to check deployed version (optional, leave empty if not applicable)
# Example: export VERSION_CHECK_COMMAND="kubectl exec -n dev deployment/example-app -- cat /app/VERSION"
export VERSION_CHECK_COMMAND="${VERSION_CHECK_COMMAND:-}"

# =============================================================================
# Health Check Endpoints (Optional)
# =============================================================================

# Health check endpoints for each environment (leave empty if not accessible)
# These should be accessible from where the test runs
export DEV_HEALTH_ENDPOINT="${DEV_HEALTH_ENDPOINT:-}"
export STAGE_HEALTH_ENDPOINT="${STAGE_HEALTH_ENDPOINT:-}"
export PROD_HEALTH_ENDPOINT="${PROD_HEALTH_ENDPOINT:-}"

# Examples:
# export DEV_HEALTH_ENDPOINT="http://example-app.dev.svc.cluster.local/health"
# export STAGE_HEALTH_ENDPOINT="http://example-app.stage.svc.cluster.local/health"
# export PROD_HEALTH_ENDPOINT="http://example-app.prod.svc.cluster.local/health"

# =============================================================================
# Safety Features
# =============================================================================

# Enable production safety check (adds additional wait before prod merge)
export PROD_SAFETY_CHECK="${PROD_SAFETY_CHECK:-true}"

# How long to wait before merging to production (seconds)
export PROD_SAFETY_WAIT="${PROD_SAFETY_WAIT:-30}"

# =============================================================================
# Test State and Artifacts
# =============================================================================

# Directory for storing test state and artifacts
export E2E_STATE_DIR="${E2E_STATE_DIR:-${SCRIPT_DIR:-/tmp}/state/$(date +%Y%m%d-%H%M%S)}"

# =============================================================================
# Debugging and Logging
# =============================================================================

# Enable verbose output
export VERBOSE="${VERBOSE:-false}"

# Enable debug mode (very verbose)
export DEBUG="${DEBUG:-false}"

# =============================================================================
# Validation
# =============================================================================

# Verify required variables are set
if [ -z "${JENKINS_TOKEN}" ]; then
    echo "WARNING: JENKINS_TOKEN is not set"
fi

if [ -z "${GITLAB_TOKEN}" ]; then
    echo "WARNING: GITLAB_TOKEN is not set"
fi

# =============================================================================
# Notes
# =============================================================================

# This configuration file is sourced by the E2E test scripts.
#
# Required tokens:
# - JENKINS_TOKEN: Create in Jenkins at /user/{username}/configure -> API Token
# - GITLAB_TOKEN: Create in GitLab at /-/profile/personal_access_tokens
#   Required scopes: api, read_repository, write_repository
#
# The test will:
# 1. Create a test commit on the dev branch
# 2. Trigger a Jenkins build
# 3. Verify deployment to dev
# 4. Create and merge MR from dev to stage
# 5. Verify deployment to stage
# 6. Create and merge MR from stage to prod
# 7. Verify deployment to prod
#
# Total estimated time: 15-25 minutes depending on build and deployment times
