#!/bin/bash
# Demo: App Code + Config Change Together (UC-E2)
#
# This demo proves that code changes bundled with deployment/app.cue changes
# flow through the pipeline atomically - the new image and new config deploy
# together, avoiding partial states.
#
# Use Case UC-E2:
# "As a developer, I push a code change that also requires a new environment
# variable, and both flow through the pipeline together"
#
# What This Demonstrates:
# - Code change + deployment/app.cue change in same commit
# - Jenkins builds the new image
# - App CI extracts and merges deployment/app.cue into k8s-deployments
# - Both image update AND config change appear in the same MR
# - Atomic deployment: new env var available when new code runs
#
# Flow:
# 1. Add a new env var reference to example-app code
# 2. Add the env var to deployment/app.cue
# 3. Bump version and commit both changes together
# 4. Push to GitLab, triggering the pipeline
# 5. Verify dev deployment has BOTH new image AND new env var
# 6. Promote through stage → prod
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"
EXAMPLE_APP_DIR="${PROJECT_ROOT}/example-app"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_APP="example-app"
DEMO_ENV_VAR_NAME="UC_E2_FEATURE"
DEMO_ENV_VAR_VALUE="code-config-atomic"
ENVIRONMENTS=("dev" "stage" "prod")

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$PROJECT_ROOT"

demo_init "UC-E2: App Code + Config Change Together"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# TODO: Implement demo steps
demo_fail "Demo not yet implemented"
exit 1
