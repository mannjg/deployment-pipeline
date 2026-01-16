# k8s-deployments Subproject Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add preflight checks, standardize variable names, remove duplicates, and document implicit contracts for k8s-deployments and example-app subprojects.

**Architecture:** Each subproject defines its configuration contract in `config/configmap.schema.yaml`. All scripts and Jenkinsfiles validate required configuration at startup using a shared preflight library. No fallback defaults - fail fast with actionable error messages.

**Tech Stack:** Bash (preflight library), Groovy (Jenkinsfiles), YAML (configuration schemas), Markdown (documentation)

---

## Phase 1: k8s-deployments Configuration Foundation

### Task 1: Create k8s-deployments config directory structure

**Files:**
- Create: `k8s-deployments/config/configmap.schema.yaml`
- Create: `k8s-deployments/config/local.env.example`
- Create: `k8s-deployments/config/README.md`

**Step 1: Create the config directory**

```bash
mkdir -p k8s-deployments/config
```

**Step 2: Create configmap.schema.yaml**

Create file `k8s-deployments/config/configmap.schema.yaml`:

```yaml
# k8s-deployments Configuration Contract
# =====================================
#
# Jenkins pipelines require these variables in pipeline-config ConfigMap.
# Local scripts require these as environment variables or in config/local.env.

required:
  GITLAB_URL_INTERNAL:
    description: "GitLab API URL (cluster-internal)"
    example: "http://gitlab.gitlab.svc.cluster.local"

  GITLAB_GROUP:
    description: "GitLab group/namespace for repositories"
    example: "p2c"

  DEPLOYMENTS_REPO_URL:
    description: "Full Git URL for k8s-deployments repo"
    example: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"

  DOCKER_REGISTRY_EXTERNAL:
    description: "External Docker registry URL (what kubelet pulls from)"
    example: "docker.jmann.local"

  JENKINS_AGENT_IMAGE:
    description: "Custom Jenkins agent image with CUE, kubectl, etc."
    example: "localhost:30500/jenkins-agent-custom:latest"

credentials:
  gitlab-credentials:
    type: "usernamePassword"
    description: "GitLab username/password for git operations"

  gitlab-api-token-secret:
    type: "secretText"
    description: "GitLab API token for MR creation"

  argocd-credentials:
    type: "usernamePassword"
    description: "ArgoCD admin credentials"

conventions:
  branch_naming:
    dev_update: "update-dev-{image_tag}"
    promotion: "promote-{target_env}-{image_tag}"

  manifest_paths:
    pattern: "manifests/{app_cue_name}/{app_cue_name}.yaml"
    example: "manifests/exampleApp/exampleApp.yaml"
    note: "app_cue_name is camelCase CUE key (e.g., exampleApp not example-app)"
```

**Step 3: Create local.env.example**

Create file `k8s-deployments/config/local.env.example`:

```bash
# k8s-deployments Local Development Configuration
# ================================================
# Copy this file to local.env and edit for your environment.
# Run: cp config/local.env.example config/local.env
#
# These variables are required by scripts in this repository.
# See config/configmap.schema.yaml for full documentation.

# GitLab Configuration
export GITLAB_URL_INTERNAL="http://gitlab.gitlab.svc.cluster.local"
export GITLAB_GROUP="p2c"
export DEPLOYMENTS_REPO_URL="http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"

# Docker Registry (external URL that kubelet uses to pull images)
export DOCKER_REGISTRY_EXTERNAL="docker.jmann.local"

# GitLab API Token (create at GitLab → Settings → Access Tokens)
# Required scopes: api, read_repository, write_repository
export GITLAB_TOKEN="your-gitlab-api-token-here"
```

**Step 4: Create config README**

Create file `k8s-deployments/config/README.md`:

```markdown
# Configuration

This directory contains configuration contracts and templates for k8s-deployments.

## Files

- `configmap.schema.yaml` - Configuration contract defining required variables
- `local.env.example` - Template for local development

## Usage

### For Jenkins Pipelines

Configure the `pipeline-config` ConfigMap with variables from `configmap.schema.yaml`.

### For Local Development

```bash
cp config/local.env.example config/local.env
# Edit config/local.env with your values
source config/local.env
```

## Documentation

See [docs/CONFIGURATION.md](../docs/CONFIGURATION.md) for full configuration documentation.
```

**Step 5: Verify files created**

Run: `ls -la k8s-deployments/config/`

Expected: Shows 3 files (configmap.schema.yaml, local.env.example, README.md)

**Step 6: Commit**

```bash
git add k8s-deployments/config/
git commit -m "feat(k8s-deployments): add configuration contract and local env template

- Add configmap.schema.yaml defining required variables
- Add local.env.example template for local development
- Add README pointing to documentation

Part of k8s-deployments cleanup initiative."
```

---

### Task 2: Create preflight.sh library

**Files:**
- Create: `k8s-deployments/scripts/lib/preflight.sh`

**Step 1: Create lib directory**

```bash
mkdir -p k8s-deployments/scripts/lib
```

**Step 2: Create preflight.sh**

Create file `k8s-deployments/scripts/lib/preflight.sh`:

```bash
#!/bin/bash
# Shared preflight check functions for k8s-deployments scripts
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/preflight.sh"
#   preflight_check_required GITLAB_URL_INTERNAL GITLAB_GROUP GITLAB_TOKEN

# Colors for output
_PREFLIGHT_RED='\033[0;31m'
_PREFLIGHT_GREEN='\033[0;32m'
_PREFLIGHT_YELLOW='\033[1;33m'
_PREFLIGHT_NC='\033[0m'

# Check if a single variable is set and non-empty
# Returns 0 if set, 1 if not
preflight_check_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    if [[ -z "$var_value" ]]; then
        echo -e "${_PREFLIGHT_RED}ERROR:${_PREFLIGHT_NC} $var_name not set" >&2
        return 1
    fi
    return 0
}

# Check multiple required variables
# Exits with error if any are missing
preflight_check_required() {
    local failed=0
    local missing=()

    for var in "$@"; do
        if ! preflight_check_var "$var" 2>/dev/null; then
            missing+=("$var")
            failed=1
        fi
    done

    if [[ $failed -eq 1 ]]; then
        echo "" >&2
        echo -e "${_PREFLIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PREFLIGHT_NC}" >&2
        echo -e "${_PREFLIGHT_RED}PREFLIGHT CHECK FAILED${_PREFLIGHT_NC}" >&2
        echo -e "${_PREFLIGHT_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_PREFLIGHT_NC}" >&2
        echo "" >&2
        echo "Missing required configuration:" >&2
        for var in "${missing[@]}"; do
            echo "  - $var" >&2
        done
        echo "" >&2
        echo "For Jenkins: Configure pipeline-config ConfigMap" >&2
        echo "For local:   Copy config/local.env.example to config/local.env and edit" >&2
        echo "See:         docs/CONFIGURATION.md" >&2
        echo "" >&2
        exit 1
    fi

    echo -e "${_PREFLIGHT_GREEN}✓ Preflight checks passed${_PREFLIGHT_NC}"
}

# Check if a command exists
preflight_check_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${_PREFLIGHT_RED}ERROR:${_PREFLIGHT_NC} Required command not found: $cmd" >&2
        if [[ -n "$install_hint" ]]; then
            echo "  Install: $install_hint" >&2
        fi
        return 1
    fi
    return 0
}

# Load local.env if it exists and we're not in Jenkins
preflight_load_local_env() {
    local script_dir="$1"
    local local_env="${script_dir}/../config/local.env"

    # Skip if running in Jenkins (BUILD_URL is set)
    if [[ -n "${BUILD_URL:-}" ]]; then
        return 0
    fi

    if [[ -f "$local_env" ]]; then
        echo -e "${_PREFLIGHT_YELLOW}Loading local configuration from config/local.env${_PREFLIGHT_NC}"
        # shellcheck source=/dev/null
        source "$local_env"
    fi
}
```

**Step 3: Make executable and verify syntax**

```bash
chmod +x k8s-deployments/scripts/lib/preflight.sh
bash -n k8s-deployments/scripts/lib/preflight.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 4: Commit**

```bash
git add k8s-deployments/scripts/lib/preflight.sh
git commit -m "feat(k8s-deployments): add preflight check library

Shared functions for validating required configuration:
- preflight_check_var: Check single variable
- preflight_check_required: Check multiple, exit on failure
- preflight_check_command: Check command availability
- preflight_load_local_env: Load local config when not in Jenkins

Part of k8s-deployments cleanup initiative."
```

---

### Task 3: Create CONFIGURATION.md documentation

**Files:**
- Create: `k8s-deployments/docs/CONFIGURATION.md`

**Step 1: Create CONFIGURATION.md**

Create file `k8s-deployments/docs/CONFIGURATION.md`:

```markdown
# k8s-deployments Configuration Guide

This document describes the configuration requirements for the k8s-deployments subproject.

## Overview

k8s-deployments requires specific environment variables to be configured. These can be provided via:

1. **Jenkins ConfigMap** (`pipeline-config`) - For CI/CD pipelines
2. **Local environment file** (`config/local.env`) - For local development

**Design Principle**: No fallback defaults. Missing configuration causes immediate failure with actionable error messages.

## Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GITLAB_URL_INTERNAL` | GitLab API URL (cluster-internal) | `http://gitlab.gitlab.svc.cluster.local` |
| `GITLAB_GROUP` | GitLab group/namespace for repositories | `p2c` |
| `DEPLOYMENTS_REPO_URL` | Full Git URL for k8s-deployments repo | `http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git` |
| `DOCKER_REGISTRY_EXTERNAL` | External Docker registry URL (what kubelet pulls from) | `docker.jmann.local` |
| `JENKINS_AGENT_IMAGE` | Custom Jenkins agent image | `localhost:30500/jenkins-agent-custom:latest` |

## Required Credentials (Jenkins)

| Credential ID | Type | Description |
|---------------|------|-------------|
| `gitlab-credentials` | Username/Password | GitLab username/password for git operations |
| `gitlab-api-token-secret` | Secret Text | GitLab API token for MR creation |
| `argocd-credentials` | Username/Password | ArgoCD admin credentials |

## Local Development Setup

1. Copy the example configuration:
   ```bash
   cp config/local.env.example config/local.env
   ```

2. Edit `config/local.env` with your values

3. Source before running scripts:
   ```bash
   source config/local.env
   ./scripts/generate-manifests.sh dev
   ```

## Jenkins ConfigMap Setup

Create or update the `pipeline-config` ConfigMap in Jenkins namespace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-config
  namespace: jenkins
data:
  GITLAB_URL_INTERNAL: "http://gitlab.gitlab.svc.cluster.local"
  GITLAB_GROUP: "p2c"
  DEPLOYMENTS_REPO_URL: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"
  DOCKER_REGISTRY_EXTERNAL: "docker.jmann.local"
  JENKINS_AGENT_IMAGE: "localhost:30500/jenkins-agent-custom:latest"
