# GitLab Group Migration & URL Parameterization Design

**Date:** 2026-01-13
**Status:** Draft
**Scope:** Migrate GitLab projects from mixed `/example/` and `/root/` paths to `/p2c/` group, and centralize GitLab URL configuration.

## Overview

This design addresses two related issues:

1. **Group Migration:** Move `example-app` and `k8s-deployments` repositories to a new `p2c` group in GitLab
2. **URL Parameterization:** Centralize hardcoded GitLab URLs scattered across ~15 files into a single configuration source

## Current State

### Problem 1: Mixed GitLab Paths
Projects are referenced inconsistently:
- Some files use `/example/` (e.g., `gitlab.../example/k8s-deployments.git`)
- Some files use `/root/` (e.g., `gitlab.../root/example-app.git`)

### Problem 2: Hardcoded URLs
`GITLAB_URL` is defined independently in ~15 locations with inconsistent values:
- `http://gitlab.local` (some scripts)
- `http://gitlab.gitlab.svc.cluster.local` (Jenkinsfiles, other scripts)

No single source of truth exists.

## Solution Architecture

### Centralized Configuration

Two sources of truth that stay in sync:

#### 1. Repo Config File: `config/gitlab.env`

```bash
# GitLab Configuration - Single Source of Truth
# Used by: local scripts, CI/CD pipelines

# Host URLs
GITLAB_HOST_INTERNAL="gitlab.gitlab.svc.cluster.local"
GITLAB_HOST_EXTERNAL="gitlab.jmann.local"

# Group/namespace for projects
GITLAB_GROUP="p2c"

# Repository names
APP_REPO_NAME="example-app"
DEPLOYMENTS_REPO_NAME="k8s-deployments"

# Full URLs (internal - for pods/cluster)
GITLAB_URL="http://${GITLAB_HOST_INTERNAL}"
APP_REPO_URL="${GITLAB_URL}/${GITLAB_GROUP}/${APP_REPO_NAME}.git"
DEPLOYMENTS_REPO_URL="${GITLAB_URL}/${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}.git"

# Full URLs (external - for local access)
GITLAB_URL_EXTERNAL="http://${GITLAB_HOST_EXTERNAL}"
APP_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${GITLAB_GROUP}/${APP_REPO_NAME}.git"
DEPLOYMENTS_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}.git"
```

#### 2. Kubernetes ConfigMap: `k8s/configmaps/gitlab-config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-config
  namespace: jenkins
  labels:
    app: jenkins
    purpose: gitlab-configuration
data:
  GITLAB_HOST_INTERNAL: "gitlab.gitlab.svc.cluster.local"
  GITLAB_HOST_EXTERNAL: "gitlab.jmann.local"
  GITLAB_GROUP: "p2c"
  APP_REPO_NAME: "example-app"
  DEPLOYMENTS_REPO_NAME: "k8s-deployments"
  GITLAB_URL: "http://gitlab.gitlab.svc.cluster.local"
  APP_REPO_URL: "http://gitlab.gitlab.svc.cluster.local/p2c/example-app.git"
  DEPLOYMENTS_REPO_URL: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"
```

### How Components Use Configuration

| Component | Source | Method |
|-----------|--------|--------|
| Jenkinsfiles | ConfigMap | `envFrom` in pod spec + `System.getenv()` |
| Local scripts | `config/gitlab.env` | `source config/gitlab.env` |
| ArgoCD | Direct in Application manifests | Static YAML values |
| E2E tests | `config/gitlab.env` | Source with external URLs |

## Files to Modify

### Jenkinsfiles (3 files)

**Pattern:** Remove hardcoded values, read from ConfigMap, fail if not set.

#### example-app/Jenkinsfile

Lines 346-348:
```groovy
// BEFORE:
environment {
    GITLAB_URL = 'http://gitlab.gitlab.svc.cluster.local'
    DEPLOYMENT_REPO = "${GITLAB_URL}/example/k8s-deployments.git"
}

// AFTER:
environment {
    GITLAB_URL = System.getenv('GITLAB_URL')
    DEPLOYMENT_REPO = System.getenv('DEPLOYMENTS_REPO_URL')
}
```

Add validation in 'Checkout & Setup' stage:
```groovy
script {
    if (!env.GITLAB_URL) {
        error "GITLAB_URL environment variable is required but not set. Configure it in the gitlab-config ConfigMap."
    }
    if (!env.DEPLOYMENT_REPO) {
        error "DEPLOYMENTS_REPO_URL environment variable is required but not set. Configure it in the gitlab-config ConfigMap."
    }
}
```

Add `envFrom` to pod spec:
```yaml
spec:
  containers:
  - name: maven
    image: ${agentImage}
    envFrom:
    - configMapRef:
        name: gitlab-config
