# Multi-Cluster Bootstrap Design

**Date:** 2026-02-02
**Status:** Approved
**Branch:** TBD (long-running feature branch)

## Overview

Transform the deployment-pipeline reference project from a single hardcoded cluster setup into a fully parameterized, repeatable bootstrap system that can stand up isolated "virtual clusters" within a single Kubernetes cluster.

### Goals

1. **Parameterize everything** - No hardcoded namespaces, hostnames, or assumptions
2. **Repeatable bootstrap** - Same scripts, different config, identical results
3. **Complete isolation** - Multiple clusters can coexist without interference
4. **Validated by demos** - Success = full demo suite passes on freshly bootstrapped cluster
5. **Clean teardown** - Return to pre-bootstrap state with no leftovers

### Success Criteria

Starting from nothing:
1. Bootstrap a new cluster using a config file
2. Run the full demo suite (all use cases)
3. Capture objective evidence (timestamped logs)
4. Teardown the cluster completely
5. No regression to existing reference cluster

## Configuration Structure

### Cluster Configuration File

Each cluster is fully defined by a single env file: `config/clusters/<name>.env`

All values are explicit - no derived values, no naming conventions assumed:

```bash
# config/clusters/alpha.env

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

# Internal service URLs
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
DEPLOYMENTS_REPO_NAME="k8s-deployments"

# Storage
STORAGE_CLASS="microk8s-hostpath"
```

### Reference Cluster

The current working cluster gets its own config file with protection enabled:

```bash
# config/clusters/reference.env
CLUSTER_NAME="reference"
PROTECTED="true"

GITLAB_NAMESPACE="gitlab"
JENKINS_NAMESPACE="jenkins"
# ... matches current hardcoded values
```

## Command Interface

All scripts require a config file as the first argument. No defaults, no fallbacks.

### Core Scripts

```bash
# Bootstrap a new cluster from nothing
./scripts/bootstrap.sh config/clusters/alpha.env

# Verify cluster health (pods running, endpoints responding)
./scripts/verify-cluster.sh config/clusters/alpha.env

# Run demo suite
./scripts/demo/run-all-demos.sh config/clusters/alpha.env

# Pause a cluster (scale all deployments to 0)
./scripts/cluster-ctl.sh pause config/clusters/alpha.env

# Resume a paused cluster
./scripts/cluster-ctl.sh resume config/clusters/alpha.env

# Teardown (with confirmation + protected check)
./scripts/teardown.sh config/clusters/alpha.env
```

### Typical Workflow

```bash
# 1. Pause reference cluster (defense against hardcoded values)
./scripts/cluster-ctl.sh pause config/clusters/reference.env

# 2. Bootstrap test cluster
./scripts/bootstrap.sh config/clusters/alpha.env

# 3. Add hosts entries (manual step - script outputs what to add)
# Example: 192.168.1.100 gitlab-alpha.jmann.local jenkins-alpha.jmann.local ...

# 4. Run demos, capture evidence
./scripts/demo/run-all-demos.sh config/clusters/alpha.env 2>&1 \
    | tee results/alpha-$(date +%Y%m%d-%H%M%S).log

# 5. Teardown test cluster
./scripts/teardown.sh config/clusters/alpha.env

# 6. Resume reference cluster
./scripts/cluster-ctl.sh resume config/clusters/reference.env
```

## Manifest Parameterization

### Current State

Manifests have hardcoded namespaces:

```yaml
# Current
metadata:
  name: jenkins
  namespace: jenkins  # hardcoded
```

### Target State

All configurable values use envsubst variables:

```yaml
# Target
metadata:
  name: jenkins
  namespace: ${JENKINS_NAMESPACE}
```

### Variables to Parameterize

| Category | Variables |
|----------|-----------|
| Infrastructure NS | `${GITLAB_NAMESPACE}`, `${JENKINS_NAMESPACE}`, `${NEXUS_NAMESPACE}`, `${ARGOCD_NAMESPACE}` |
| Environment NS | `${DEV_NAMESPACE}`, `${STAGE_NAMESPACE}`, `${PROD_NAMESPACE}` |
| Hostnames | `${GITLAB_HOST}`, `${JENKINS_HOST}`, `${NEXUS_HOST}`, `${ARGOCD_HOST}`, `${DOCKER_REGISTRY_HOST}` |
| Internal URLs | `${GITLAB_URL_INTERNAL}`, `${JENKINS_URL_INTERNAL}`, etc. |
| Storage | `${STORAGE_CLASS}` |

### Apply Pattern

```bash
source config/clusters/alpha.env
envsubst < k8s/jenkins/jenkins-lightweight.yaml | kubectl apply -f -
```

## Bootstrap Process

`bootstrap.sh` performs these steps in order:

1. **Validate** - Config file exists, required variables set
2. **Check collisions** - Target namespaces don't already exist
3. **Create namespaces** - Infrastructure + environment namespaces
4. **Apply cert-manager** - If not already cluster-wide
5. **Apply manifests** - envsubst + kubectl apply for GitLab, Jenkins, Nexus, ArgoCD
6. **Wait for ready** - Pods running in all namespaces
7. **Generate credentials** - Random passwords, stored in K8s secrets
8. **Configure services** - GitLab repos, Jenkins jobs, webhooks, ArgoCD apps
9. **Output summary** - Hosts entries, credentials, next steps

### Idempotency

Running bootstrap twice is safe (kubectl apply is idempotent). Credentials are not regenerated if secrets exist.

### Failure Handling

If bootstrap fails partway:
- Fix issue and re-run (idempotent), OR
- Teardown and start fresh

## Teardown Process

`teardown.sh` performs these steps:

1. **Load config** - Source the config file
2. **Check PROTECTED** - If `true`, exit immediately with error
3. **Display plan** - Show all namespaces/resources to be deleted
4. **Confirm** - Prompt user to type 'yes'
5. **Delete** - In reverse order:
   - ArgoCD applications (prevent sync conflicts)
   - Environment namespaces
   - Infrastructure namespaces
   - Cluster-scoped resources (certificates)
6. **Confirm cleanup** - Output success message

## Cluster Control

### Pause (Scale to Zero)

Scales all deployments to 0 replicas. Stores original replica counts for resume.

```bash
./scripts/cluster-ctl.sh pause config/clusters/reference.env
```

Purpose: Defense in depth against missed hardcoded values. If a script accidentally references the paused cluster, it fails fast (no pods to respond).

### Resume

Restores deployments to original replica counts.

```bash
./scripts/cluster-ctl.sh resume config/clusters/reference.env
```

## Demo Script Integration

Demo scripts accept config file as argument or inherit from parent process:

```bash
# Direct invocation
./scripts/demo/demo-uc-e1-app-deployment.sh config/clusters/alpha.env

# Via run-all-demos.sh (inherits environment)
./scripts/demo/run-all-demos.sh config/clusters/alpha.env
```

### Implementation Pattern

```bash
CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    # Check if already sourced by parent
    if [[ -z "${GITLAB_NAMESPACE:-}" ]]; then
        echo "Usage: $0 <config-file>"
        exit 1
    fi
else
    source "$CONFIG_FILE"
fi
```

## Hostname Resolution

Bootstrap outputs required `/etc/hosts` entries:

```
# Add to /etc/hosts:
192.168.1.100 gitlab-alpha.jmann.local jenkins-alpha.jmann.local nexus-alpha.jmann.local argocd-alpha.jmann.local docker-alpha.jmann.local
```

User adds entries manually before testing. Production clusters use proper DNS.

## Credentials Management

Credentials are auto-generated during bootstrap:
- Random passwords generated
- Stored in K8s secrets within cluster namespaces
- Output to console for operator reference

Config files contain no secrets (can be committed to git).

## Verification and Evidence

### Verification

Success is proven by running actual demos:
- Start with smoke test (UC-E1) until bootstrap is proven
- Graduate to full demo suite

### Evidence Capture

Timestamped log files:

```bash
./scripts/demo/run-all-demos.sh config/clusters/alpha.env 2>&1 \
    | tee results/alpha-$(date +%Y%m%d-%H%M%S).log
```

Log contains:
- Pass/fail per test
- Duration per test
- Final summary
- Any error output

## Implementation Phases

### Phase 1: Foundation
- Create `config/clusters/` directory structure
- Create `config/clusters/reference.env` (PROTECTED=true)
- Create `config/clusters/alpha.env` template
- Implement `cluster-ctl.sh` (pause/resume)

### Phase 2: Manifest Parameterization
- Audit all manifests for hardcoded values
- Replace with `${VARIABLE}` placeholders
- Update apply scripts to require config file

### Phase 3: Script Updates
- Update `scripts/01-infrastructure/*`
- Update `scripts/02-configure/*`
- Update `scripts/03-pipelines/*`
- Update `scripts/04-operations/*`
- Update `scripts/demo/*`

### Phase 4: New Scripts
- Create `bootstrap.sh`
- Create `teardown.sh`
- Create `verify-cluster.sh`

### Phase 5: Validation
- Pause reference cluster
- Bootstrap alpha cluster
- Run smoke test (UC-E1)
- Expand to full suite
- Capture evidence
- Teardown

## Development Approach

All work done on a long-running feature branch until validated. Main branch remains stable as reference.

## Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Config structure | Single env file per cluster | Simple, self-contained, no merge logic |
| Naming conventions | Fully parameterized | No assumptions; works with any naming scheme |
| Templating | envsubst | Already in use, no new dependencies |
| Command interface | Config file as argument | Explicit, no magic lookups |
| Cluster isolation | Scale to zero | Defense against hardcoded values |
| Teardown safety | Confirmation + PROTECTED flag | Prevents accidental deletion |
| Verification | Run actual demos | Only true end-to-end validation |
| Evidence | Timestamped logs | Simple, sufficient for proof |
