# Workflows

## Design Philosophy

### Multi-Application Architecture

This pipeline is designed for **multiple independent applications**, each in its own repository:

- **App repositories** (e.g., `example-app`, `user-service`, `order-api`) contain:
  - Application source code
  - Tests (unit and integration)
  - `deployment/app.cue` — application-specific deployment configuration

- **k8s-deployments repository** contains:
  - Environment state for all applications (branches: dev, stage, prod)
  - CUE schemas and templates
  - Generated Kubernetes manifests

This separation means:
- Developers work in their app repo without touching deployment infrastructure
- Platform team owns k8s-deployments and promotion logic
- Adding a new app doesn't require changes to the CI/CD infrastructure

### Separation of Concerns

| Responsibility | Owner | Trigger |
|----------------|-------|---------|
| Build, test, publish artifacts | App CI (Jenkins) | Push to app repo |
| Create initial deployment MR | App CI (Jenkins) | Merge to app main branch |
| Validate manifests | k8s-deployments CI | MR created |
| **Promotion MRs (dev→stage→prod)** | **k8s-deployments CI** | **Merge to environment branch** |
| Deploy to cluster | ArgoCD | Change detected in branch |
| Health checking | ArgoCD | After sync |

**Key insight**: App CI pipelines do NOT know about promotion. They create the initial MR to dev, then they're done. The k8s-deployments repository owns all promotion logic, triggered by merge events.

### Why MR-Gated Promotion?

Each promotion (dev→stage, stage→prod) requires a merge request because:

1. **Visibility**: Reviewers see both CUE config changes AND generated manifest diffs
2. **Auditability**: Every promotion is a merge commit with full history
3. **Control**: Human approval required before deployment
4. **Rollback**: Easy to revert via Git

The MR shows exactly what Kubernetes resources will change before they change.

### Event-Driven Promotion

Promotion MRs are created automatically via webhook:

```
MR merged to dev branch
         │
         │ GitLab webhook (push event)
         ▼
Jenkins auto-promote job
         │
         │ Detects which apps changed
         ▼
Creates MR: dev → stage
         │
         │ (Human reviews and merges)
         ▼
MR merged to stage branch
         │
         │ GitLab webhook (push event)
         ▼
Jenkins auto-promote job
         │
Creates MR: stage → prod
```

This pattern:
- Requires no manual job triggering
- Creates MRs immediately after merge
- Works for any number of applications
- Keeps promotion logic in the deployment repo

---

## CI/CD Pipeline Workflows

### 1. Unit Test Workflow (Every Commit)

```
Developer commits to feature branch
         │
         ▼
┌─────────────────────────────────────┐
│  GitLab Push Event                  │
│  - Branch: feature/*                │
│  - Trigger: commit                  │
└─────────────────────────────────────┘
         │
         ▼ (webhook)
┌─────────────────────────────────────┐
│  Jenkins: example-app-ci            │
│  Stage: Unit Tests                  │
└─────────────────────────────────────┘
         │
         ├─> Checkout code
         ├─> mvn test
         │   └─> Run JUnit tests
         │
         ▼
┌─────────────────────────────────────┐
│  Result: SUCCESS / FAILURE          │
│  - Notification to GitLab           │
│  - Build status visible on commit   │
└─────────────────────────────────────┘
```

**Duration**: ~30 seconds
**Purpose**: Fast feedback on code changes
**Failure Action**: Fix tests and push again

---

### 2. Integration Test Workflow (Merge Request)

```
Developer creates MR
         │
         ▼
┌─────────────────────────────────────┐
│  GitLab MR Created Event            │
│  - Source: feature/*                │
│  - Target: main                     │
└─────────────────────────────────────┘
         │
         ▼ (webhook)
┌─────────────────────────────────────┐
│  Jenkins: example-app-ci            │
│  Stage: Integration Tests           │
└─────────────────────────────────────┘
         │
         ├─> Checkout MR branch
         ├─> mvn verify
         │   ├─> Unit tests
         │   └─> Integration tests
         │       └─> @QuarkusTest
         │           └─> TestContainers
         │               ├─> Start PostgreSQL container
         │               ├─> Start Redis container
         │               └─> Run tests
         │
         ▼
┌─────────────────────────────────────┐
│  Result posted to MR                │
│  - SUCCESS: Can merge               │
│  - FAILURE: Fix required            │
└─────────────────────────────────────┘
```

**Duration**: ~2 minutes
**Purpose**: Validate integration points and database interactions
**Failure Action**: Review test failures, fix code, push updates

---