```

#### k8s-deployments/Jenkinsfile

Lines 264-266 - same pattern as above.

#### jenkins/pipelines/Jenkinsfile.k8s-manifest-generator

Line 61 - same pattern as above.

### ArgoCD Applications (6 files)

**Pattern:** Update hardcoded `repoURL` from `/example/` to `/p2c/`.

Files:
- `argocd/applications/example-app-dev.yaml`
- `argocd/applications/example-app-stage.yaml`
- `argocd/applications/example-app-prod.yaml`
- `argocd/applications/postgres-dev.yaml`
- `argocd/applications/postgres-stage.yaml`
- `argocd/applications/postgres-prod.yaml`

Change (line 14 in each):
```yaml
# BEFORE:
repoURL: http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git

# AFTER:
repoURL: http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git
```

### Scripts (11 files)

**Pattern:** Source central config instead of defining own variables.

```bash
# Add at top of each script:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/gitlab.env"

# Validate required vars
: "${GITLAB_URL:?GITLAB_URL is required}"
: "${GITLAB_GROUP:?GITLAB_GROUP is required}"
```

Files to update:
- `scripts/setup-gitlab-repos.sh`
- `scripts/setup-manifest-generator-job.sh`
- `scripts/configure-jenkins.sh`
- `scripts/setup-gitlab-webhook.sh`
- `scripts/setup-k8s-deployments-webhook.sh`
- `scripts/setup-k8s-deployments-validation-job.sh`
- `scripts/configure-gitlab.sh`
- `scripts/create-gitlab-projects.sh`
- `scripts/configure-gitlab-connection.sh`
- `scripts/configure-merge-requirements.sh`
- `scripts/create-gitlab-mr.sh`

### Test Configuration (2 files)

#### tests/e2e/config/e2e-config.sh
```bash
# AFTER:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../config/gitlab.env"

# Use external URL for e2e tests (run from outside cluster)
export GITLAB_URL="${GITLAB_URL_EXTERNAL}"
export GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-9m86y9YHyGf77Kr8bRjX}"
```

#### tests/e2e/config/e2e-config.template.sh
```bash
# AFTER:
export GITLAB_URL="${GITLAB_URL:-http://gitlab.jmann.local}"
```

## New Files to Create

| File | Purpose |
|------|---------|
| `config/gitlab.env` | Central configuration for scripts |
| `k8s/configmaps/gitlab-config.yaml` | ConfigMap for Jenkins pods |

## Deployment Order

### Pre-requisites (Manual GitLab Steps)

1. Create `p2c` group in GitLab
2. Transfer `example-app` project to `p2c` group
3. Transfer `k8s-deployments` project to `p2c` group

### Code Deployment Steps

| Step | Action | Reason |
|------|--------|--------|
| 1 | Apply `gitlab-config` ConfigMap | Jenkins needs config before pipelines run |
| 2 | Update ArgoCD repo credentials | ArgoCD needs access to new path |
| 3 | Deploy updated ArgoCD Application manifests | Point to new repo URLs |
| 4 | Deploy updated Jenkinsfiles | Pipelines use new ConfigMap values |
| 5 | Update scripts in repo | Local tooling uses new config |

### ArgoCD Credential Update

```bash
argocd repo rm http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git
argocd repo add http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git \
  --username <user> --password <token>
```

## Validation: E2E Test

After deployment, validate the full pipeline flow:

```
1. Push commit to example-app (p2c/example-app)
       │
       ▼
2. Jenkins CI triggers build
       │
       ▼
3. Build succeeds, creates MR to k8s-deployments (p2c) dev branch
       │
       ▼
4. Merge MR → ArgoCD syncs dev environment
       │
       ▼
5. Stage promotion MR created automatically
       │
       ▼
6. Merge stage MR → ArgoCD syncs stage environment
       │
       ▼
7. Prod promotion MR created automatically
       │
       ▼
8. Merge prod MR → ArgoCD syncs prod environment
       │
       ▼
✓ Full pipeline validated with new p2c group paths
```

### Validation Checkpoints

| Step | Verify |
|------|--------|
| 1 | Git push to `http://gitlab.jmann.local/p2c/example-app.git` succeeds |
| 2 | Jenkins reads ConfigMap, logs show correct `GITLAB_URL` and `DEPLOYMENTS_REPO_URL` |
| 3 | MR created in `p2c/k8s-deployments` (not `example/k8s-deployments`) |
| 4-8 | ArgoCD apps sync from `p2c/k8s-deployments` repo |
| Final | App running in prod namespace with new image |

## Rollback Plan

- Keep old ArgoCD repo credentials until verified
- ConfigMap can be updated back to `/example/` if needed
- GitLab project transfer is reversible

## Summary

| Category | Files Changed | New Files |
|----------|---------------|-----------|
| Jenkinsfiles | 3 | 0 |
| ArgoCD manifests | 6 | 0 |
| Scripts | 11 | 0 |
| Test config | 2 | 0 |
| Configuration | 0 | 2 |
| **Total** | **22** | **2** |