```

## Conventions

### Branch Naming

| Purpose | Pattern | Example |
|---------|---------|---------|
| Dev update MRs | `update-dev-{image_tag}` | `update-dev-1.0.0-abc123` |
| Promotion MRs | `promote-{target_env}-{image_tag}` | `promote-stage-1.0.0-abc123` |

### Manifest Paths

- **Pattern**: `manifests/{app_cue_name}/{app_cue_name}.yaml`
- **Example**: `manifests/exampleApp/exampleApp.yaml`
- **Note**: `app_cue_name` is the camelCase CUE key (e.g., `exampleApp` not `example-app`)

### APP_CUE_NAME Mapping

The root project's `validate-pipeline.sh` requires `APP_CUE_NAME` in `config/infra.env`:
- Maps repository name to CUE manifest name
- Example: `APP_REPO_NAME=example-app` → `APP_CUE_NAME=exampleApp`

## Troubleshooting

### "PREFLIGHT CHECK FAILED" Error

This error indicates missing configuration. The error message lists the missing variables.

**For Jenkins:**
1. Check that `pipeline-config` ConfigMap exists
2. Verify all required variables are present
3. Restart Jenkins to pick up ConfigMap changes

**For Local Development:**
1. Ensure `config/local.env` exists
2. Verify all required variables are set
3. Source the file: `source config/local.env`

### Variable Name Mapping

If migrating from older variable names:

| Old Name (deprecated) | New Name (use this) |
|-----------------------|---------------------|
| `GITLAB_INTERNAL_URL` | `GITLAB_URL_INTERNAL` |
| `DOCKER_REGISTRY` | `DOCKER_REGISTRY_EXTERNAL` |
| `DEPLOYMENT_REPO` | `DEPLOYMENTS_REPO_URL` |

## Configuration Schema

The full configuration contract is defined in `config/configmap.schema.yaml`.

## Related Documentation

- [JENKINS_SETUP.md](JENKINS_SETUP.md) - Jenkins job configuration
- [Root CLAUDE.md](../../CLAUDE.md) - Project overview and conventions
```

**Step 2: Verify file created**

```bash
head -20 k8s-deployments/docs/CONFIGURATION.md
```

**Step 3: Commit**

```bash
git add k8s-deployments/docs/CONFIGURATION.md
git commit -m "docs(k8s-deployments): add CONFIGURATION.md

Documents:
- Required environment variables
- Jenkins ConfigMap setup
- Local development setup
- Branch naming conventions
- Manifest path conventions
- Troubleshooting guide

Part of k8s-deployments cleanup initiative."
```

---

## Phase 2: k8s-deployments Script Updates

### Task 4: Add preflight checks to generate-manifests.sh

**Files:**
- Modify: `k8s-deployments/scripts/generate-manifests.sh`

**Step 1: Add preflight check after shebang**

At the top of `k8s-deployments/scripts/generate-manifests.sh`, after the shebang and before the existing code, add:

```bash
#!/bin/bash
set -euo pipefail

# Generate Kubernetes manifests from CUE configuration
# Usage: ./generate-manifests.sh [environment]
#
# In the branch-per-environment structure:
# - Each branch (dev/stage/prod) has env.cue at root
# - Environment can be auto-detected from env.cue or specified
# - Manifests are generated to manifests/ directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load preflight library and local config
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"

MANIFEST_DIR="${PROJECT_ROOT}/manifests"
```

The rest of the script remains unchanged.

**Step 2: Verify syntax**

```bash
bash -n k8s-deployments/scripts/generate-manifests.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 3: Test the script (dry run)**

```bash
cd k8s-deployments && ./scripts/generate-manifests.sh dev 2>&1 | head -5
```

Expected: Shows "Loading local configuration" or "✓ Preflight checks passed" followed by manifest generation output

**Step 4: Commit**

```bash
git add k8s-deployments/scripts/generate-manifests.sh
git commit -m "feat(k8s-deployments): add preflight checks to generate-manifests.sh

- Load preflight library
- Check for cue command
- Load local.env when running outside Jenkins

Part of k8s-deployments cleanup initiative."
```

---

### Task 5: Add preflight checks to create-gitlab-mr.sh

**Files:**
- Modify: `k8s-deployments/scripts/create-gitlab-mr.sh`

**Step 1: Add preflight check after shebang**

Replace the top section of `k8s-deployments/scripts/create-gitlab-mr.sh` up to and including the GITLAB_GROUP validation with:

```bash
#!/bin/bash
set -euo pipefail

