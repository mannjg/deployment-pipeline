# CLAUDE.md - Agent Entry Point

This is the primary reference for AI coding agents working with this repository.

## Project Overview

Local GitOps CI/CD pipeline demonstration using Jenkins, GitLab, ArgoCD, and Nexus on MicroK8s. This is a reference implementation for airgapped environments, showing how to build, test, and deploy containerized applications using GitOps principles.

**Components:**
- **GitLab** - Source control and webhooks (airgap-compatible)
- **Jenkins** - CI/CD builds and artifact publishing
- **Nexus** - Maven artifacts and Docker registry
- **ArgoCD** - GitOps deployment to Kubernetes
- **MicroK8s** - Local Kubernetes cluster

## Git Remote Strategy (Critical)

This repo uses **monorepo-with-subtree-publishing**:

- **GitHub (`origin`)**: Always receives the COMPLETE repo - every file, every commit
- **GitLab**: Receives only `example-app/` and `k8s-deployments/` as separate repos for CI/CD

**Workflow (always in this order):**
1. `git push origin main` - full repo to GitHub
2. `./scripts/sync-to-gitlab.sh` - subtrees to GitLab (only if those folders changed)

**Why:** GitLab triggers Jenkins webhooks and ArgoCD watches. GitHub is the source of truth.

See `docs/GIT_REMOTE_STRATEGY.md` for subtree commands, troubleshooting, and full rationale.

## Repository Layout

```
deployment-pipeline/
├── example-app/           # Sample Quarkus app (synced to GitLab p2c/example-app)
├── k8s-deployments/       # CUE-based K8s configs (synced to GitLab p2c/k8s-deployments)
├── scripts/               # Helper scripts (NOT synced to GitLab)
├── argocd/                # ArgoCD application definitions
├── k8s/                   # Infrastructure K8s manifests (GitLab, Jenkins, Nexus, ArgoCD)
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

**Infrastructure:** MicroK8s cluster with GitLab, Jenkins, Nexus, ArgoCD deployed.

**GitLab Configuration:**
- External URL: `http://gitlab.jmann.local`
- Internal URL: `http://gitlab.gitlab.svc.cluster.local`
- Group: `p2c`
- Repositories: `p2c/example-app`, `p2c/k8s-deployments`

**Known Limitations:**
- Single cluster (all environments in one MicroK8s instance)
- No HA (single replicas of infrastructure components)
- Local storage only

**Last verified:** 2026-01-14

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
sg microk8s -c "microk8s kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd'"
```

## Common Operations

### Trigger a Build
```bash
curl -X POST http://jenkins.local/job/example-app-ci/build
```

### Check Build Status
```bash
curl -s "http://jenkins.local/job/example-app-ci/lastBuild/api/json" | \
  python3 -c "import sys, json; d=json.load(sys.stdin); print(f\"Build #{d['number']}: {d['result'] or 'BUILDING'}\")"
```

### Check Deployment Status
```bash
sg microk8s -c "microk8s kubectl get applications -n argocd"
sg microk8s -c "microk8s kubectl get pods -n dev"
```

### Sync to GitLab (after pushing to GitHub)
```bash
./scripts/sync-to-gitlab.sh
```

### Environment Promotion
Promotion is manual via GitLab merge requests:
1. Jenkins creates draft MR: dev → stage after successful dev deployment
2. Review and merge MR to promote to stage
3. Jenkins creates draft MR: stage → prod after successful stage deployment
4. Review and merge MR to promote to prod

### Access Application
```bash
sg microk8s -c "microk8s kubectl port-forward -n dev svc/example-app 8080:8080" &
curl http://localhost:8080/api/greetings
pkill -f "port-forward.*example-app"
```

## Infrastructure Notes

**MicroK8s Cluster:**
- Runs locally via snap
- Uses `sg microk8s -c "microk8s kubectl ..."` for kubectl commands
- Addons: dns, storage, ingress

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
sg microk8s -c "microk8s kubectl describe pod -n <namespace> <pod-name>"
sg microk8s -c "microk8s kubectl logs -n <namespace> <pod-name>"
```

**ArgoCD not syncing:**
```bash
sg microk8s -c "microk8s kubectl describe application -n argocd <app-name>"
```

**CUE validation:**
```bash
cd k8s-deployments
cue vet ./...
```
