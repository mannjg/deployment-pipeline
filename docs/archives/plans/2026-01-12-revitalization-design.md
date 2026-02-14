# Deployment Pipeline Revitalization Design

**Date:** 2026-01-12
**Status:** Approved
**Target Environment:** jmann-tower (192.168.7.202)

## Overview

This document captures the design for revitalizing the deployment-pipeline project. The goal is to create a reference implementation for CUE-based GitOps deployments that can be cloned and reconstituted in airgapped clusters.

### Key Goals

1. **Reference implementation** - Clean, well-documented template for airgap deployment
2. **Remove Helm** - Use CUE to generate k8s manifests, making changes visible in MR diffs
3. **Clear ownership model** - Platform owns base CUE, app teams own app-specific CUE
4. **Reproducible** - Self-contained with all images catalogued for offline transfer

### Production Context

This project simulates a production environment where:

| This Project | Production Reality |
|--------------|-------------------|
| GitLab | GitLab-Main (source) + Cluster GitLab (k8s manifests) |
| Nexus | Artifactory (build artifacts) + Cluster Nexus (airgap delivery) |
| Jenkins | CI/CD pipeline |
| ArgoCD | Cluster deployment (same role) |

---

## Repository Structure

Three separate GitHub repos, each with distinct purpose:

### deployment-pipeline/ (Infrastructure + Docs)

```
deployment-pipeline/              → GitHub
├── k8s/
│   ├── cert-manager/
│   ├── gitlab/
│   ├── jenkins/
│   ├── nexus/
│   └── argocd/
├── scripts/
│   ├── bootstrap.sh              # Initial cluster setup
│   ├── apply-infrastructure.sh   # envsubst + kubectl apply
│   ├── export-images.sh          # Export Nexus cache for airgap
│   └── import-images.sh          # Import images to airgap Nexus
├── docs/
│   ├── README.md                 # Index
│   ├── ARCHITECTURE.md           # System overview, diagrams
│   ├── DECISIONS.md              # ADR-style decision records
│   ├── runbooks/
│   │   ├── 01-infrastructure-setup.md
│   │   ├── 02-configure-pipeline.md
│   │   ├── 03-deploy-app.md
│   │   ├── 04-environment-promotion.md
│   │   └── 05-airgap-migration.md
│   ├── reference/
│   │   ├── CUE-PATTERNS.md
│   │   ├── PARAMETERS.md
│   │   └── IMAGE-CATALOG.md
│   └── TROUBLESHOOTING.md
├── env.example                   # Template for environment variables
└── README.md
```

**Purpose:** Infrastructure setup, documentation, bootstrap scripts. This repo "evaporates" in target clusters - it's only used for setup and reference.

### example-app/ (App Template)

```
example-app/                      → GitHub
├── src/                          # Quarkus application code
├── deployment/
│   └── app.cue                   # App-specific CUE (source of truth)
├── Jenkinsfile                   # App CI/CD pipeline
└── README.md
```

**Purpose:** Template for how any application repo should be structured. Demonstrates TestContainers + DinD for integration testing.

### k8s-deployments/ (Deployment Repo)

```
k8s-deployments/                  → GitHub
├── schemas/                      # K8s primitives (platform-owned)
│   ├── deployment.cue
│   ├── service.cue
│   ├── configmap.cue
│   ├── secret.cue
│   └── pvc.cue
├── templates/
│   ├── base/                     # Base app template (platform-owned)
│   ├── core/                     # Core definitions (platform-owned)
│   ├── resources/                # Resource definitions (platform-owned)
│   └── apps/                     # App-specific (copied from app repos)
│       ├── example-app.cue       # From example-app/deployment/app.cue
│       └── postgres.cue          # 3rd party, owned here
├── env.cue                       # Environment config (branch-specific)
├── manifests/                    # Generated output (ArgoCD syncs)
├── scripts/
├── Jenkinsfile                   # Deployment CI/CD pipeline
└── README.md
```

**Purpose:** CUE libraries, environment configs, generated manifests. This is the active deployment repo in target clusters.

---

## CUE Ownership Model

| Owner | Location | Rationale |
|-------|----------|-----------|
| **Platform (k8s-deployments)** | `schemas/` | K8s resource primitives - specs are universal |
| **Platform (k8s-deployments)** | `templates/base/`, `templates/core/` | Common app patterns - shared across all apps |
| **Platform (k8s-deployments)** | `env.cue` | Environment config - shared infrastructure |
| **App repo** | `deployment/app.cue` | App-specific needs - only app devs know their requirements |

