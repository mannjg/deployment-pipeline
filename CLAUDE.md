# CLAUDE.md - Agent Entry Point

This is the primary reference for AI coding agents working with this repository.

## Project Overview

Local GitOps CI/CD pipeline demonstration using Jenkins, GitLab, ArgoCD, and Nexus on Kubernetes. This is a reference implementation for airgapped environments, showing how to build, test, and deploy containerized applications using GitOps principles.

**Components:**
- **GitLab** - Source control and webhooks (airgap-compatible)
- **Jenkins** - CI/CD builds and artifact publishing
- **Nexus** - Maven artifacts and Docker registry
- **ArgoCD** - GitOps deployment to Kubernetes
- **Kubernetes** - Local cluster

## Git Remote Strategy (Critical)

This repo uses **monorepo-with-subtree-publishing**:

- **GitHub (`origin`)**: Always receives the COMPLETE repo - every file, every commit
- **GitLab**: Receives only `example-app/` and `k8s-deployments/` as separate repos for CI/CD

**Workflow (always in this order):**
1. `git push origin main` - full repo to GitHub
2. `./scripts/04-operations/sync-to-gitlab.sh` - subtrees to GitLab (only if those folders changed)

**Why:** GitLab triggers Jenkins webhooks and ArgoCD watches. GitHub is the source of truth.

See `docs/GIT_REMOTE_STRATEGY.md` for subtree commands, troubleshooting, and full rationale.

## Demo Setup: Environment Branches

The k8s-deployments repo uses **branch-per-environment** (dev/stage/prod branches in GitLab).
These branches are NOT managed by subtree sync - they're created directly in GitLab.

**Initial Setup (run once after syncing subtrees):**
```bash
export GITLAB_USER="root"  # or your GitLab username
export GITLAB_TOKEN="your-gitlab-token"  # or let script get from K8s secret
./scripts/03-pipelines/setup-gitlab-env-branches.sh
```

This script:
1. Clones k8s-deployments from GitLab
2. Creates dev/stage/prod branches from main
3. Transforms `example-env.cue` into `env.cue` with environment-specific values
4. Pushes all branches to GitLab

**Reset Demo State (preserves valid images):**
```bash
./scripts/03-pipelines/reset-demo-state.sh
```

This script cleans up MRs and resets app version WITHOUT destroying environment branches.
The branches retain their valid CI/CD-managed images from previous builds.

