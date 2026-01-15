# Handoff Document

**Date:** 2026-01-15
**Status:** Iteration 2 (Stage Promotion) complete and validated

## What's Working

The `validate-pipeline.sh` script successfully:
1. Bumps version, pushes to GitHub, syncs to GitLab
2. Waits for Jenkins build to complete
3. Finds and merges the dev MR (with image validation)
4. Waits for ArgoCD sync (with revision change detection)
5. Verifies pod is running with correct image
6. **NEW:** Triggers `promote-environment` Jenkins job (dev -> stage)
7. **NEW:** Waits for promotion job to complete
8. **NEW:** Finds and merges stage MR
9. **NEW:** Waits for ArgoCD sync (stage)
10. **NEW:** Verifies stage pod running with correct image

**Last successful run:** Version 1.0.19-SNAPSHOT deployed to dev and stage in ~2m 46s.

## Key Changes (This Session)

### New Files Created
| File | Purpose |
|------|---------|
| `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote` | Promotion pipeline for dev->stage and stage->prod |
| `scripts/setup-jenkins-promote-job.sh` | Creates promote-environment Jenkins job via API |
| `docs/plans/2026-01-15-gitops-promotion-redesign.md` | Design document for the promotion flow |
| `docs/plans/2026-01-15-gitops-promotion-implementation.md` | Implementation plan |

### Files Modified
| File | Changes |
|------|---------|
| `config/infra.env` | Added `JENKINS_PROMOTE_JOB_NAME` |
| `example-app/Jenkinsfile` | Removed stage/prod promotion stages (205 lines), changed `APP_GROUP` to `p2c` |
| `validate-pipeline.sh` | Added promotion functions, CSRF handling, ArgoCD revision detection |
| `k8s-deployments/example-env.cue` | Changed `APP_GROUP` from `example` to `p2c` |
| `argocd/applications/example-app-stage.yaml` | Fixed repo URL and path |

### Key Scripts
| Script | Purpose |
|--------|---------|
| `validate-pipeline.sh` | End-to-end pipeline validation (dev + stage) |
| `scripts/setup-jenkins-promote-job.sh` | Creates Jenkins promote-environment job |
| `scripts/setup-gitlab-env-branches.sh` | Creates/resets dev/stage/prod branches in GitLab |
| `scripts/sync-to-gitlab.sh` | Syncs subtrees (example-app, k8s-deployments) to GitLab |

## Architecture Change: Separate CI and Promotion

**Previous:** Jenkins CI pipeline created all 3 MRs (dev, stage, prod) at build time.

**New:**
- CI pipeline creates only dev MR
- Promotion pipeline (`promote-environment`) creates stage/prod MRs on demand
- Promotions triggered after verifying previous environment is healthy

This ensures "promote what's proven, not what was planned."

## Workflow Order (Critical)

The setup script reads from **GitLab's main branch**, not local files. See CLAUDE.md for full workflow.

| Scenario | Commands |
|----------|----------|
| Full reset | `git push origin main` -> `sync-to-gitlab.sh` -> `setup-gitlab-env-branches.sh --reset` |
| Validation only | `./validate-pipeline.sh` |
| Create Jenkins job | `./scripts/setup-jenkins-promote-job.sh` |

## Bug Fixes Applied

1. **APP_GROUP mismatch** - Changed from `example` to `p2c` to match GitLab group
2. **Jenkins CSRF crumb** - Added crumb handling for API calls
3. **BUILD_URL reference** - Fixed to `env.BUILD_URL` in Jenkinsfile
4. **ArgoCD sync detection** - Now waits for revision to change, not just status
5. **Image verification** - Waits for pod with correct image tag before promotion
6. **Stage ArgoCD app** - Fixed manifest path and applied to cluster

## Reference Plans

- `docs/plans/2026-01-14-validate-pipeline-design.md` - Original design
- `docs/plans/2026-01-15-gitops-promotion-redesign.md` - Promotion flow design
- `docs/plans/2026-01-15-gitops-promotion-implementation.md` - Implementation tasks

## Not Yet Implemented

From the design doc's "Future Iterations":
- **Iteration 3:** Prod promotion
- **Iteration 4:** Component health checks (quick infrastructure check)
- **Iteration 5:** Pattern validation (CUE schema, GitOps structure)

## Git State

- GitHub (origin): All changes pushed
- GitLab subtrees: Synced
- Working tree: Clean (after next commit)