### 3. Build and Publish Workflow (Merge to Main)

```
MR approved and merged
         │
         ▼
┌──────────────────────────────────────────┐
│  GitLab Merge Event                      │
│  - Branch: main                          │
│  - Trigger: merge_request_merged         │
└──────────────────────────────────────────┘
         │
         ▼ (webhook)
┌──────────────────────────────────────────┐
│  Jenkins: example-app-ci                 │
│  Stage: Build & Publish                  │
└──────────────────────────────────────────┘
         │
         ├─> Checkout main
         ├─> Determine version (from pom.xml or git tag)
         │
         ├─> mvn verify
         │   └─> All tests (unit + integration)
         │
         ├─> mvn deploy
         │   └─> Publish JAR to Nexus
         │       └─> nexus.local/maven-releases
         │
         ├─> mvn jib:build
         │   └─> Build Docker image
         │       └─> nexus.local/docker/example-app:1.2.3
         │
         ▼
┌──────────────────────────────────────────┐
│  Trigger: update-deployment job          │
│  Parameters:                             │
│  - APP_NAME=example-app                  │
│  - VERSION=1.2.3                         │
│  - COMMIT_SHA=abc123                     │
└──────────────────────────────────────────┘
```

**Duration**: ~3-4 minutes
**Purpose**: Create versioned, tested artifacts
**Failure Action**: Review build logs, fix issues

---

### 4. Deployment Update Workflow

```
Jenkins: update-deployment job triggered
         │
         ▼
┌──────────────────────────────────────────┐
│  Clone k8s-deployments repo              │
│  - Branch: dev                           │
└──────────────────────────────────────────┘
         │
         ├─> Extract deployment/app.cue from example-app
         │   └─> Copy to services/apps/example-app.cue
         │
         ├─> Update envs/dev.cue
         │   └─> Set image tag to 1.2.3
         │
         ├─> Run CUE validation
         │   └─> cue vet ./...
         │
         ├─> Generate manifests
         │   └─> ./scripts/generate-manifests.sh dev
         │       └─> Creates manifests/dev/example-app.yaml
         │
         ├─> Git commit
         │   └─> "Update example-app to v1.2.3
         │        - Merged CUE from commit abc123
         │        - Updated image tag"
         │
         └─> Git push origin dev
         │
         ▼
┌──────────────────────────────────────────┐
│  k8s-deployments dev branch updated      │
└──────────────────────────────────────────┘
         │
         ▼ (ArgoCD polling or webhook)
┌──────────────────────────────────────────┐
│  ArgoCD detects change                   │
│  Application: example-app-dev            │
└──────────────────────────────────────────┘
         │
         ├─> Sync manifests/dev/example-app.yaml
         │   └─> Apply to namespace: dev
         │
         ▼
┌──────────────────────────────────────────┐
│  Kubernetes Deployment rollout           │
│  - Namespace: dev                        │
│  - Image: nexus.local/example-app:1.2.3  │
└──────────────────────────────────────────┘
         │
         ▼
Application running in dev environment
         │
         ▼ (post-sync hook)
┌──────────────────────────────────────────┐
│  Jenkins: create-promotion-mr job        │
│  - Triggered after successful sync       │
└──────────────────────────────────────────┘
```

**Duration**: ~2-3 minutes
**Purpose**: Deploy to dev environment automatically
**Failure Action**: Check Jenkins logs, CUE validation errors, ArgoCD sync status

Validation gates in k8s-deployments CI:
- `Validate CUE` runs `cue vet ./...` and `./scripts/pipeline validate-cue`.
- `Validate Manifests` runs `./scripts/pipeline validate-manifests-static <env>` and `./scripts/pipeline validate-manifests-dry-run`.

---

### 5. Environment Promotion Workflow (Dev → Stage)

**Trigger**: GitLab webhook fires when MR is merged to dev branch (push event).