### CUE Composition Flow

```
Platform-owned (stable)          App-owned (changes with app)
─────────────────────────────    ────────────────────────────
schemas/                     \
templates/base/               }── merge ──► manifests/
templates/core/              /        ▲
env.cue                     /         │
                                      │
                          templates/apps/{app}.cue
                          (copied from app repo)
```

---

## Infrastructure Stack

### Components on jmann-tower (microk8s)

| Component | Purpose | Access Variable |
|-----------|---------|-----------------|
| GitLab | Source code + deployment repo hosting | `${GITLAB_HOST}` |
| Jenkins | CI/CD pipelines | `${JENKINS_HOST}` |
| Nexus | Docker registry + Maven + proxy cache | `${NEXUS_HOST}` |
| ArgoCD | GitOps deployment to cluster | `${ARGOCD_HOST}` |
| cert-manager | Auto-generates TLS certificates | - |
| ingress | Routes HTTPS traffic | microk8s addon |
| hostpath-storage | PVC backing | microk8s addon |

### Nexus Repository Configuration

| Repository | Type | Purpose |
|------------|------|---------|
| `docker-hosted` | hosted | Local builds (example-app images) |
| `docker-proxy-dockerhub` | proxy | Pull-through cache for Docker Hub |
| `docker-proxy-gcr` | proxy | Pull-through cache for gcr.io |
| `docker-proxy-quay` | proxy | Pull-through cache for quay.io |
| `docker-group` | group | Unified endpoint for all docker repos |
| `maven-snapshots` | hosted | App build artifacts |
| `maven-releases` | hosted | Released artifacts |
| `maven-proxy-central` | proxy | Pull-through cache for Maven Central |

### Environment Configuration

Infrastructure yamls use envsubst for parameterization:

```bash
# env.local (jmann-tower)
GITLAB_HOST=gitlab.jmann.local
JENKINS_HOST=jenkins.jmann.local
NEXUS_HOST=nexus.jmann.local
ARGOCD_HOST=argocd.jmann.local
```

Full URLs are parameterized (not just domain suffix) to support varying naming conventions across environments.

---

## CI/CD Pipelines

### Pipeline 1: App CI/CD (example-app/Jenkinsfile)

**Trigger:** Push to main branch in app repo

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Checkout                                                 │
├─────────────────────────────────────────────────────────────┤
│ 2. Unit Tests                                               │
├─────────────────────────────────────────────────────────────┤
│ 3. Integration Tests (TestContainers + DinD)                │
├─────────────────────────────────────────────────────────────┤
│ 4. Build & Publish                                          │
│    • Build JAR (Maven)                                      │
│    • Build Docker image (Jib)                               │
│    • Push to Nexus docker-hosted                            │
│    • Publish Maven artifacts to Nexus                       │
├─────────────────────────────────────────────────────────────┤
│ 5. Update Deployment Repo                                   │
│    • Clone k8s-deployments                                  │
│    • Copy app.cue → templates/apps/{app-name}.cue            │
│    • Update image tag in CUE file                           │
│    • Commit & push to k8s-deployments                       │
│    (triggers Deployment Pipeline)                           │
└─────────────────────────────────────────────────────────────┘
```

### Pipeline 2: Deployment CI/CD (k8s-deployments/Jenkinsfile)

**Trigger:** Push to k8s-deployments (from app pipeline OR direct edit)

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Checkout                                                 │
├─────────────────────────────────────────────────────────────┤
│ 2. Validate CUE                                             │
│    • Syntax validation                                      │
│    • Schema validation                                      │
├─────────────────────────────────────────────────────────────┤
│ 3. Generate Manifests                                       │
│    • Run CUE export using branch's env.cue                  │
│    • Output to manifests/                                   │
├─────────────────────────────────────────────────────────────┤
│ 4. Diff Check                                               │
│    • Show what changed in manifests                         │
├─────────────────────────────────────────────────────────────┤
│ 5. Commit Generated Manifests                               │
├─────────────────────────────────────────────────────────────┤
│ 6. Create/Update MR (for promotion)                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Environment Promotion Workflow

### Branch Strategy

```
main        → Source CUE libraries only (schemas/, templates/base/, templates/core/)
               No env.cue, no manifests