**Seed Template Maintenance:**
- `k8s-deployments/example-env.cue` is the seed template (persisted to GitHub)
- Only used during INITIAL bootstrap (when branches don't exist)
- Once branches have valid CI/CD images, they are managed by the pipeline

**Workflow Order (Critical):**

| Scenario | Commands |
|----------|----------|
| Initial bootstrap (first time) | `git push origin main` → `./scripts/04-operations/sync-to-gitlab.sh` → `./scripts/03-pipelines/setup-gitlab-env-branches.sh` |
| Demo reset (preserves images) | `./scripts/03-pipelines/reset-demo-state.sh` → `./scripts/test/validate-pipeline.sh` |
| Validation only | `./scripts/test/validate-pipeline.sh` |
| After example-app changes only | `git push origin main` → `./scripts/test/validate-pipeline.sh` (script syncs example-app internally) |

## Repository Layout

```
deployment-pipeline/
├── example-app/           # Sample Quarkus app (synced to GitLab p2c/example-app)
├── k8s-deployments/       # CUE-based K8s configs (synced to GitLab p2c/k8s-deployments)
├── scripts/               # Helper scripts (NOT synced to GitLab)
├── k8s/                   # Infrastructure manifests
│   ├── argocd/            # ArgoCD install and ingress
│   ├── cert-manager/      # TLS certificate management
│   ├── gitlab/            # GitLab deployment
│   ├── jenkins/           # Jenkins Helm values and manifests
│   │   └── agent/         # Custom Jenkins agent (Dockerfile, build script, CA cert)
│   ├── cluster-config/    # Optional cluster-specific configs (e.g., kubeconfig)
│   └── nexus/             # Nexus deployment
├── config/                # Centralized configuration
│   └── infra.env          # Infrastructure URLs (GitLab, Jenkins, ArgoCD, Nexus)
├── docs/                  # Documentation
│   ├── ARCHITECTURE.md    # System design details
│   ├── GIT_REMOTE_STRATEGY.md  # Full git workflow details
│   ├── WORKFLOWS.md       # CI/CD workflow details
│   └── archives/          # Historical docs (may be stale)
└── CLAUDE.md              # This file
```

## Current State

**Infrastructure:** Kubernetes cluster with GitLab, Jenkins, Nexus, ArgoCD deployed.

**GitLab Configuration:**
- External URL: `http://gitlab.jmann.local`
- Internal URL: `http://gitlab.gitlab.svc.cluster.local`
- Group: `p2c`
- Repositories: `p2c/example-app`, `p2c/k8s-deployments`

**Known Limitations:**
- Single cluster (all environments in one cluster)
- No HA (single replicas of infrastructure components)
- Local storage only

**Last verified:** 2026-01-16

## Service Access

**URLs (add to /etc/hosts pointing to 127.0.0.1):**
| Service | URL | Purpose |
|---------|-----|---------|
| GitLab | http://gitlab.jmann.local | Source control, webhooks |
| Jenkins | http://jenkins.local | CI/CD builds |
| Nexus | http://nexus.local | Maven artifacts, Docker registry |
| ArgoCD | http://argocd.local | GitOps deployment |
| Docker Registry | https://docker.local:5000 | Container images (via Nexus) |

**Credentials:** Stored in Jenkins credentials store and Kubernetes secrets. Do not hardcode.

**Check service health:**
```bash
kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd'
```

## Common Operations

### Jenkins Operations (ALWAYS use jenkins-cli.sh)

**IMPORTANT:** Always use `scripts/04-operations/jenkins-cli.sh` for Jenkins operations. Do not write ad-hoc curl commands - extend the CLI if needed.

```bash
# Get build status (JSON output)
./scripts/04-operations/jenkins-cli.sh status example-app/main
./scripts/04-operations/jenkins-cli.sh status k8s-deployments/dev

# Get console output
./scripts/04-operations/jenkins-cli.sh console example-app/main
./scripts/04-operations/jenkins-cli.sh console example-app/main 138  # specific build

# Wait for build to complete
./scripts/04-operations/jenkins-cli.sh wait example-app/main --timeout 600
```

Job notation uses slash format: `example-app/main` → `example-app/job/main`

### Trigger a Build
```bash
./scripts/04-operations/trigger-build.sh example-app
```

### Check Deployment Status
```bash
kubectl get applications -n argocd
kubectl get pods -n dev
```

### Sync to GitLab (after pushing to GitHub)
```bash
./scripts/04-operations/sync-to-gitlab.sh
```

### Environment Promotion
Promotion is **event-driven** via GitLab merge requests:
1. App CI creates MR to k8s-deployments dev branch
2. Human reviews and merges → ArgoCD deploys to dev
3. **Auto-promote job** (webhook-triggered) creates MR: dev → stage
4. Human reviews stage deployment health, merges → ArgoCD deploys to stage
5. **Auto-promote job** creates MR: stage → prod
6. Human reviews prod MR carefully, merges → ArgoCD deploys to prod

**Key**: Promotion MRs are created automatically on merge. Humans verify deployment health before accepting the next promotion MR. See `docs/WORKFLOWS.md` for details.

### Access Application
```bash
kubectl port-forward -n dev svc/example-app 8080:8080 &
curl http://localhost:8080/api/greetings
pkill -f "port-forward.*example-app"
```

## Infrastructure Notes

**Kubernetes Cluster:**
- **Distribution-agnostic**: Works with any K8s cluster (microk8s, kind, k3s, EKS, GKE, etc.)
- **Prerequisite**: User must configure `kubectl` to access their target cluster
- Scripts use standard `kubectl` commands - no distribution-specific tooling

**Namespaces:**
| Namespace | Purpose |
|-----------|---------|
| gitlab | GitLab CE |
| jenkins | Jenkins CI/CD |
| nexus | Nexus Repository |
| argocd | ArgoCD GitOps |
| dev | Development environment |
| stage | Staging environment |
| prod | Production environment |

**Centralized Config:**
Source `config/infra.env` for infrastructure URLs in scripts:
```bash
source config/infra.env
echo $GITLAB_URL_EXTERNAL   # https://gitlab.jmann.local
echo $JENKINS_URL_EXTERNAL  # https://jenkins.jmann.local
echo $APP_REPO_PATH         # p2c/example-app
```

## Documentation Index

| Document | Purpose |
|----------|---------|
| `docs/ARCHITECTURE.md` | System design, component details, data flow |
| `docs/GIT_REMOTE_STRATEGY.md` | Git subtree workflow, troubleshooting |
| `docs/WORKFLOWS.md` | CI/CD pipeline stages, trigger matrix |
| `docs/archives/` | Historical docs - may be stale, use for reference only |

## Quick Debugging

**Pod not starting:**
```bash
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name>
```

**ArgoCD not syncing:**
```bash
kubectl describe application -n argocd <app-name>
```

**CUE validation:**
```bash
cd k8s-deployments
cue vet ./...
```
