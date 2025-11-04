# Multi-Repository CI/CD Architecture

**Version:** 1.0
**Date:** 2025-11-04
**Status:** Implementation Plan

## Executive Summary

This document outlines the architectural design for supporting multiple application repositories in a CI/CD pipeline with centralized CUE-based Kubernetes deployment configurations. The design ensures that application teams can manage infrastructure requirements alongside their code changes within the same merge request, while maintaining separation between application-specific configs and shared infrastructure templates.

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [Architectural Principles](#architectural-principles)
3. [Repository Structure](#repository-structure)
4. [Workflow Entrypoints](#workflow-entrypoints)
5. [Feature Delivery Cycle](#feature-delivery-cycle)
6. [Implementation Plan](#implementation-plan)
7. [Acceptance Criteria](#acceptance-criteria)
8. [Future Enhancements](#future-enhancements)

---

## Current State Analysis

### Existing Workflow

The current pipeline (defined in `Jenkinsfile:1`) follows this progression:

```
Source Change → Build & Test → Publish → Deploy Dev → Promote Stage → Promote Prod
```

**Pipeline Stages:**
1. **Checkout** (`Jenkinsfile:54`) - Version extraction, image tag generation
2. **Unit Tests** (`Jenkinsfile:86`) - Fast feedback on every commit
3. **Integration Tests** (`Jenkinsfile:104`) - Currently disabled (should run on release branches)
4. **Build & Publish** (`Jenkinsfile:122`) - Docker image + Maven artifacts
5. **Update Deployment Repo** (`Jenkinsfile:171`) - Updates `k8s-deployments/dev` branch
6. **Create Stage Promotion MR** (`Jenkinsfile:291`) - Automated promotion preparation
7. **Create Prod Promotion MR** (`Jenkinsfile:405`) - Final promotion preparation

### Current Triggers

**Implemented:**
- ✅ GitLab webhook on application repo push to `main` branch
- ✅ Manual Jenkins UI trigger

**Missing:**
- ❌ Application deployment config changes (`deployment/app.cue`)
- ❌ Environment configuration changes (`envs/*.cue`)
- ❌ Base template changes (`services/base/*.cue`, `services/core/*.cue`)
- ❌ Validation pipeline for infrastructure changes

### Key Issues

1. **Deployment Config Drift**: `example-app/deployment/app.cue` and `k8s-deployments/services/apps/example-app.cue` are maintained separately
2. **Infrastructure Changes Isolated**: Adding environment variables requires separate commits in different repos
3. **No Validation Pipeline**: Changes to base templates aren't automatically validated
4. **Manual Manifest Regeneration**: Infrastructure changes require manual script execution

---

## Architectural Principles

### 1. Single Source of Truth

**Application-Specific Configuration** (`deployment/app.cue`):
- Lives in **application repository**
- Owned by **application team**
- Versioned with application code
- Synchronized to `k8s-deployments` during CI/CD

**Infrastructure Templates** (`services/base/`, `services/core/`, `services/resources/`):
- Live in **k8s-deployments repository**
- Owned by **platform team**
- Shared across all applications
- Changes trigger validation and regeneration

**Environment Configurations** (`envs/*.cue`):
- Live in **k8s-deployments repository**
- Owned by **DevOps team**
- Environment-specific overrides
- Updated by CI/CD pipelines

### 2. Build Once, Deploy Many

- Application code and its deployment config are built together
- Same artifact (Docker image) flows through all environments
- Image tag is the only thing that changes between environments

### 3. Infrastructure as Code

- All deployment configurations in version control
- Changes reviewed via merge requests
- Automated validation before merge
- Auditable change history

### 4. Feature Delivery Proximity

Application teams should be able to:
- Change application code
- Update deployment requirements (env vars, volumes, resources)
- Submit both changes in a **single merge request**

---

## Repository Structure

### Multi-Repo Layout

```
┌─────────────────────────────────────────────────────────┐
│            Application Repositories (Siloed)             │
├─────────────────────────────────────────────────────────┤
│                                                          │
│ example-app/ (individual repo)                          │
│ ├── src/                      ← Application source      │
│ ├── deployment/                                         │
│ │   └── app.cue               ← OWNED BY APP TEAM      │
│ │                                (app-specific config)  │
│ ├── Jenkinsfile               ← CI/CD pipeline         │
│ ├── pom.xml                                             │
│ └── README.md                                           │
│                                                          │
│ another-app/ (individual repo)                          │
│ ├── src/                      ← Different technology    │
│ ├── deployment/                                         │
│ │   └── app.cue               ← OWNED BY APP TEAM      │
│ └── Jenkinsfile               ← CI/CD pipeline         │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│      k8s-deployments (Shared Infrastructure)             │
│              Branches: dev, stage, prod                  │
├─────────────────────────────────────────────────────────┤
│                                                          │
│ services/                                               │
│ ├── base/                     ← OWNED BY PLATFORM TEAM │
│ │   ├── schema.cue           (#AppConfig schema)       │
│ │   └── defaults.cue         (Default values)          │
│ │                                                        │
│ ├── core/                     ← OWNED BY PLATFORM TEAM │
│ │   └── app.cue              (#App template)           │
│ │                                                        │
│ ├── resources/                ← OWNED BY PLATFORM TEAM │
│ │   ├── deployment.cue       (Deployment template)     │
│ │   ├── service.cue          (Service templates)       │
│ │   └── configmap.cue        (ConfigMap template)      │
│ │                                                        │
│ └── apps/                     ← GENERATED/SYNCED       │
│     ├── example-app.cue      ← Synced from example-app│
│     └── another-app.cue      ← Synced from another-app│
│                                                          │
│ envs/                         ← OWNED BY DEVOPS TEAM   │
│ ├── dev.cue                  (Dev environment config)  │
│ ├── stage.cue                (Stage environment config)│
│ └── prod.cue                 (Prod environment config) │
│                                                          │
│ manifests/                    ← GENERATED              │
│ ├── dev/                     (Generated YAML)          │
│ │   └── example-app.yaml                               │
│ ├── stage/                                              │
│ └── prod/                                               │
│                                                          │
│ scripts/                                                │
│ ├── generate-manifests.sh   ← Manifest generation     │
│ ├── validate-manifests.sh   ← Validation              │
│ └── add-new-app.sh          ← Bootstrap new apps      │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Critical Design Decision: `services/apps/` is SYNCHRONIZED

**Problem:** Currently, `k8s-deployments/services/apps/example-app.cue` is manually maintained and can drift from the source application repository.

**Solution:** Treat `services/apps/*.cue` as **build artifacts** that are automatically synchronized during the CI/CD pipeline.

**Rationale:**
1. Application teams own their deployment requirements
2. Infrastructure changes live alongside code changes
3. Single merge request contains both code and config
4. No drift between repositories
5. Clear ownership boundaries

---

## Workflow Entrypoints

### Complete Entrypoint Matrix

| Trigger Source | Repository | Branch | Action | Status |
|----------------|------------|--------|--------|--------|
| **App source code** | example-app | main | Full CI/CD pipeline | ✅ Implemented |
| **App deployment config** | example-app | main | Sync to k8s-deployments | ❌ Needs implementation |
| **Environment config** | k8s-deployments | dev/stage/prod | Validate + regenerate manifests | ❌ Needs implementation |
| **Base templates** | k8s-deployments | main | Validate all apps | ❌ Needs implementation |
| **Manual regeneration** | k8s-deployments | any | Jenkins job | ⚠️ Partial (script exists) |

### Entrypoint 1: Application Changes

**Trigger:** Push to `example-app` repository, `main` branch

**Webhook Configuration:** `scripts/setup-gitlab-webhook.sh:94`

**Pipeline Actions:**
1. Build and test application
2. Publish Docker image
3. **Sync `deployment/app.cue` to k8s-deployments**
4. Update `envs/dev.cue` with new image tag
5. Generate manifests
6. Create MR to k8s-deployments/dev branch
7. Create promotion MRs for stage/prod

**Modified Files:**
- `k8s-deployments/services/apps/example-app.cue` (synced)
- `k8s-deployments/envs/dev.cue` (image tag updated)
- `k8s-deployments/manifests/dev/example-app.yaml` (regenerated)

### Entrypoint 2: Infrastructure Template Changes

**Trigger:** Push to `k8s-deployments` repository, any branch

**Pipeline Actions:**
1. Validate CUE syntax across all files
2. Regenerate manifests for affected environment
3. Validate generated Kubernetes YAML
4. Run dry-run against cluster (if configured)
5. Commit regenerated manifests

**Use Cases:**
- Platform team updates base schema
- DevOps team changes environment configuration
- Infrastructure requirements change

### Entrypoint 3: Manual Operations

**Trigger:** Jenkins job or script execution

**Use Cases:**
- Emergency manifest regeneration
- Testing configuration changes
- Troubleshooting deployment issues

---

## Feature Delivery Cycle

### Example: Add Redis Caching Support

This example demonstrates the ideal workflow for a feature that requires both code and infrastructure changes.

#### Changes in Application Repository (`example-app`)

**Single Merge Request:**

```
Title: feat: Add Redis caching layer

Files Changed:
├── src/main/java/com/example/app/CacheService.java    (new file)
├── src/main/java/com/example/app/UserService.java     (modified)
├── src/test/java/com/example/app/CacheServiceTest.java (new file)
└── deployment/app.cue                                  (modified)
```

**deployment/app.cue changes:**

```cue
// Package deployment defines application-specific configuration
package deployment

exampleApp: {
    appName: "example-app"

    appEnvVars: [
        {
            name: "QUARKUS_HTTP_PORT"
            value: "8080"
        },
        {
            name: "QUARKUS_LOG_CONSOLE_ENABLE"
            value: "true"
        },
        // NEW: Redis configuration
        {
            name: "REDIS_URL"
            value: "redis://redis.cache.svc.cluster.local:6379"
        },
        {
            name: "REDIS_TIMEOUT_SECONDS"
            value: "5"
        },
    ]

    appConfig: {
        healthCheck: {
            path: "/health/ready"
            port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
        }
    }
}
```

#### Pipeline Execution Flow

```
1. Developer commits to feature branch
   └── Opens MR in example-app repository

2. CI runs on MR:
   ├── Unit tests (including new CacheServiceTest)
   ├── Integration tests (if enabled)
   └── Build succeeds (no deployment yet)

3. Developer merges to main
   └── Webhook triggers Jenkins pipeline

4. Jenkins Pipeline (Jenkinsfile:171):
   ├── Checkout and build
   ├── Run all tests
   ├── Build Docker image with new code
   ├── Publish to Nexus registry
   └── Update k8s-deployments:
       ├── Clone k8s-deployments (dev branch)
       ├── **SYNC: Copy deployment/app.cue → services/apps/example-app.cue**
       ├── Update envs/dev.cue with new image tag
       ├── Run ./scripts/generate-manifests.sh dev
       ├── Commit changes:
       │   ├── services/apps/example-app.cue (synced config)
       │   ├── envs/dev.cue (new image)
       │   └── manifests/dev/example-app.yaml (regenerated)
       └── Create MR to k8s-deployments/dev

5. k8s-deployments MR Review:
   ├── Reviewer sees:
   │   ├── New Redis environment variables
   │   ├── Updated image tag
   │   └── Regenerated manifest with REDIS_URL
   └── Merge triggers ArgoCD sync

6. ArgoCD Deployment:
   ├── Detects change in k8s-deployments/dev
   ├── Syncs to dev namespace
   └── Pods restart with:
       ├── New image (with caching code)
       └── New environment variables (Redis config)

7. Result:
   ✅ Code and config deployed together
   ✅ Single MR from developer perspective
   ✅ Infrastructure changes tracked in k8s-deployments
   ✅ Audit trail maintained
```

#### Key Benefits

1. **Single MR**: Developer submits one merge request with both code and config
2. **Atomic Deployment**: Code and infrastructure changes deploy together
3. **Proper Review**: Infrastructure team can review config changes in k8s-deployments
4. **Audit Trail**: All changes tracked with proper commit messages
5. **No Manual Steps**: Entire process is automated

---

## Implementation Plan

This section outlines the step-by-step implementation with rationale for ordering.

### Phase 1: Foundation (Validation Infrastructure)

**Rationale:** Before syncing files automatically, we need validation to prevent breaking changes.

#### Step 1.1: Enhance Manifest Validation Script

**File:** `scripts/validate-manifests.sh`

**Requirements:**
- Validate Kubernetes YAML syntax
- Check for required fields (namespace, labels, image)
- Verify resource naming conventions
- Validate resource limits are within acceptable ranges
- Check for common security issues (privileged containers, hostPath, etc.)

**Deliverable:** Production-ready validation script

**Dependencies:** None

**Estimated Effort:** 2-4 hours

#### Step 1.2: Create CUE Validation Script

**File:** `scripts/validate-cue-config.sh` (new)

**Requirements:**
- Run `cue vet ./...` across all CUE files
- Validate schema compliance
- Check for circular dependencies
- Ensure all required fields are provided
- Report clear error messages with file/line numbers

**Deliverable:** CUE validation script

**Dependencies:** None

**Estimated Effort:** 2-3 hours

#### Step 1.3: Create Integration Test Script

**File:** `scripts/test-cue-integration.sh` (new)

**Requirements:**
- Generate manifests for all environments
- Validate all generated YAML
- Run kubectl dry-run (if cluster access available)
- Compare generated manifests with expected output (regression tests)

**Deliverable:** Integration test suite

**Dependencies:** Steps 1.1, 1.2

**Estimated Effort:** 3-4 hours

### Phase 2: Application Pipeline Enhancement

**Rationale:** Implement the sync mechanism in the application pipeline.

#### Step 2.1: Add Sync Logic to Jenkinsfile

**File:** `Jenkinsfile:171` (Update Deployment Repo stage)

**Changes:**
```groovy
stage('Update Deployment Repo') {
    steps {
        container('maven') {
            script {
                withCredentials([...]) {
                    sh '''
                        cd k8s-deployments

                        # Fetch and checkout dev branch
                        git fetch origin dev
                        git checkout dev
                        git pull origin dev

                        # Create feature branch
                        FEATURE_BRANCH="update-dev-${IMAGE_TAG}"
                        git checkout -b "$FEATURE_BRANCH"
                    '''

                    // **NEW: Sync deployment config**
                    sh """
                        cd k8s-deployments

                        # Ensure target directory exists
                        mkdir -p services/apps

                        # Copy app-specific CUE config from source repo
                        echo "Syncing deployment config..."
                        cp ${WORKSPACE}/deployment/app.cue services/apps/${APP_NAME}.cue

                        # Validate the synced CUE file
                        echo "Validating synced configuration..."
                        cue vet ./services/apps/${APP_NAME}.cue
                    """

                    // Update environment-specific image tag
                    sh """
                        cd k8s-deployments

                        # Update image in dev environment
                        sed -i 's|image: ".*"|image: "${IMAGE_FOR_DEPLOY}"|' envs/dev.cue

                        echo "Updated image in envs/dev.cue:"
                        grep 'image:' envs/dev.cue
                    """

                    // Generate manifests
                    sh """
                        cd k8s-deployments

                        # Generate Kubernetes manifests from CUE
                        ./scripts/generate-manifests.sh dev

                        # Validate generated manifests
                        ./scripts/validate-manifests.sh dev
                    """

                    // Commit with detailed message
                    sh """
                        cd k8s-deployments

                        # Stage all changes
                        git add services/apps/${APP_NAME}.cue
                        git add envs/dev.cue
                        git add manifests/dev/

                        # Commit with metadata
                        git commit -m "Update ${APP_NAME} to ${IMAGE_TAG}

Automated deployment update from application CI/CD pipeline.

Changes:
- Synced services/apps/${APP_NAME}.cue from source repository
- Updated dev environment image to ${IMAGE_TAG}
- Regenerated Kubernetes manifests

Build: ${BUILD_URL}
Git commit: ${GIT_SHORT_HASH}
Image: ${FULL_IMAGE}
Deploy image: ${IMAGE_FOR_DEPLOY}

Generated manifests from CUE configuration." || echo "No changes to commit"
                    """

                    // Push and create MR
                    sh '''...existing push logic...'''
                }
            }
        }
    }
}
```

**Testing:**
- Run pipeline with unchanged `deployment/app.cue` (should be no-op)
- Run pipeline with modified `deployment/app.cue` (should sync changes)
- Verify validation failures are caught

**Dependencies:** Phase 1 (validation scripts)

**Estimated Effort:** 3-4 hours

#### Step 2.2: Update Commit Message Template

**File:** `Jenkinsfile:223` (commit message)

**Changes:**
- Add section indicating which files were synced
- Include link to source repository commit
- List changed configuration keys (if detectable)

**Dependencies:** Step 2.1

**Estimated Effort:** 1 hour

#### Step 2.3: Test Application Pipeline

**Test Cases:**
1. Add new environment variable in `deployment/app.cue`
2. Modify existing environment variable
3. Add new resource (e.g., persistent volume)
4. Change health check configuration
5. Invalid CUE syntax (should fail validation)

**Expected Results:**
- All changes sync correctly
- Manifests regenerate with changes
- Invalid configs fail with clear error messages

**Dependencies:** Steps 2.1, 2.2

**Estimated Effort:** 2-3 hours

### Phase 3: Infrastructure Validation Pipeline

**Rationale:** Enable infrastructure team to safely modify base templates.

#### Step 3.1: Create Jenkins Job for k8s-deployments Validation

**File:** `jenkins/k8s-deployments-validation.Jenkinsfile` (new)

**Purpose:** Validate changes to k8s-deployments repository

**Pipeline Stages:**
1. Checkout
2. Validate CUE syntax
3. Generate manifests for all environments
4. Validate all generated YAML
5. Run integration tests
6. Report results

**Trigger:** Webhook on k8s-deployments repository

**Dependencies:** Phase 1 (all validation scripts)

**Estimated Effort:** 4-5 hours

#### Step 3.2: Add Webhook to k8s-deployments Repository

**File:** `scripts/setup-k8s-deployments-webhook.sh` (new)

**Purpose:** Trigger validation pipeline on infrastructure changes

**Configuration:**
- Repository: k8s-deployments
- Branches: all branches
- Events: push, merge_request
- Target: Jenkins validation job

**Dependencies:** Step 3.1

**Estimated Effort:** 1-2 hours

#### Step 3.3: Add Pre-Merge Validation

**Purpose:** Prevent merging broken configurations

**Implementation:**
- Configure GitLab CI/CD (`.gitlab-ci.yml` in k8s-deployments)
- Run validation scripts
- Block merge if validation fails

**Alternative:** Use Jenkins pipeline status as merge requirement

**Dependencies:** Steps 3.1, 3.2

**Estimated Effort:** 2-3 hours

### Phase 4: Bootstrap Tooling

**Rationale:** Simplify adding new applications to the platform.

#### Step 4.1: Create App Bootstrap Script

**File:** `scripts/add-new-app.sh` (new)

**Usage:**
```bash
./scripts/add-new-app.sh my-new-app \
    --registry docker.local \
    --group my-group \
    --initial-image my-new-app:latest
```

**Actions:**
1. Create template `services/apps/my-new-app.cue` (placeholder)
2. Add entries to `envs/dev.cue`, `envs/stage.cue`, `envs/prod.cue`
3. Generate initial manifests
4. Create ArgoCD Application definitions
5. Output next steps for developer

**Dependencies:** None (can be done in parallel)

**Estimated Effort:** 3-4 hours

#### Step 4.2: Create Application Template

**File:** `templates/app-template/` (new directory)

**Contents:**
- `deployment/app.cue` - Template with common configurations
- `Jenkinsfile` - Standard pipeline (parameterized)
- `.gitlab-ci.yml` - Validation pipeline
- `README.md` - Documentation for app teams

**Dependencies:** None

**Estimated Effort:** 2-3 hours

#### Step 4.3: Document Onboarding Process

**File:** `docs/APP_ONBOARDING.md` (new)

**Contents:**
- Prerequisites for new applications
- Step-by-step onboarding guide
- Repository structure requirements
- CI/CD setup instructions
- Example deployment configurations
- Troubleshooting guide

**Dependencies:** Steps 4.1, 4.2

**Estimated Effort:** 2-3 hours

### Phase 5: Testing and Documentation

**Rationale:** Ensure everything works end-to-end and is well-documented.

#### Step 5.1: End-to-End Testing

**Test Scenarios:**

1. **New Application Onboarding:**
   - Use bootstrap script to add new app
   - Create app repository from template
   - Commit initial code and config
   - Trigger pipeline
   - Verify deployment to dev
   - Verify promotion MRs created

2. **Feature with Config Changes:**
   - Add new environment variable
   - Commit to app repository
   - Verify sync to k8s-deployments
   - Verify manifest regeneration
   - Verify deployment

3. **Infrastructure Template Update:**
   - Modify base schema
   - Commit to k8s-deployments
   - Verify validation runs
   - Verify all apps regenerate manifests
   - Verify no breaking changes

4. **Environment Configuration Change:**
   - Update dev.cue directly
   - Commit to k8s-deployments/dev
   - Verify validation and regeneration
   - Verify ArgoCD sync

5. **Failure Scenarios:**
   - Invalid CUE syntax
   - Invalid Kubernetes YAML
   - Failing validation
   - Merge conflicts
   - Missing required fields

**Dependencies:** Phases 1-4 complete

**Estimated Effort:** 4-6 hours

#### Step 5.2: Update Documentation

**Files to Update:**
- `README.md` - Reference to new architecture docs
- `k8s-deployments/README.md` - Document sync behavior
- `example-app/README.md` - Document deployment config ownership
- `docs/TROUBLESHOOTING.md` - Add new troubleshooting scenarios

**New Documentation:**
- `docs/MULTI_REPO_ARCHITECTURE.md` (this file)
- `docs/APP_ONBOARDING.md` (from Step 4.3)
- `docs/INFRASTRUCTURE_CHANGES.md` - Guide for platform team

**Dependencies:** Step 5.1 (testing complete)

**Estimated Effort:** 3-4 hours

#### Step 5.3: Create Runbook

**File:** `docs/RUNBOOK.md` (new)

**Contents:**
- Common operational procedures
- Emergency procedures (rollback, etc.)
- Debugging guides
- Manual intervention procedures
- Monitoring and alerting setup

**Dependencies:** Step 5.2

**Estimated Effort:** 2-3 hours

---

## Acceptance Criteria

### Phase 1: Validation Infrastructure

- [ ] CUE validation script validates all files successfully
- [ ] Manifest validation detects common issues
- [ ] Integration test runs successfully for all environments
- [ ] Clear error messages for all failure scenarios
- [ ] Scripts are executable and have proper error handling

### Phase 2: Application Pipeline

- [ ] `deployment/app.cue` syncs to k8s-deployments automatically
- [ ] Synced file validates successfully
- [ ] Manifests regenerate with changes
- [ ] Commit messages include sync details
- [ ] Pipeline fails on invalid CUE syntax
- [ ] Pipeline fails on validation errors
- [ ] Existing functionality (image updates) still works

### Phase 3: Infrastructure Pipeline

- [ ] Webhook triggers on k8s-deployments changes
- [ ] Validation pipeline runs for all commits
- [ ] All validation scripts execute
- [ ] Manifests regenerate for all environments
- [ ] Merge blocked if validation fails
- [ ] Success/failure status visible in GitLab

### Phase 4: Bootstrap Tooling

- [ ] Bootstrap script creates all required files
- [ ] Generated configurations are valid
- [ ] ArgoCD applications created
- [ ] Template repository structure is correct
- [ ] Documentation is clear and complete
- [ ] Onboarding can be completed by app team without help

### Phase 5: Testing and Documentation

- [ ] All test scenarios pass
- [ ] Failure scenarios fail gracefully with clear messages
- [ ] Documentation is complete and accurate
- [ ] Runbook covers common scenarios
- [ ] Team members can follow procedures successfully

---

## Implementation Order and Dependencies

### Dependency Graph

```
Phase 1: Foundation (Validation)
├── 1.1 Enhance Manifest Validation [No deps]
├── 1.2 Create CUE Validation [No deps]
└── 1.3 Create Integration Tests [Depends: 1.1, 1.2]

Phase 2: Application Pipeline
├── 2.1 Add Sync Logic [Depends: Phase 1]
├── 2.2 Update Commit Messages [Depends: 2.1]
└── 2.3 Test Application Pipeline [Depends: 2.1, 2.2]

Phase 3: Infrastructure Pipeline
├── 3.1 Create Validation Job [Depends: Phase 1]
├── 3.2 Add Webhook [Depends: 3.1]
└── 3.3 Add Pre-Merge Validation [Depends: 3.1, 3.2]

Phase 4: Bootstrap Tooling (Can run parallel to Phase 3)
├── 4.1 Create Bootstrap Script [No deps]
├── 4.2 Create Application Template [No deps]
└── 4.3 Document Onboarding [Depends: 4.1, 4.2]

Phase 5: Testing and Documentation
├── 5.1 End-to-End Testing [Depends: Phases 1-4]
├── 5.2 Update Documentation [Depends: 5.1]
└── 5.3 Create Runbook [Depends: 5.2]
```

### Recommended Implementation Order

1. **Week 1: Foundation**
   - Day 1-2: Steps 1.1, 1.2 (Validation scripts)
   - Day 3: Step 1.3 (Integration tests)
   - Day 4-5: Step 2.1 (Add sync logic to Jenkinsfile)

2. **Week 2: Pipeline Enhancement**
   - Day 1: Step 2.2 (Commit messages)
   - Day 2-3: Step 2.3 (Test application pipeline)
   - Day 4-5: Steps 3.1, 3.2 (Infrastructure validation job + webhook)

3. **Week 3: Bootstrap and Testing**
   - Day 1-2: Step 3.3 (Pre-merge validation)
   - Day 3: Steps 4.1, 4.2 (Bootstrap script + template)
   - Day 4-5: Step 5.1 (End-to-end testing)

4. **Week 4: Documentation and Launch**
   - Day 1-2: Step 4.3 (Onboarding docs)
   - Day 3-4: Step 5.2 (Update all documentation)
   - Day 5: Step 5.3 (Create runbook)

**Total Estimated Effort:** 15-20 days (3-4 weeks)

---

## Rollout Strategy

### Phase 1: Internal Testing (Week 1-2)

**Scope:** Test with `example-app` only

**Actions:**
1. Implement validation infrastructure
2. Add sync logic to `example-app` Jenkinsfile
3. Test with various configuration changes
4. Gather feedback from team

**Success Criteria:**
- Sync works correctly
- Validation catches issues
- No manual intervention required

### Phase 2: Limited Rollout (Week 3)

**Scope:** Add 1-2 additional applications

**Actions:**
1. Use bootstrap tooling to onboard new apps
2. Create app templates
3. Test with real-world scenarios
4. Refine tooling based on feedback

**Success Criteria:**
- Bootstrap process is smooth
- App teams can self-onboard with minimal help
- Infrastructure changes don't break existing apps

### Phase 3: General Availability (Week 4)

**Scope:** Open to all applications

**Actions:**
1. Complete documentation
2. Conduct training sessions
3. Announce new architecture
4. Provide support during migration

**Success Criteria:**
- Documentation is clear
- Teams successfully onboard
- Support burden is manageable
- System is stable

---

## Monitoring and Metrics

### Key Metrics to Track

1. **Pipeline Success Rate**
   - Target: > 95% success rate
   - Measure: Jenkins pipeline statistics

2. **Sync Accuracy**
   - Target: 100% of `deployment/app.cue` changes sync correctly
   - Measure: Manual audit of random samples

3. **Validation Effectiveness**
   - Target: 100% of invalid configs caught before merge
   - Measure: Track validation failures vs. deployment failures

4. **Deployment Lead Time**
   - Target: < 15 minutes from commit to dev deployment
   - Measure: Time from commit to ArgoCD sync

5. **Onboarding Time**
   - Target: < 2 hours for new app onboarding
   - Measure: Track time for new apps from start to first deployment

### Alerting

**Critical Alerts:**
- Validation pipeline failures
- Sync failures in application pipeline
- Manifest generation failures
- ArgoCD sync errors

**Warning Alerts:**
- Increasing pipeline duration
- High validation failure rate
- Frequent manual interventions

---

## Future Enhancements

### Short Term (3-6 months)

1. **Automatic Rollback**
   - Detect failed deployments
   - Automatically revert to previous version
   - Notify team of rollback

2. **Configuration Drift Detection**
   - Detect manual changes to deployed resources
   - Alert on drift from Git state
   - Provide reconciliation tools

3. **Advanced Validation**
   - Resource limit enforcement by environment
   - Security scanning of configurations
   - Cost estimation for resource requests

### Medium Term (6-12 months)

1. **Self-Service Portal**
   - Web UI for app onboarding
   - Configuration management interface
   - Deployment status dashboard

2. **Progressive Delivery**
   - Canary deployments
   - Blue-green deployments
   - Automated rollout with metrics

3. **Policy as Code**
   - OPA (Open Policy Agent) integration
   - Enforce organizational policies
   - Custom validation rules per team

### Long Term (12+ months)

1. **Multi-Cluster Support**
   - Support multiple Kubernetes clusters
   - Cross-cluster promotions
   - Disaster recovery automation

2. **Advanced Observability**
   - Integrated monitoring dashboards
   - Automated performance testing
   - Deployment impact analysis

3. **AI-Assisted Operations**
   - Anomaly detection
   - Automated issue resolution
   - Predictive scaling

---

## Risk Analysis and Mitigation

### Risk 1: Sync Failures Lead to Broken Deployments

**Probability:** Medium
**Impact:** High

**Mitigation:**
1. Comprehensive validation before sync
2. Dry-run capability for testing changes
3. Easy rollback mechanism
4. Alert on sync failures

### Risk 2: Performance Impact of Frequent Regeneration

**Probability:** Low
**Impact:** Medium

**Mitigation:**
1. Cache generated manifests
2. Only regenerate when CUE files change
3. Parallel manifest generation for multiple environments
4. Optimize CUE evaluation

### Risk 3: Learning Curve for Teams

**Probability:** High
**Impact:** Low

**Mitigation:**
1. Comprehensive documentation
2. Training sessions
3. Templates and examples
4. Dedicated support during transition

### Risk 4: Configuration Drift

**Probability:** Medium
**Impact:** Medium

**Mitigation:**
1. Make `services/apps/` read-only via CI checks
2. Clear documentation on proper workflow
3. Automated drift detection
4. Regular audits

### Risk 5: Breaking Changes in Base Templates

**Probability:** Medium
**Impact:** High

**Mitigation:**
1. Comprehensive validation pipeline
2. Version CUE schemas
3. Regression tests for all apps
4. Gradual rollout of template changes
5. Rollback procedures

---

## Glossary

**Application Repository:** Individual Git repository containing application source code, owned by application team.

**k8s-deployments Repository:** Centralized Git repository containing CUE-based Kubernetes deployment configurations.

**Sync:** Process of copying `deployment/app.cue` from application repository to `k8s-deployments/services/apps/` during CI/CD pipeline.

**Environment Branch:** Git branch in k8s-deployments representing a deployment environment (dev, stage, prod).

**Manifest Generation:** Process of converting CUE configuration to Kubernetes YAML using `generate-manifests.sh`.

**Bootstrap:** Process of setting up initial configuration for a new application in the deployment platform.

**Validation Pipeline:** Automated checks that run on configuration changes to ensure correctness before deployment.

---

## Appendix A: File Locations Reference

### Application Repository Structure

```
example-app/
├── src/main/java/com/example/app/     # Application source code
├── src/test/java/com/example/app/     # Tests
├── deployment/
│   └── app.cue                        # App-specific CUE config (OWNED BY APP TEAM)
├── Jenkinsfile                        # CI/CD pipeline
├── pom.xml                            # Maven configuration
└── README.md
```

### k8s-deployments Repository Structure

```
k8s-deployments/
├── services/
│   ├── base/
│   │   ├── schema.cue                 # #AppConfig schema definition
│   │   └── defaults.cue               # Default values
│   ├── core/
│   │   └── app.cue                    # #App template
│   ├── resources/
│   │   ├── deployment.cue             # Deployment template
│   │   ├── service.cue                # Service templates
│   │   ├── configmap.cue              # ConfigMap template
│   │   ├── secret.cue                 # Secret template
│   │   └── pvc.cue                    # PVC template
│   └── apps/
│       └── example-app.cue            # SYNCED from example-app/deployment/app.cue
├── envs/
│   ├── dev.cue                        # Dev environment config
│   ├── stage.cue                      # Stage environment config
│   └── prod.cue                       # Prod environment config
├── manifests/
│   ├── dev/
│   │   └── example-app.yaml           # Generated Kubernetes YAML
│   ├── stage/
│   └── prod/
└── scripts/
    ├── generate-manifests.sh          # Manifest generation
    ├── validate-manifests.sh          # YAML validation
    ├── validate-cue-config.sh         # CUE validation
    ├── test-cue-integration.sh        # Integration tests
    └── add-new-app.sh                 # Bootstrap new applications
```

---

## Appendix B: Example Configurations

### Example: deployment/app.cue

```cue
// Package deployment defines application-specific configuration for example-app
// This file is OWNED by the application team and lives in the app repository
// It is automatically synced to k8s-deployments during CI/CD
package deployment

import (
    core "deployments.local/k8s-deployments/services/core"
)

// example-app application configuration
exampleApp: core.#App & {
    // Set the application name
    appName: "example-app"

    // App-level environment variables (applied to all instances across all environments)
    appEnvVars: [
        {
            name: "QUARKUS_HTTP_PORT"
            value: "8080"
        },
        {
            name: "QUARKUS_LOG_CONSOLE_ENABLE"
            value: "true"
        },
        {
            name: "REDIS_URL"
            value: "redis://redis.cache.svc.cluster.local:6379"
        },
    ]

    // Application-level configuration defaults
    // These can be overridden by environment-specific configs
    appConfig: {
        // Health check configuration
        healthCheck: {
            path: "/health/ready"
            port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
        }

        // Service configuration uses default HTTP port (80 -> 8080)
        // No additional ports needed
    }
}
```

### Example: envs/dev.cue

```cue
// Development environment configuration
package envs

import (
    "deployments.local/k8s-deployments/services/apps"
)

// Development environment settings for example-app
dev: exampleApp: apps.exampleApp & {
    // Override namespace for dev
    appConfig: {
        namespace: "dev"

        labels: {
            environment: "dev"
            managed_by: "argocd"
        }

        // Enable debug mode in dev
        debug: true

        // Deployment configuration
        deployment: {
            // Image will be updated by CI/CD pipeline
            image: "docker.local/example/example-app:1.0.0-SNAPSHOT-abc1234"

            // Lower replicas in dev
            replicas: 1

            // Resource limits for dev
            resources: {
                requests: {
                    cpu: "100m"
                    memory: "256Mi"
                }
                limits: {
                    cpu: "500m"
                    memory: "512Mi"
                }
            }

            // Dev-specific environment variables
            additionalEnv: [
                {
                    name: "QUARKUS_LOG_LEVEL"
                    value: "DEBUG"
                },
                {
                    name: "ENVIRONMENT"
                    value: "dev"
                },
            ]
        }

        // ConfigMap data for development environment
        configMap: {
            data: {
                "log-level": "debug"
                "feature-flags": "experimental-features=true"
            }
        }
    }
}
```

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-04 | Claude Code | Initial architecture design and implementation plan |

---

**End of Document**
