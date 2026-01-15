# Handoff Document

**Date:** 2026-01-15
**Status:** Iteration 3 (Prod Promotion) complete and validated

## Current State

The `validate-pipeline.sh` script successfully executes the full dev-to-stage-to-prod promotion flow:

1. Bumps version in pom.xml, pushes to GitHub, syncs to GitLab
2. Waits for Jenkins CI build to complete
3. Finds and merges the dev MR (with image validation)
4. Waits for ArgoCD sync (with revision change detection)
5. Verifies pod is running with correct image
6. Triggers `promote-environment` Jenkins job (dev -> stage)
7. Waits for promotion job to complete
8. Finds and merges stage MR
9. Waits for ArgoCD sync (stage)
10. Verifies stage pod running with correct image
11. Triggers `promote-environment` Jenkins job (stage -> prod)
12. Waits for promotion job to complete
13. Finds and merges prod MR
14. Waits for ArgoCD sync (prod)
15. Verifies prod pod running with correct image

**Last successful run:** Version 1.0.20-SNAPSHOT deployed to dev, stage, and prod in ~3m 50s.

## Reference Documents

| Document | Purpose |
|----------|---------|
| `docs/plans/2026-01-14-validate-pipeline-design.md` | Original pipeline validation design |
| `docs/plans/2026-01-15-gitops-promotion-redesign.md` | Promotion flow design (CI separation) |
| `docs/plans/2026-01-15-gitops-promotion-implementation.md` | Implementation tasks for promotion |

## Key Files

| File | Purpose |
|------|---------|
| `validate-pipeline.sh` | End-to-end pipeline validation script |
| `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote` | Promotion pipeline (dev->stage, stage->prod) |
| `scripts/setup-jenkins-promote-job.sh` | Creates Jenkins promote-environment job |
| `scripts/setup-gitlab-env-branches.sh` | Creates/resets dev/stage/prod branches |

## What's Working Well

- **CSRF handling:** Jenkins API calls use crumb authentication
- **Image verification:** Waits for pod with expected image tag before promotion
- **ArgoCD sync detection:** Detects revision changes, not just status
- **Promotion separation:** CI builds dev MR, promotion pipeline creates stage/prod MRs

## Bug Fixes Applied This Session

1. **APP_GROUP mismatch** - Changed from `example` to `p2c` everywhere
2. **Jenkins CSRF** - Added crumb handling for API calls
3. **BUILD_URL reference** - Fixed to `env.BUILD_URL` in Jenkinsfile.promote
4. **ArgoCD sync race** - Now waits for revision change, not just status
5. **Image verification race** - Waits for pod with correct image tag
6. **Stage ArgoCD app** - Fixed manifest paths and applied to cluster
7. **Prod ArgoCD app** - Fixed URL (internal->external) and path (added prod app)

## Not Yet Implemented

From `docs/plans/2026-01-15-gitops-promotion-redesign.md` "Future Iterations":

- **Iteration 4:** Component health checks (quick infrastructure verification)
- **Iteration 5:** Pattern validation (CUE schema, GitOps structure checks)

## Workflow Order (Critical)

The setup script reads from GitLab's main branch. Changes must be synced before setup.

| Scenario | Commands |
|----------|----------|
| Full reset | `git push origin main` -> `sync-to-gitlab.sh` -> `setup-gitlab-env-branches.sh --reset` |
| Validation only | `./validate-pipeline.sh` |
| Create Jenkins job | `./scripts/setup-jenkins-promote-job.sh` |

## Git State

- GitHub (origin): All changes pushed
- GitLab subtrees: Synced
- Working tree: Clean (pending this commit)