```
MR merged to dev branch
         │
         ▼ (GitLab webhook: push event to dev)
┌──────────────────────────────────────────┐
│  Jenkins: k8s-deployments-auto-promote   │
│  - Triggered by webhook                  │
│  - Detects: dev branch updated           │
└──────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────┐
│  Checkout k8s-deployments repo           │
│  - Fetch branches: dev, stage            │
└──────────────────────────────────────────┘
         │
         ├─> Generate manifests for dev
         │   └─> cue export --out yaml ./envs:dev
         │
         ├─> Generate manifests for stage
         │   └─> cue export --out yaml ./envs:stage
         │
         ├─> Create diff
         │   └─> diff -u manifests/stage/ manifests/dev/
         │       (simulated, stage will have dev's changes)
         │
         ├─> Create GitLab MR via API
         │   ├─> Source: dev
         │   ├─> Target: stage
         │   ├─> Title: "Promote example-app v1.2.3 to stage"
         │   ├─> Description: Full manifest diff
         │   ├─> Draft: true
         │   └─> Label: auto-promotion
         │
         ▼
┌──────────────────────────────────────────┐
│  GitLab MR Created (DRAFT)               │
│  - Review required                       │
│  - Shows complete K8s manifest diff      │
└──────────────────────────────────────────┘
         │
         ▼ (manual review)
Developer reviews diff
  - Check version changes
  - Verify configuration changes
  - Validate resource requirements
         │
         ▼
Developer marks MR as "Ready" (undraft)
         │
         ▼
Developer approves and merges MR
         │
         ▼
┌──────────────────────────────────────────┐
│  k8s-deployments stage branch updated    │
└──────────────────────────────────────────┘
         │
         ▼
ArgoCD syncs example-app-stage
         │
         ▼
Application deployed to stage
         │
         ▼ (GitLab webhook: push event to stage)
Jenkins auto-promote creates MR: stage → prod
```

**Duration**: ~5 seconds (MR creation), manual review time varies
**Purpose**: Controlled promotion with visibility
**Human verification**: Before merging stage→prod MR, reviewer checks:
- Dev deployment is healthy (ArgoCD status)
- Stage deployment is healthy (ArgoCD status)
- Manifest diff is correct
**Failure Action**: Close MR, fix issues in dev, re-promote

---

### 6. Complete Feature Delivery Flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Day 1: Development                                             │
└─────────────────────────────────────────────────────────────────┘

09:00 - Developer creates feature branch
        └─> git checkout -b feature/add-user-api

09:15 - Developer implements REST endpoint
        └─> Commits trigger unit tests (SUCCESS)

11:00 - Developer adds integration test
        └─> Commits trigger unit tests (SUCCESS)

14:00 - Developer creates MR
        └─> Integration tests run (SUCCESS)

14:05 - Peer review

15:00 - MR approved and merged to main
        ├─> Unit + Integration tests (SUCCESS)
        ├─> Build artifacts (SUCCESS)
        ├─> Publish to Nexus (SUCCESS)
        │   ├─> example-app-1.2.3.jar
        │   └─> example-app:1.2.3
        └─> Update deployment repo (SUCCESS)

15:05 - ArgoCD syncs dev environment
        └─> example-app v1.2.3 running in dev

15:06 - Draft MR created: dev → stage
        └─> Ready for QA review

┌─────────────────────────────────────────────────────────────────┐
│  Day 2: QA in Stage                                             │
└─────────────────────────────────────────────────────────────────┘

09:00 - QA reviews dev environment
        └─> Smoke tests pass

09:30 - QA reviews stage MR diff
        └─> Approves changes

09:35 - Tech lead unDrafts and merges MR
        └─> Stage deployment triggered

09:37 - ArgoCD syncs stage environment
        └─> example-app v1.2.3 running in stage

09:38 - Draft MR created: stage → prod

10:00 - QA performs full regression in stage
        └─> All tests pass

┌─────────────────────────────────────────────────────────────────┐
│  Day 3: Production Release                                      │
└─────────────────────────────────────────────────────────────────┘

09:00 - Release manager reviews stage performance
        └─> No issues found

09:30 - Release manager reviews prod MR diff
        └─> Verifies version, configuration

09:35 - Release manager unDrafts and merges MR
        └─> Production deployment triggered

09:37 - ArgoCD syncs prod environment
        └─> example-app v1.2.3 running in prod

09:40 - Monitoring confirms healthy rollout
        └─> Feature delivered to production
```

---

### 7. Configuration Change Workflow

When a feature requires infrastructure changes:

```
Developer creates feature branch
         │
         ├─> Modifies application code
         │   └─> src/main/java/com/example/UserService.java
         │
         └─> Modifies deployment configuration
             └─> deployment/app.cue
                 ├─> Add new environment variable
                 ├─> Increase memory limit
                 └─> Add new ConfigMap entry
         │
         ▼
Developer commits and creates MR
         │
         ├─> Integration tests run
         │   └─> Tests use new configuration
         │
         ▼
MR approved and merged
         │
         ▼
Jenkins: Build & Publish
         │
         ├─> Publishes artifacts
         │
         ▼
