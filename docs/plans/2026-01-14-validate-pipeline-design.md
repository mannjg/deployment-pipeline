# Pipeline Validation Script Design

**Date:** 2026-01-14
**Status:** Approved
**Scope:** Iteration 1 - Commit to Dev Deployment

## Purpose

A single focused script that proves the core CI/CD pipeline works by exercising the full automation loop: code commit → Jenkins build → ArgoCD deploy → running in dev.

### What This Validates

1. **The demo works** - Someone can push code and see it deployed automatically
2. **Components integrate** - GitLab webhooks trigger Jenkins, Jenkins updates k8s-deployments, ArgoCD syncs
3. **The pattern is sound** - GitOps promotion via git commits functions correctly

## Script Overview

**Name:** `validate-pipeline.sh`
**Location:** Repository root
**Runtime:** ~5-10 minutes
**Exit codes:** 0 on success, non-zero on failure

### Characteristics

- Self-contained (no external library dependencies)
- Single file (~200-300 lines)
- Uses standard `kubectl` (not MicroK8s-specific)
- Prints diagnostics on failure
- Portable to any Kubernetes cluster with proper kubeconfig

## Script Flow

### Step 1: Pre-flight Checks (~5 seconds)

- Verify `kubectl` works and can reach cluster
- Verify GitLab API responds
- Verify Jenkins API responds
- Check ArgoCD application `example-app-dev` exists
- Fail immediately with clear message if any check fails

### Step 2: Bump Version (~2 seconds)

- Read current version from `example-app/pom.xml`
- Increment patch version (e.g., `1.0.5` → `1.0.6`)
- Commit with message: `chore: bump version to X.Y.Z [pipeline-validation]`
- Push to GitLab

### Step 3: Wait for Jenkins Build (~3-5 minutes)

- Poll Jenkins API for new build triggered after commit
- Wait for build to complete (poll every 10 seconds)
- Timeout: 10 minutes (configurable)
- On failure: print last 50 lines of build console, exit non-zero

### Step 4: Wait for ArgoCD Sync (~1-2 minutes)

- Poll ArgoCD application status for `example-app-dev`
- Wait for sync status = "Synced" and health = "Healthy"
- Timeout: 5 minutes (configurable)
- On failure: print application status and recent events, exit non-zero

### Step 5: Verify Deployment (~10 seconds)

- Check pod is running with expected image tag
- Print success summary with version deployed and total time

## Configuration

Via environment variables or config file:

```bash
# Required
export GITLAB_URL="http://gitlab.jmann.local"
export GITLAB_TOKEN="glpat-xxx"
export JENKINS_URL="http://jenkins.local"
export JENKINS_USER="admin"
export JENKINS_TOKEN="xxx"

# Optional (with defaults)
export JENKINS_JOB_NAME="example-app-ci"
export JENKINS_BUILD_TIMEOUT=600      # 10 minutes
export ARGOCD_SYNC_TIMEOUT=300        # 5 minutes
export ARGOCD_APP_NAME="example-app-dev"
export DEV_NAMESPACE="dev"
```

Or source from file:
```bash
source ./config/validate-pipeline.env
```

## Output Format

### Success

```
=== Pipeline Validation ===

[✓] Pre-flight checks passed
    - kubectl: connected to cluster
    - GitLab: http://gitlab.jmann.local (reachable)
    - Jenkins: http://jenkins.local (reachable)
    - ArgoCD: example-app-dev application exists

[→] Bumping version: 1.0.5 → 1.0.6
[✓] Committed and pushed to GitLab

[→] Waiting for Jenkins build...
    Build #47 started
[✓] Build #47 completed successfully (3m 22s)

[→] Waiting for ArgoCD sync...
[✓] example-app-dev synced and healthy (1m 15s)

[→] Verifying deployment...
[✓] Pod running with image: nexus.local:5000/example-app:1.0.6

=== VALIDATION PASSED ===
Version 1.0.6 deployed to dev in 4m 47s
```

### Failure (Jenkins build failed)

```
=== Pipeline Validation ===

[✓] Pre-flight checks passed
[✓] Committed and pushed to GitLab
[→] Waiting for Jenkins build...
    Build #47 started
[✗] Build #47 FAILED

--- Build Console (last 50 lines) ---
[ERROR] Failed to execute goal org.apache.maven.plugins:maven-compiler-plugin...
...
--- End Console ---

=== VALIDATION FAILED ===
Jenkins build failed. See console output above.
```

## Implementation Details

- **Polling intervals:** 10 seconds for Jenkins, 15 seconds for ArgoCD
- **Version bump:** Uses `sed` to increment patch version in pom.xml
- **Git push:** Direct push to GitLab remote for example-app
- **kubectl:** Plain kubectl - assumes kubeconfig configured for target cluster

### Diagnostic Output on Failure

| Failure Point | Diagnostics Shown |
|---------------|-------------------|
| Jenkins build | Build console tail (50 lines) |
| ArgoCD sync | `kubectl describe application`, sync errors |
| Pod health | `kubectl describe pod`, `kubectl logs` |

## Future Iterations

### Iteration 2: Stage Promotion
- After dev passes, create MR dev→stage
- Merge MR, wait for ArgoCD sync
- Verify stage deployment

### Iteration 3: Prod Promotion
- MR stage→prod, verify
- Optional `--include-prod` flag for safety

### Iteration 4: Component Health Checks
- Separate quick script for "is infrastructure ready?"
- No pipeline exercise, just service health

### Iteration 5: Pattern Validation
- CUE schema compilation
- GitOps repo structure validation
- Webhook configuration checks

## Prerequisites

- `kubectl` configured for target cluster
- `curl` and `jq` installed
- Git configured with GitLab credentials
- Jenkins API token with build permissions
- GitLab API token with repo write permissions