dev         → env.cue (dev values) + templates/apps/ + manifests/
stage       → env.cue (stage values) + templates/apps/ + manifests/
prod        → env.cue (prod values) + templates/apps/ + manifests/
```

### Promotion Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         dev branch                                  │
│  templates/apps/example-app.cue  (changed)                           │
│  env.cue                        (dev values - stays here)           │
│  manifests/                     (regenerated for dev)               │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                       MR created (only app CUE changes)
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        stage branch                                 │
│  templates/apps/example-app.cue  ← merged from dev                   │
│  env.cue                        (stage values - untouched)          │
│  manifests/                     ← regenerated using stage env.cue   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key mechanism:** When MR is merged, pipeline regenerates manifests using target branch's env.cue (not source branch's).

### ArgoCD Configuration

| Application | Watches | Deploys to |
|-------------|---------|------------|
| `apps-dev` | k8s-deployments branch `dev`, path `manifests/` | `dev` namespace |
| `apps-stage` | k8s-deployments branch `stage`, path `manifests/` | `stage` namespace |
| `apps-prod` | k8s-deployments branch `prod`, path `manifests/` | `prod` namespace |

---

## Airgap Migration Process

### What Gets Transferred

| Artifact | Source | Destination |
|----------|--------|-------------|
| `deployment-pipeline` repo | GitHub | Airgap GitLab (reference/docs) |
| `example-app` repo | GitHub | Airgap GitLab (template) |
| `k8s-deployments` repo | GitHub | Airgap GitLab (active use) |
| Container images | Nexus cache | Airgap Nexus |
| Maven artifacts | Nexus | Airgap Nexus |

### Transfer Process

```
jmann-tower (internet-connected)
├── Apps build, images push to Nexus docker-hosted
├── Base images pulled through Nexus proxy-cache
└── Run: scripts/export-images.sh
    ├── Queries Nexus for all cached/hosted images
    ├── Exports to tarball (skopeo)
    └── Generates IMAGE-CATALOG.md

        │ Physical transfer (USB, secure drop, etc.)
        ▼

