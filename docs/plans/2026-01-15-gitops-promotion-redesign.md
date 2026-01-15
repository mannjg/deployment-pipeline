# GitOps Promotion Pipeline Redesign

**Date:** 2026-01-15
**Status:** Approved
**Scope:** Iteration 2+ - Proper GitOps promotion flow

## Problem Statement

The current Jenkins pipeline creates all promotion MRs (dev, stage, prod) during a single build. This is fundamentally flawed:

1. **Fixes don't propagate** - If a developer edits the dev MR to fix an issue, the stage/prod MRs still have the old broken config
2. **Premature promotion** - Stage MR exists before dev is verified healthy
3. **Violates GitOps principles** - Should "promote what's proven, not what was planned"

### Example Failure Scenario

```
1. Jenkins build creates all 3 MRs (same snapshot)
2. Reviewer finds bug in dev MR (wrong resource limits)
3. Developer edits update-dev branch to fix it
4. Dev MR merged with fix
5. Stage MR still has OLD broken config ← Problem!
6. Merging stage MR deploys broken code
```

## Solution: Separate CI and Promotion Pipelines

### Architecture

```
Pipeline 1: CI Pipeline (triggered by app repo push)
├── Build
├── Test
├── Publish image
└── Create dev MR
    └── DONE - CI's job is finished

Pipeline 2: Promotion Pipeline (triggered after previous env verified)
├── Get current image from source environment
├── Create promotion MR for target environment
└── DONE
```

### Pipeline Inventory

| Pipeline | Location | Trigger | Output |
|----------|----------|---------|--------|
| `example-app-ci` | `example-app/Jenkinsfile` | App repo push | Dev MR |
| `promote-environment` | `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote` | API call / Manual / Webhook | Stage or Prod MR |

## Promotion Pipeline Design

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `APP_NAME` | string | Yes | Application to promote (e.g., `example-app`) |
| `SOURCE_ENV` | choice (dev/stage) | Yes | Environment to promote from |
| `TARGET_ENV` | choice (stage/prod) | Yes | Environment to promote to |
| `IMAGE_TAG` | string | No | Specific tag, or auto-detect from source env |

### Pipeline Flow

```groovy
1. Validate parameters
   - Ensure valid progression: dev→stage or stage→prod

2. Resolve image tag (if not provided)
   - Query SOURCE_ENV deployment for current image

3. Clone k8s-deployments repository
   - Checkout TARGET_ENV branch
   - Create feature branch: promote-{TARGET_ENV}-{IMAGE_TAG}

4. Update configuration
   - Run ./scripts/update-app-image.sh {TARGET_ENV} {APP_NAME} {IMAGE}
   - Run ./scripts/generate-manifests.sh {TARGET_ENV}

5. Commit and push
   - Commit with promotion metadata
   - Push feature branch

6. Create MR
   - Via ./scripts/create-gitlab-mr.sh
   - Target: TARGET_ENV branch
```

### Trigger Methods

| Method | Use Case | Example |
|--------|----------|---------|
| Jenkins UI | Manual promotion | Click "Build with Parameters" |
| API call | Script automation | `curl -X POST .../buildWithParameters` |
| Webhook | ArgoCD notification | Future enhancement |

## CI Jenkinsfile Changes

### Remove

- `Promote to Stage` stage (lines 570-609)
- `Promote to Prod` stage (lines 612-655)
- `SKIP_STAGE_PROMOTION` parameter
- `SKIP_PROD_PROMOTION` parameter

### Keep

- `deployToEnvironment` function - used for dev MR, has app.cue sync logic
- All CI stages through "Update Dev Environment"

### Move

- `promoteEnvironment` function → `Jenkinsfile.promote`

### Resulting CI Stages

```
1. Checkout & Setup
2. Unit Tests
3. Integration Tests
4. Build & Publish
5. Update Dev Environment  ← Terminal stage
```

## Validate Script Changes

### New Flow

```bash
# Iteration 1 (existing)
1. Bump version, push to GitLab
2. Wait for CI build to complete
3. Merge dev MR
4. Wait for ArgoCD sync (dev)
5. Verify dev pod healthy

# Iteration 2 (new)
6. Trigger promote-environment job (dev→stage)
7. Wait for promote job to complete
8. Merge stage MR
9. Wait for ArgoCD sync (stage)
10. Verify stage pod healthy

# Iteration 3 (future)
11. Trigger promote-environment job (stage→prod)
12. Wait for promote job to complete
13. Merge prod MR
14. Wait for ArgoCD sync (prod)
15. Verify prod pod healthy
```

### New Functions Needed

```bash
trigger_promotion_job()    # POST to Jenkins API with parameters
wait_for_promotion_job()   # Poll Jenkins for job completion
merge_env_mr()             # Generic version of merge_dev_mr()
wait_for_env_sync()        # Generic version of wait_for_argocd_sync()
verify_env_deployment()    # Generic version of verify_deployment()
```

## Jenkins Configuration

### New Job: `promote-environment`

- **Type:** Pipeline
- **Pipeline source:** SCM (GitLab)
- **Repository:** k8s-deployments
- **Script path:** `jenkins/pipelines/Jenkinsfile.promote`
- **Parameters:** As defined above

### Setup Method

Either:
1. Manual creation via Jenkins UI
2. JCasC (Jenkins Configuration as Code)
3. Job DSL script

For the demo, manual creation is sufficient.

## File Changes Summary

| File | Action |
|------|--------|
| `example-app/Jenkinsfile` | Remove stage/prod promotion stages and params |
| `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote` | **New** - promotion pipeline |
| `validate-pipeline.sh` | Add promotion triggering and stage verification |
| `config/infra.env` | Add `PROMOTE_JOB_NAME` if needed |

## Implementation Order

1. **Create `Jenkinsfile.promote`** - New promotion pipeline
2. **Create Jenkins job** - `promote-environment` pointing to new Jenkinsfile
3. **Test promotion job** - Manual trigger via UI to verify it works
4. **Modify CI Jenkinsfile** - Remove stage/prod stages
5. **Update validate script** - Add promotion triggering and stage verification
6. **End-to-end test** - Run full validation

## Rollback Plan

If issues arise:
1. Revert CI Jenkinsfile changes (re-add stage/prod stages)
2. Keep promote-environment job (doesn't conflict)
3. Validate script can fall back to using Jenkins-created MRs

## Future Enhancements

- **Webhook triggers** - ArgoCD calls promote job on successful sync
- **Approval gates** - Require manual approval for prod promotion
- **Slack/notification integration** - Alert on promotion events
- **Automatic rollback** - Revert if health check fails after promotion
