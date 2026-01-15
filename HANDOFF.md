# Handoff Document

**Date:** 2026-01-15
**Status:** Pipeline validation working end-to-end

## What's Working

The `validate-pipeline.sh` script successfully:
1. Bumps version, pushes to GitHub, syncs to GitLab
2. Waits for Jenkins build to complete
3. Finds and merges the dev MR (with image validation)
4. Waits for ArgoCD sync
5. Verifies pod is running with correct image

**Last successful run:** Version 1.0.8-SNAPSHOT deployed to dev in ~4 minutes.

## Key Scripts

| Script | Purpose |
|--------|---------|
| `validate-pipeline.sh` | End-to-end pipeline validation |
| `scripts/setup-gitlab-env-branches.sh` | Creates/resets dev/stage/prod branches in GitLab |
| `scripts/sync-to-gitlab.sh` | Syncs subtrees (example-app, k8s-deployments) to GitLab |

## Workflow Order (Critical)

The setup script reads from **GitLab's main branch**, not local files. See CLAUDE.md for full workflow.

| Scenario | Commands |
|----------|----------|
| Full reset | `git push origin main` → `sync-to-gitlab.sh` → `setup-gitlab-env-branches.sh --reset` |
| Validation only | `./validate-pipeline.sh` |

## Session Changes

1. **validate-pipeline.sh enhancements:**
   - Added `merge_dev_mr()` - finds MR by version, validates image, merges
   - Added `verify_mr_image()` - parses YAML manifest to validate image URL
   - Handles multiple open MRs correctly (matches by version)

2. **Configuration:**
   - `config/infra.env`: Added `APP_CUE_NAME` for parameterized app name
   - `k8s-deployments/example-env.cue`: Uses placeholder URL (`REGISTRY_URL_NOT_SET/...`)

3. **Documentation:**
   - `CLAUDE.md`: Removed microk8s references (use `kubectl` directly)
   - `CLAUDE.md`: Added workflow order documentation

## Reference Plans

- `docs/plans/2026-01-14-validate-pipeline-design.md` - Design rationale
- `docs/plans/2026-01-14-validate-pipeline-implementation.md` - Original implementation tasks

## Not Yet Implemented

From the design doc's "Future Iterations":
- **Iteration 2:** Stage promotion (MR dev→stage, verify)
- **Iteration 3:** Prod promotion
- **Iteration 4:** Component health checks (quick infrastructure check)
- **Iteration 5:** Pattern validation (CUE schema, GitOps structure)

## Git State

- GitHub (origin): All changes pushed
- GitLab subtrees: Synced
- Working tree: Clean