# Create a GitLab merge request using the API
# Usage: ./create-gitlab-mr.sh <source_branch> <target_branch> <title> <description>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load preflight library and local config
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Preflight checks
preflight_check_required GITLAB_URL_INTERNAL GITLAB_GROUP GITLAB_TOKEN

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate arguments
if [ $# -lt 4 ]; then
    log_error "Insufficient arguments"
    echo "Usage: $0 <source_branch> <target_branch> <title> <description>"
    echo ""
    echo "Example:"
    echo "  $0 dev stage 'Promote example-app:1.0.0-abc123' 'Automatic promotion from dev to stage'"
    exit 1
fi

SOURCE_BRANCH=$1
TARGET_BRANCH=$2
TITLE=$3
DESCRIPTION=$4

# GitLab configuration (from preflight-validated environment)
GITLAB_URL=${GITLAB_URL_INTERNAL}
PROJECT_PATH="${GITLAB_GROUP}/k8s-deployments"
PROJECT_PATH_ENCODED=$(echo "$PROJECT_PATH" | sed 's/\//%2F/g')
```

Then remove the old GITLAB_URL, GITLAB_TOKEN, and GITLAB_GROUP validation sections that follow (the script continues from "Debug: Show token length").

**Step 2: Verify syntax**

```bash
bash -n k8s-deployments/scripts/create-gitlab-mr.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 3: Commit**

```bash
git add k8s-deployments/scripts/create-gitlab-mr.sh
git commit -m "feat(k8s-deployments): add preflight checks to create-gitlab-mr.sh

- Use preflight library for variable validation
- Standardize to GITLAB_URL_INTERNAL variable name
- Remove manual variable checks (handled by preflight)

Part of k8s-deployments cleanup initiative."
```

---

### Task 6: Add preflight checks to update-app-image.sh

**Files:**
- Modify: `k8s-deployments/scripts/update-app-image.sh`

**Step 1: Add preflight check after variable declarations**

After the shebang and variable declarations (ENVIRONMENT, APP_NAME, NEW_IMAGE), add the preflight loading:

```bash
#!/bin/bash
set -euo pipefail

# Update application image in environment CUE configuration
# This script safely updates only the specified app's image without affecting other apps
# Usage: ./update-app-image.sh <environment> <app-name> <new-image>

ENVIRONMENT=${1:-}
APP_NAME=${2:-}
NEW_IMAGE=${3:-}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load preflight library and local config
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"

# Colors
```

The rest of the script remains unchanged.

**Step 2: Verify syntax**

```bash
bash -n k8s-deployments/scripts/update-app-image.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 3: Commit**

```bash
git add k8s-deployments/scripts/update-app-image.sh
git commit -m "feat(k8s-deployments): add preflight checks to update-app-image.sh

- Load preflight library
- Check for cue command
- Load local.env when running outside Jenkins

Part of k8s-deployments cleanup initiative."
```

---

### Task 7: Fix validate-cue-config.sh for branch-per-env structure

**Files:**
- Modify: `k8s-deployments/scripts/validate-cue-config.sh`

**Step 1: Rewrite validate-cue-config.sh**

Replace the entire file with:

```bash
#!/bin/bash
# Validates CUE configuration files
# Checks syntax, schema compliance, and imports
#
# Supports both structures:
# - Branch-per-environment: env.cue at root (current)
# - Directory-per-environment: envs/*.cue (legacy)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load preflight library
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"

echo "Validating CUE configuration..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Validating CUE Syntax"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERRORS=0

# Validate services (allow incomplete - these are schemas)
if [ -d "services" ]; then
    echo "Validating services..."
    for file in services/**/*.cue; do
        if [ -f "$file" ]; then
            if cue vet -c=false "$file" 2>&1 | grep -q "error"; then
                echo "✗ Error in $file"
                ERRORS=$((ERRORS + 1))
            else
                echo "✓ $file"
            fi
        fi
    done
fi

# Validate environment configuration
# Support both branch-per-env (env.cue at root) and directory-per-env (envs/*.cue)
echo ""
echo "Validating environment configuration..."

if [ -f "env.cue" ]; then
    # Branch-per-environment structure (current)
    echo "  Structure: branch-per-environment (env.cue at root)"
    if cue vet "env.cue" 2>&1 | grep -q "error"; then
        echo "✗ Error in env.cue"
        cue vet "env.cue" 2>&1 | head -20
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ env.cue"
    fi
elif [ -d "envs" ]; then
    # Directory-per-environment structure (legacy)
    echo "  Structure: directory-per-environment (envs/*.cue)"
    for file in envs/*.cue; do
        if [ -f "$file" ]; then
            if cue vet "$file" 2>&1 | grep -q "error"; then
                echo "✗ Error in $file"
                ERRORS=$((ERRORS + 1))
            else
                echo "✓ $file"
            fi
        fi
    done
else
    echo "⚠ No environment configuration found (env.cue or envs/)"
fi

# Validate k8s templates (allow incomplete)
if [ -d "k8s" ]; then
    echo ""
    echo "Validating k8s templates..."
    for file in k8s/*.cue; do
        if [ -f "$file" ]; then
            if cue vet -c=false "$file" 2>&1 | grep -q "error"; then
                echo "✗ Error in $file"
                ERRORS=$((ERRORS + 1))
            else
                echo "✓ $file"
            fi
        fi
    done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $ERRORS -gt 0 ]; then
    echo "✗ CUE validation failed with $ERRORS error(s)"
    exit 1
else
    echo "✓ All CUE files validated successfully"
    exit 0
fi
```

**Step 2: Verify syntax**

```bash
bash -n k8s-deployments/scripts/validate-cue-config.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 3: Commit**

```bash
git add k8s-deployments/scripts/validate-cue-config.sh
git commit -m "fix(k8s-deployments): update validate-cue-config.sh for branch-per-env

- Add preflight library integration
- Support both env.cue (branch-per-env) and envs/*.cue (legacy)
- Auto-detect structure and validate accordingly

Part of k8s-deployments cleanup initiative."
```

---

### Task 8: Make test-cue-integration.sh generic

**Files:**
- Modify: `k8s-deployments/scripts/test-cue-integration.sh`

**Step 1: Rewrite test-cue-integration.sh**

Replace the entire file with:

```bash
#!/bin/bash
# Integration tests for CUE configuration and manifest generation
# Tests the complete workflow: CUE → Manifest → Validation
#
# Discovers apps dynamically from environment configuration.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load preflight library
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"
preflight_check_command "yq" "https://github.com/mikefarah/yq"

echo "Running CUE integration tests..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Integration Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERRORS=0

# Detect environment structure
if [ -f "env.cue" ]; then
    # Branch-per-environment: test current branch's environment
    DETECTED_ENV=$(grep -m1 'env:' "env.cue" 2>/dev/null | grep -oP '"\K[^"]+' || echo "dev")
    ENVIRONMENTS=("$DETECTED_ENV")
    echo "Structure: branch-per-environment"
    echo "Testing environment: $DETECTED_ENV"
else
    # Directory-per-environment: test all environments
    ENVIRONMENTS=(dev stage prod)
    echo "Structure: directory-per-environment"
    echo "Testing environments: ${ENVIRONMENTS[*]}"
fi

# Test 1: Generate manifests
echo ""
echo "Test 1: Manifest generation"
for env in "${ENVIRONMENTS[@]}"; do
    echo "  Testing $env environment..."

    if [ -f "./scripts/generate-manifests.sh" ]; then
        if ./scripts/generate-manifests.sh "$env" > /dev/null 2>&1; then
            echo "    ✓ Manifest generation succeeded"
        else
            echo "    ✗ Manifest generation failed"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "    ⚠ generate-manifests.sh not found, skipping"
    fi
done

# Test 2: Validate generated manifests exist
echo ""
echo "Test 2: Manifest file validation"
for env in "${ENVIRONMENTS[@]}"; do
    echo "  Checking $env manifests..."

    # Find manifests (could be in manifests/{app}/ or manifests/{env}/)
    manifest_count=$(find manifests -name "*.yaml" -type f 2>/dev/null | wc -l)

    if [ "$manifest_count" -gt 0 ]; then
        echo "    ✓ Found $manifest_count manifest file(s)"

        # Validate YAML syntax for each
        for manifest in manifests/**/*.yaml manifests/*.yaml; do
            if [ -f "$manifest" ]; then
                if yq eval '.' "$manifest" > /dev/null 2>&1; then
                    echo "    ✓ $manifest - YAML valid"
                else
                    echo "    ✗ $manifest - YAML invalid"
                    ERRORS=$((ERRORS + 1))
                fi
            fi
        done
    else
        echo "    ⚠ No manifest files found"
    fi
done

# Test 3: Check required resources in manifests
echo ""
echo "Test 3: Required resources check"
for manifest in manifests/**/*.yaml manifests/*.yaml; do
    if [ -f "$manifest" ]; then
        app_name=$(basename "$manifest" .yaml)
        echo "  Checking $app_name..."

        # Check for Deployment
        if yq eval 'select(.kind == "Deployment")' "$manifest" 2>/dev/null | grep -q "kind"; then
            echo "    ✓ Deployment resource found"
        else
            echo "    ⚠ Deployment resource not found (may be optional)"
        fi

        # Check for Service
        if yq eval 'select(.kind == "Service")' "$manifest" 2>/dev/null | grep -q "kind"; then
            echo "    ✓ Service resource found"
        else
            echo "    ⚠ Service resource not found (may be optional)"
        fi
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $ERRORS -gt 0 ]; then
    echo "✗ Integration tests failed with $ERRORS error(s)"
    exit 1
else
    echo "✓ All integration tests passed"
    exit 0
fi
```

**Step 2: Verify syntax**

```bash
bash -n k8s-deployments/scripts/test-cue-integration.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 3: Commit**

```bash
git add k8s-deployments/scripts/test-cue-integration.sh
git commit -m "fix(k8s-deployments): make test-cue-integration.sh generic

- Auto-detect environment structure (branch-per-env vs directory-per-env)
- Dynamically discover apps instead of hardcoding example-app
- Add preflight library integration
- Improved manifest discovery for different directory structures

Part of k8s-deployments cleanup initiative."
```

---

## Phase 3: k8s-deployments Jenkinsfile Updates

### Task 9: Fix k8s-deployments-validation.Jenkinsfile

**Files:**
- Modify: `k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile`

**Step 1: Update the Jenkinsfile**

Replace the environment block and add Preflight stage. Key changes:

1. Get agent image from environment variable (fail if not set)
2. Add Preflight stage
3. Fix hardcoded URLs to use environment variables
4. Fix path from `example/k8s-deployments` to use `GITLAB_GROUP`

Find and replace the agent image line at the top:

```groovy
// Agent image from environment (ConfigMap) - REQUIRED, no default
def agentImage = System.getenv('JENKINS_AGENT_IMAGE')
if (!agentImage) {
    error "JENKINS_AGENT_IMAGE environment variable is required but not set. Configure it in the pipeline-config ConfigMap."
}
```

Replace the environment block:

```groovy
    environment {
        // Git repository (from pipeline-config ConfigMap)
        GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')
        GITLAB_GROUP = System.getenv('GITLAB_GROUP')
        DEPLOYMENTS_REPO = System.getenv('DEPLOYMENTS_REPO_URL')

        // Credentials
        GITLAB_CREDENTIALS = credentials('gitlab-credentials')
    }
```

Add a Preflight stage after 'Checkout':

```groovy
        stage('Preflight') {
            steps {
                container('validator') {
                    script {
                        echo "=== Preflight Checks ==="

                        def missing = []
                        if (!env.GITLAB_URL) missing.add('GITLAB_URL_INTERNAL')
                        if (!env.GITLAB_GROUP) missing.add('GITLAB_GROUP')
                        if (!env.DEPLOYMENTS_REPO) missing.add('DEPLOYMENTS_REPO_URL')

                        if (missing) {
                            error """Missing required configuration: ${missing.join(', ')}

Configure pipeline-config ConfigMap with these variables.
See: k8s-deployments/docs/CONFIGURATION.md"""
                        }

                        echo "✓ Preflight checks passed"
                        echo "  GITLAB_URL: ${env.GITLAB_URL}"
                        echo "  GITLAB_GROUP: ${env.GITLAB_GROUP}"
                    }
                }
            }
        }
```

In the post block, fix the hardcoded project ID:

Replace:
```groovy
curl -X POST "http://gitlab.gitlab.svc.cluster.local/api/v4/projects/2/statuses/${env.GIT_COMMIT}"
```

With:
```groovy
curl -X POST "${env.GITLAB_URL}/api/v4/projects/${env.GITLAB_GROUP}%2Fk8s-deployments/statuses/${env.GIT_COMMIT}"
```

**Step 2: Commit**

```bash
git add k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile
git commit -m "fix(k8s-deployments): update validation Jenkinsfile

- Add preflight checks for required environment variables
- Standardize variable names to match infra.env
- Replace hardcoded URLs with ConfigMap variables
- Replace hardcoded project ID with path-based API calls

Part of k8s-deployments cleanup initiative."
```

---

### Task 10: Fix Jenkinsfile.promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Step 1: Update environment variable names**

In the environment block, change:
- `GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')` → `GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')`
- `DEPLOY_REGISTRY = System.getenv('DOCKER_REGISTRY')` → `DEPLOY_REGISTRY = System.getenv('DOCKER_REGISTRY_EXTERNAL')`
- `DEPLOYMENT_REPO = System.getenv('DEPLOYMENTS_REPO_URL')` remains the same

In the 'Validate Parameters' stage, update the error messages to match:
- `"GITLAB_INTERNAL_URL not set"` → `"GITLAB_URL_INTERNAL not set"`
- `"DOCKER_REGISTRY not set"` → `"DOCKER_REGISTRY_EXTERNAL not set"`

**Step 2: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "fix(k8s-deployments): standardize variable names in Jenkinsfile.promote

- GITLAB_INTERNAL_URL → GITLAB_URL_INTERNAL
- DOCKER_REGISTRY → DOCKER_REGISTRY_EXTERNAL

Part of k8s-deployments cleanup initiative."
```

---

### Task 11: Fix Jenkinsfile.auto-promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote`

**Step 1: Update environment variable names**

In the environment block, change:
- `GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')` → `GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')`

In the 'Validate Environment' stage, update:
- `"GITLAB_INTERNAL_URL not set"` → `"GITLAB_URL_INTERNAL not set"`

**Step 2: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote
git commit -m "fix(k8s-deployments): standardize variable names in Jenkinsfile.auto-promote

- GITLAB_INTERNAL_URL → GITLAB_URL_INTERNAL

Part of k8s-deployments cleanup initiative."
```

---

### Task 12: Fix k8s-deployments root Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile`

**Step 1: Update agent image handling**

At the top, change:
```groovy
def agentImage = System.getenv('JENKINS_AGENT_IMAGE') ?: 'jenkins/inbound-agent:latest-jdk21'
```

To:
```groovy
def agentImage = System.getenv('JENKINS_AGENT_IMAGE')
if (!agentImage) {
    error "JENKINS_AGENT_IMAGE environment variable is required but not set. Configure it in the pipeline-config ConfigMap."
}
```

**Step 2: Update environment variable names**

In the environment block, change:
- `GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')` → `GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')`
- `DEPLOYMENTS_REPO = System.getenv('DEPLOYMENTS_REPO_URL')` remains the same

**Step 3: Fix hardcoded project IDs in post blocks**

Replace all occurrences of:
```groovy
"${env.GITLAB_URL}/api/v4/projects/2/merge_requests/${params.MR_IID}/notes"
```

With:
```groovy
"${env.GITLAB_URL}/api/v4/projects/${env.GITLAB_GROUP ?: 'p2c'}%2Fk8s-deployments/merge_requests/${params.MR_IID}/notes"
```

**Step 4: Update helper functions**

In `createPromotionMR` function, the `GITLAB_URL` reference is already using env var, but verify it uses the correct one.

**Step 5: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "fix(k8s-deployments): update root Jenkinsfile

- Remove fallback default for JENKINS_AGENT_IMAGE
- Standardize GITLAB_INTERNAL_URL → GITLAB_URL_INTERNAL
- Replace hardcoded project ID with path-based API calls

Part of k8s-deployments cleanup initiative."
```

---

### Task 13: Archive Jenkinsfile.k8s-manifest-generator

**Files:**
- Move: `k8s-deployments/jenkins/pipelines/Jenkinsfile.k8s-manifest-generator` → `k8s-deployments/docs/archives/`

**Step 1: Create archives directory**

```bash
mkdir -p k8s-deployments/docs/archives
```

**Step 2: Move file with explanation**

```bash
mv k8s-deployments/jenkins/pipelines/Jenkinsfile.k8s-manifest-generator k8s-deployments/docs/archives/
```

**Step 3: Add README to archives**

Create file `k8s-deployments/docs/archives/README.md`:

```markdown
# Archived Files

This directory contains files that have been archived but preserved for reference.

## Jenkinsfile.k8s-manifest-generator

**Archived**: 2026-01-16
**Reason**: Redundant with current event-driven MR workflow

This Jenkinsfile used SCM polling to detect changes and generate manifests automatically.
The current architecture uses event-driven webhooks and MR-based workflows instead.

If you need to reference the SCM polling approach, this file shows how it was implemented.
```

**Step 4: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/ k8s-deployments/docs/archives/
git commit -m "chore(k8s-deployments): archive Jenkinsfile.k8s-manifest-generator

Moved to docs/archives/ - redundant with event-driven MR workflow.
Uses SCM polling which conflicts with current webhook-based architecture.

Part of k8s-deployments cleanup initiative."
```

---

## Phase 4: example-app Updates

### Task 14: Create example-app config directory structure

**Files:**
- Create: `example-app/config/configmap.schema.yaml`
- Create: `example-app/config/local.env.example`
- Create: `example-app/config/README.md`

**Step 1: Create config directory**

```bash
mkdir -p example-app/config
```

**Step 2: Create configmap.schema.yaml**

Create file `example-app/config/configmap.schema.yaml`:

```yaml
# example-app Configuration Contract
# ==================================
#
# Jenkins pipelines require these variables in pipeline-config ConfigMap.
# Local scripts require these as environment variables or in config/local.env.

required:
  GITLAB_URL_INTERNAL:
    description: "GitLab API URL (cluster-internal)"
    example: "http://gitlab.gitlab.svc.cluster.local"

  GITLAB_GROUP:
    description: "GitLab group/namespace for repositories"
    example: "p2c"

  DEPLOYMENTS_REPO_URL:
    description: "Full Git URL for k8s-deployments repo"
    example: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"

  DOCKER_REGISTRY_EXTERNAL:
    description: "External Docker registry URL (what kubelet pulls from)"
    example: "docker.jmann.local"

  JENKINS_AGENT_IMAGE:
    description: "Custom Jenkins agent image with Maven, Docker, etc."
    example: "localhost:30500/jenkins-agent-custom:latest"

credentials:
  nexus-credentials:
    type: "usernamePassword"
    description: "Nexus username/password for Maven artifacts"

  docker-registry-credentials:
    type: "usernamePassword"
    description: "Docker registry credentials for image push"

  gitlab-credentials:
    type: "usernamePassword"
    description: "GitLab username/password for git operations"

  gitlab-api-token-secret:
    type: "secretText"
    description: "GitLab API token for MR creation"
```

**Step 3: Create local.env.example**

Create file `example-app/config/local.env.example`:

```bash
# example-app Local Development Configuration
# ============================================
# Copy this file to local.env and edit for your environment.
# Run: cp config/local.env.example config/local.env
#
# Note: These variables are primarily for CI/CD pipeline reference.
# Local Maven builds typically don't need these.

# GitLab Configuration
export GITLAB_URL_INTERNAL="http://gitlab.gitlab.svc.cluster.local"
export GITLAB_GROUP="p2c"
export DEPLOYMENTS_REPO_URL="http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"

# Docker Registry (external URL that kubelet uses to pull images)
export DOCKER_REGISTRY_EXTERNAL="docker.jmann.local"
```

**Step 4: Create README**

Create file `example-app/config/README.md`:

```markdown
# Configuration

This directory contains configuration contracts for example-app CI/CD pipeline.

## Files

- `configmap.schema.yaml` - Configuration contract defining required variables
- `local.env.example` - Template for local reference

## Usage

### For Jenkins Pipelines

Configure the `pipeline-config` ConfigMap with variables from `configmap.schema.yaml`.

### For Local Development

Local Maven builds typically don't need these environment variables.
They're primarily used by the Jenkins pipeline for deployment operations.

## Documentation

See [docs/CONFIGURATION.md](../docs/CONFIGURATION.md) for full documentation.
```

**Step 5: Commit**

```bash
git add example-app/config/
git commit -m "feat(example-app): add configuration contract

- Add configmap.schema.yaml defining required variables
- Add local.env.example template
- Add README pointing to documentation

Part of k8s-deployments cleanup initiative."
```

---

### Task 15: Update example-app Jenkinsfile

**Files:**
- Modify: `example-app/Jenkinsfile`

**Step 1: Update environment variable names**

In the environment block, change:
- `GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')` → `GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')`
- `DEPLOY_REGISTRY = System.getenv('DOCKER_REGISTRY')` → `DEPLOY_REGISTRY = System.getenv('DOCKER_REGISTRY_EXTERNAL')`

In the 'Checkout & Setup' stage validation, update:
- `"GITLAB_INTERNAL_URL not set"` → `"GITLAB_URL_INTERNAL not set"`
- `"DOCKER_REGISTRY not set"` → `"DOCKER_REGISTRY_EXTERNAL not set"`

**Step 2: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "fix(example-app): standardize variable names in Jenkinsfile

- GITLAB_INTERNAL_URL → GITLAB_URL_INTERNAL
- DOCKER_REGISTRY → DOCKER_REGISTRY_EXTERNAL

Part of k8s-deployments cleanup initiative."
```

---

### Task 16: Create example-app CONFIGURATION.md

**Files:**
- Create: `example-app/docs/CONFIGURATION.md`

**Step 1: Create docs directory and file**

```bash
mkdir -p example-app/docs
```

Create file `example-app/docs/CONFIGURATION.md`:

```markdown
# example-app Configuration Guide

This document describes the configuration requirements for the example-app CI/CD pipeline.

## Overview

The example-app Jenkins pipeline requires specific environment variables to be configured in the `pipeline-config` ConfigMap.

**Design Principle**: No fallback defaults. Missing configuration causes immediate failure with actionable error messages.

## Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GITLAB_URL_INTERNAL` | GitLab API URL (cluster-internal) | `http://gitlab.gitlab.svc.cluster.local` |
| `GITLAB_GROUP` | GitLab group/namespace for repositories | `p2c` |
| `DEPLOYMENTS_REPO_URL` | Full Git URL for k8s-deployments repo | `http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git` |
| `DOCKER_REGISTRY_EXTERNAL` | External Docker registry URL | `docker.jmann.local` |
| `JENKINS_AGENT_IMAGE` | Custom Jenkins agent image | `localhost:30500/jenkins-agent-custom:latest` |

## Required Credentials (Jenkins)

| Credential ID | Type | Description |
|---------------|------|-------------|
| `nexus-credentials` | Username/Password | Nexus credentials for Maven artifacts |
| `docker-registry-credentials` | Username/Password | Docker registry credentials |
| `gitlab-credentials` | Username/Password | GitLab credentials for git operations |
| `gitlab-api-token-secret` | Secret Text | GitLab API token for MR creation |

## Pipeline Behavior

The example-app pipeline:
1. Builds the Quarkus application with Maven
2. Runs unit and integration tests
3. Publishes Docker image to Nexus registry
4. Publishes Maven artifact to Nexus
5. Creates MR to k8s-deployments dev branch

## Troubleshooting

### "GITLAB_URL_INTERNAL not set" Error

Ensure the `pipeline-config` ConfigMap contains `GITLAB_URL_INTERNAL`.

### Variable Name Mapping

If migrating from older variable names:

| Old Name (deprecated) | New Name (use this) |
|-----------------------|---------------------|
| `GITLAB_INTERNAL_URL` | `GITLAB_URL_INTERNAL` |
| `DOCKER_REGISTRY` | `DOCKER_REGISTRY_EXTERNAL` |

## Related Documentation

- [k8s-deployments CONFIGURATION.md](../../k8s-deployments/docs/CONFIGURATION.md)
- [Root CLAUDE.md](../../CLAUDE.md)
```

**Step 2: Commit**

```bash
git add example-app/docs/
git commit -m "docs(example-app): add CONFIGURATION.md

Documents required environment variables, credentials,
and pipeline behavior for example-app CI/CD.

Part of k8s-deployments cleanup initiative."
```

---

## Phase 5: Root Cleanup

### Task 17: Remove duplicate create-gitlab-mr.sh from root

**Files:**
- Delete: `scripts/04-operations/create-gitlab-mr.sh`

**Step 1: Verify duplicate exists**

```bash
ls -la scripts/04-operations/create-gitlab-mr.sh
```

**Step 2: Remove the file**

```bash
rm scripts/04-operations/create-gitlab-mr.sh
```

**Step 3: Commit**

```bash
git add scripts/04-operations/create-gitlab-mr.sh
git commit -m "chore: remove duplicate create-gitlab-mr.sh from root

The authoritative version is in k8s-deployments/scripts/create-gitlab-mr.sh.
Root should not duplicate subproject scripts.

Part of k8s-deployments cleanup initiative."
```

---

### Task 18: Remove empty test-results directory

**Files:**
- Delete: `k8s-deployments/test-results/`

**Step 1: Verify directory is empty**

```bash
ls -la k8s-deployments/test-results/ 2>/dev/null || echo "Directory doesn't exist or is empty"
```

**Step 2: Remove directory if it exists**

```bash
rmdir k8s-deployments/test-results/ 2>/dev/null || echo "Already removed or not empty"
```

**Step 3: Commit (if there was a .gitkeep or similar)**

```bash
git add k8s-deployments/test-results/ 2>/dev/null || echo "No tracked files to remove"
git commit -m "chore(k8s-deployments): remove empty test-results directory

Directory had no defined purpose and was empty.

Part of k8s-deployments cleanup initiative." 2>/dev/null || echo "Nothing to commit"
```

---

## Phase 6: Documentation Updates

### Task 19: Update JENKINS_SETUP.md

**Files:**
- Modify: `k8s-deployments/docs/JENKINS_SETUP.md`

**Step 1: Fix path references**

Replace all occurrences of:
- `example/k8s-deployments` → `p2c/k8s-deployments` (or `${GITLAB_GROUP}/k8s-deployments`)
- Hardcoded `projects/2` → path-based API using `GITLAB_GROUP`

**Step 2: Add reference to CONFIGURATION.md**

Add near the top, after Prerequisites:

```markdown
## Configuration

Before proceeding, ensure you understand the configuration requirements.
See [CONFIGURATION.md](CONFIGURATION.md) for required environment variables and credentials.
```

**Step 3: Commit**

```bash
git add k8s-deployments/docs/JENKINS_SETUP.md
git commit -m "docs(k8s-deployments): fix paths in JENKINS_SETUP.md

- Replace example/k8s-deployments with p2c/k8s-deployments
- Add reference to CONFIGURATION.md
- Update API calls to use path-based project identification

Part of k8s-deployments cleanup initiative."
```

---

### Task 20: Update k8s-deployments README.md

**Files:**
- Modify: `k8s-deployments/README.md`

**Step 1: Add configuration section**

Add after the "Status" section:

```markdown
## Configuration

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for:
- Required environment variables
- Jenkins ConfigMap setup
- Local development configuration
- Branch naming conventions
```

**Step 2: Commit**

```bash
git add k8s-deployments/README.md
git commit -m "docs(k8s-deployments): add configuration reference to README

Points to docs/CONFIGURATION.md for configuration details.

Part of k8s-deployments cleanup initiative."
```

---

## Phase 7: Validation

### Task 21: Run validate-pipeline.sh

**Files:**
- None (validation only)

**Step 1: Ensure all changes are committed**

```bash
git status
```

Expected: Clean working directory

**Step 2: Push changes to origin**

```bash
git push origin main
```

**Step 3: Sync to GitLab**

```bash
./scripts/04-operations/sync-to-gitlab.sh
```

**Step 4: Run validation**

```bash
./scripts/test/validate-pipeline.sh
```

Expected: All tests pass

**Step 5: If validation fails, debug and fix**

Review the error output and fix any issues. Common problems:
- ConfigMap not updated with new variable names
- GitLab branches not synced
- Typos in variable names

---

## Summary

This implementation plan covers:

1. **Phase 1**: Configuration foundation (config directory, preflight library, docs)
2. **Phase 2**: Script updates (preflight checks, branch-per-env support)
3. **Phase 3**: Jenkinsfile updates (variable standardization, preflight stages)
4. **Phase 4**: example-app updates (config, Jenkinsfile, docs)
5. **Phase 5**: Root cleanup (remove duplicates)
6. **Phase 6**: Documentation updates (fix paths, add references)
7. **Phase 7**: Validation (run validate-pipeline.sh)

Total: 21 tasks with frequent commits for easy rollback if needed.