Jenkins: update-deployment
         │
         ├─> Extracts deployment/app.cue
         │   └─> Detects changes (git diff)
         │
         ├─> Merges into k8s-deployments
         │   └─> services/apps/example-app.cue updated
         │
         ├─> Generates manifests
         │   └─> New ConfigMap rendered
         │   └─> Deployment has new env vars
         │   └─> Resource limits updated
         │
         └─> Commits to dev branch
         │
         ▼
ArgoCD syncs dev
         │
         └─> Applies ALL changes:
             ├─> New container image
             ├─> New ConfigMap
             ├─> Updated Deployment spec
             │
         ▼
Promotion MRs show BOTH:
         ├─> Version change (v1.2.3 → v1.2.4)
         └─> Configuration changes
             ├─> + env: DATABASE_POOL_SIZE=20
             └─> + memory: 512Mi → 1Gi
```

**Key Point**: CUE file changes are tracked in Git history and visible in promotion MRs, providing full auditability.

---

### 8. Rollback Workflow

```
Issue detected in production
         │
         ▼
┌─────────────────────────────────────────┐
│  Option 1: ArgoCD Rollback              │
└─────────────────────────────────────────┘
         │
         ├─> ArgoCD UI → History → Select previous revision
         └─> Sync to previous version
             └─> Immediate rollback

┌─────────────────────────────────────────┐
│  Option 2: Git Revert                   │
└─────────────────────────────────────────┘
         │
         ├─> git revert <commit> on prod branch
         ├─> Push to prod branch
         └─> ArgoCD auto-syncs
             └─> Rolls back to previous version

┌─────────────────────────────────────────┐
│  Option 3: Manual MR (Preferred)        │
└─────────────────────────────────────────┘
         │
         ├─> Create MR to change image tag back
         ├─> Review and approve
         └─> Merge → ArgoCD syncs
             └─> Controlled rollback with audit trail
```

---

## Trigger Matrix

### Application Repository Events (example-app, etc.)

| Event | Branch | Jenkins Job | Actions | Duration |
|-------|--------|-------------|---------|----------|
| Push | feature/* | example-app-ci | Unit tests only | ~30s |
| Push | main | - | None (wait for MR) | - |
| MR Created | any → main | example-app-ci | Unit + Integration tests | ~2m |
| MR Updated | any → main | example-app-ci | Unit + Integration tests | ~2m |
| MR Merged | any → main | example-app-ci | Build + Publish + Create k8s-deployments MR | ~5m |

### k8s-deployments Repository Events

| Event | Branch | Triggered By | Actions | Duration |
|-------|--------|--------------|---------|----------|
| MR Created | any → dev/stage/prod | App CI or auto-promote | Validation pipeline runs | ~30s |
| MR Merged | any → dev | Human approval | ArgoCD syncs dev | ~1m |
| Push (post-merge) | dev | GitLab webhook | **auto-promote job → creates stage MR** | ~10s |
| MR Merged | any → stage | Human approval | ArgoCD syncs stage | ~1m |
| Push (post-merge) | stage | GitLab webhook | **auto-promote job → creates prod MR** | ~10s |
| MR Merged | any → prod | Human approval | ArgoCD syncs prod | ~1m |
| Push (post-merge) | prod | GitLab webhook | No further promotion | - |

**Note**: The auto-promote job is triggered by GitLab webhook on push to dev/stage branches (which occurs after MR merge). It is NOT triggered by ArgoCD sync status — MR creation happens immediately, and humans verify deployment health before merging the next promotion MR.

---

## Approval Gates

| Environment | Automated | Manual Approval Required | Approvers |
|-------------|-----------|--------------------------|-----------|
| Dev | ✓ Auto-deploy on merge | ✗ | None |
| Stage | ✗ | ✓ MR approval required | QA team, Tech leads |
| Prod | ✗ | ✓ MR approval required | Release managers, Senior engineers |

---

## Notification Points

1. **Unit test failure**: GitLab commit status, Slack (optional)
2. **Integration test failure**: MR comment, Slack (optional)
3. **Build failure**: Jenkins console, Slack (optional)
4. **Dev deployment**: ArgoCD notification, Slack (optional)
5. **Promotion MR created**: GitLab notification, Email
6. **Stage/Prod deployment**: ArgoCD notification, Slack, Email

---

## Metrics and KPIs

- **Cycle Time**: Commit to production (target: <2 days)
- **Build Success Rate**: Target >95%
- **Deployment Frequency**: Track deployments per day/week
- **Mean Time to Recovery**: Track rollback time
- **Lead Time for Changes**: Commit to dev deployment (target: <10 minutes)