Airgap cluster
├── Run: scripts/import-images.sh
│   ├── Loads images from tarball
│   └── Pushes to airgap Nexus
├── Clone repos from GitHub transfer
├── Push repos to airgap GitLab
├── Update env.cue with airgap-specific values
└── Configure ArgoCD to watch airgap GitLab
```

---

## Cleanup Required

### deployment-pipeline/ (Parent Repo)

| Action | Item | Reason |
|--------|------|--------|
| DELETE | `cue-templates/` | Duplicate, k8s-deployments is source |
| DELETE | `envs/` | Duplicate |
| DELETE | `manifests/` | Duplicate |
| DELETE | `cue.mod/` | Duplicate |
| DELETE | Root-level CUE files | Duplicate |
| DELETE | `jenkins/pipelines/` | Duplicate Jenkinsfiles |
| KEEP | `k8s/gitlab/`, `k8s/jenkins/`, etc. | Infrastructure yamls |
| UPDATE | Infrastructure yamls | Add envsubst parameterization |
| ADD | `k8s/cert-manager/` | New component |
| ADD | `env.example` | Template |

### k8s-deployments/

| Action | Item | Reason |
|--------|------|--------|
| RESTRUCTURE | Branch model | Create dev/stage/prod branches |
| DELETE | `envs/dev.cue`, `stage.cue`, `prod.cue` | Replace with single env.cue per branch |
| ADD | `env.cue` | Single file on each env branch |
| UPDATE | `Jenkinsfile` | Regenerate-on-merge logic |

### example-app/

| Action | Item | Reason |
|--------|------|--------|
| UPDATE | `Jenkinsfile` | Stage 5: copy app.cue logic |
| CLEAN | Git remote | Remove embedded token |

---

## Implementation Phases

### Phase 1: Foundation (jmann-tower infrastructure)

**Setup:**
1. Enable microk8s addons (hostpath-storage, verify ingress)
2. Install cert-manager
3. Create namespaces
4. Parameterize infrastructure yamls
5. Create `env.local`

**Deploy & Verify:**

| Step | Deploy | External Verify | Internal Verify |
|------|--------|-----------------|-----------------|
| 1a | cert-manager | Pods running | - |
| 1b | ClusterIssuer | Test cert issued | - |
| 1c | GitLab | UI via HTTPS | curl from test pod |
| 1d | Nexus | UI via HTTPS | curl from test pod |
| 1e | Jenkins | UI via HTTPS | curl from test pod |
| 1f | ArgoCD | UI via HTTPS | curl from test pod |

**Gate Checklist:**
- [ ] All pods healthy
- [ ] All UIs accessible via HTTPS (external)
- [ ] All services reachable from pods (internal)
- [ ] Can create GitLab project
- [ ] Can push docker image to Nexus
- [ ] Can push maven artifact to Nexus
- [ ] Nexus proxy pulls from internet

### Phase 2: Integration verification

| Step | Configure | Verify |
|------|-----------|--------|
| 2a | Jenkins GitLab credentials | Jenkins can clone |
| 2b | Jenkins Nexus credentials | Jenkins can push docker |
| 2c | Jenkins Maven settings | Jenkins can push maven |
| 2d | ArgoCD GitLab repo | ArgoCD sees repo |
| 2e | GitLab webhook | Push triggers Jenkins |

**Gate Checklist:**
- [ ] Jenkins clones private GitLab repo
- [ ] Jenkins pushes docker to Nexus
- [ ] Jenkins publishes maven to Nexus
- [ ] ArgoCD repo connected (green)
- [ ] Webhook triggers Jenkins

### Phase 3: Repository cleanup

1. Clean deployment-pipeline
2. Restructure k8s-deployments branches
3. Create env.cue per branch
4. Clean git remotes
5. Push to jmann-tower GitLab

**Gate Checklist:**
- [ ] No duplicate CUE files in parent
- [ ] dev/stage/prod branches exist
- [ ] Each branch has env.cue
- [ ] `cue eval` succeeds on each branch
- [ ] All repos in jmann-tower GitLab

### Phase 4: Pipeline implementation

| Step | Implement | Verify |
|------|-----------|--------|
| 4a | Deployment Jenkinsfile (validate) | CUE validates |
| 4b | Deployment Jenkinsfile (generate) | Manifests correct |
| 4c | Deployment Jenkinsfile (commit) | Manifests committed |
| 4d | ArgoCD dev app | Syncs to dev namespace |
| 4e | App Jenkinsfile (build/test) | DinD works |
| 4f | App Jenkinsfile (publish) | Artifacts in Nexus |
| 4g | App Jenkinsfile (update k8s-deployments) | Triggers deployment pipeline |

**Gate Checklist:**
- [ ] Push to k8s-deployments → manifests regenerated → ArgoCD syncs
- [ ] TestContainers works (DinD)
- [ ] App publishes to Nexus
- [ ] App triggers deployment pipeline
- [ ] End-to-end: code change → deployed to dev

### Phase 5: Promotion flow

| Step | Test | Verify |
|------|------|--------|
| 5a | MR: dev → stage | Shows app CUE diff |
| 5b | Merge MR | Stage pipeline regenerates |
| 5c | ArgoCD stage | Deployed to stage |
| 5d | stage → prod | Same flow works |

**Gate Checklist:**
- [ ] MR shows correct diff
- [ ] Merge triggers stage pipeline
- [ ] Stage manifests use stage env.cue values
- [ ] ArgoCD syncs to stage
- [ ] Full dev→stage→prod works

### Phase 6: Multi-app demonstration

| Step | Test | Verify |
|------|------|--------|
| 6a | Add postgres | Deployed to dev |
| 6b | Add second app | Both apps work |
| 6c | Update one app | Only that app changes |
| 6d | Update base CUE | All apps regenerate |
| 6e | Promote independently | Works |
| 6f | Promote together | Works |

**Gate Checklist:**
- [ ] 3rd party app (postgres) works
- [ ] Multiple apps coexist
- [ ] Single app change isolated
- [ ] Base CUE change affects all
- [ ] Independent and batch promotion work

### Phase 7: Documentation & Airgap prep

1. Write ARCHITECTURE.md
2. Write DECISIONS.md
3. Create runbooks
4. Create IMAGE-CATALOG.md
5. Test export/import scripts
6. Write TROUBLESHOOTING.md

**Gate Checklist:**
- [ ] Runbooks are followable
- [ ] Image catalog complete
- [ ] Export script works
- [ ] Import script works

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Repo structure | Separate repos | Mirrors production, no parent in target |
| Infrastructure deployment | Lightweight yamls + envsubst | Minimal, pragmatic for demo purposes |
| HTTPS/Certs | cert-manager + self-signed | Kubernetes-native, declarative |
| Image strategy | Nexus proxy cache | Documents images through usage |
| CUE ownership | Platform owns base, apps own specific | Clear separation of concerns |
| Environment promotion | Branch-based + regenerate on merge | Clean model, MRs show real changes |
| Persistence | PVC with hostpath StorageClass | K8s-native patterns, simple backing |
| Documentation | Modular docs + runbooks | Works for humans and AI agents |
