# Handoff Document - Pipeline Validation

**Date:** 2026-01-14
**Plans:**
- `docs/plans/2026-01-14-validate-pipeline-implementation.md` - Original validate-pipeline.sh plan (complete)
- `/home/jmann/.claude/plans/cozy-snuggling-wombat.md` - Setup script plan (in progress)

## Current Objective

Get `validate-pipeline.sh` working end-to-end. The pipeline now runs through Jenkins successfully, but **ArgoCD deployment fails due to image pull errors**.

## Progress Summary

| Component | Status |
|-----------|--------|
| validate-pipeline.sh | Complete (per original plan) |
| Webhook integration | Working |
| Jenkins build | Working (Build #57 succeeded) |
| setup-gitlab-env-branches.sh | Created and working |
| ArgoCD sync | Failing - ImagePullBackOff |

## What's Working

1. **validate-pipeline.sh** - Implemented per plan, runs through all stages
2. **Webhook Integration** - GitLab → Jenkins triggers automatically
3. **Jenkins Build #57** - Completed successfully, created update branch with correct image
4. **setup-gitlab-env-branches.sh** - New script that populates env.cue on GitLab environment branches
5. **infra.env** - Added `GITLAB_USER_SECRET` and `GITLAB_USER_KEY` for username retrieval

## What's Failing

**Pod stuck in ImagePullBackOff:**
```
Failed to pull image "nexus.nexus.svc.cluster.local:5000/example/example-app:latest":
dial tcp: lookup nexus.nexus.svc.cluster.local on 127.0.0.53:53: server misbehaving
```

**Root Cause:** `example-env.cue` uses internal registry URL (`nexus.nexus.svc.cluster.local:5000`) which kubelet cannot resolve. Should use external URL (`docker.jmann.local`).

## Architecture Understanding

**Branch-per-environment in k8s-deployments:**
- `main` branch: Has `example-env.cue` (seed template) and empty `env.cue`
- `dev/stage/prod` branches: Have transformed `env.cue` with environment-specific values
- Subtree sync only pushes to `main` - environment branches are managed separately

**Jenkins MR Flow:**
- Jenkins creates feature branches (e.g., `update-dev-1.0.6-SNAPSHOT-f54ec26`)
- Jenkins creates Merge Requests targeting environment branches
- MRs must be merged for ArgoCD to pick up changes
- The update branch has correct image: `docker.jmann.local/example/example-app:1.0.6-SNAPSHOT-f54ec26`

## Next Steps

1. **Fix example-env.cue** - Change image URL from internal to external registry:
   ```
   # Current (broken):
   image: "nexus.nexus.svc.cluster.local:5000/example/example-app:latest"

   # Should be:
   image: "docker.jmann.local/example/example-app:latest"
   ```

2. **Re-run setup script** - Regenerate dev branch env.cue:
   ```bash
   ./scripts/setup-gitlab-env-branches.sh --reset
   ```

3. **Consider flow adjustment** - Either:
   - Modify validate-pipeline.sh to auto-merge the MR, OR
   - Accept MR-based flow as intentional (manual gate)

## Key Files

| File | Purpose |
|------|---------|
| `k8s-deployments/example-env.cue` | Seed template - **needs image URL fix** |
| `scripts/setup-gitlab-env-branches.sh` | Creates/populates GitLab env branches |
| `config/infra.env` | Infrastructure config (updated with user secret config) |
| `validate-pipeline.sh` | End-to-end validation script |
| `example-app/Jenkinsfile` | CI/CD pipeline (working correctly) |

## Recent Changes This Session

1. Created `scripts/setup-gitlab-env-branches.sh`
2. Updated `config/infra.env` - added `GITLAB_USER_SECRET`, `GITLAB_USER_KEY`
3. Updated `CLAUDE.md` - documented demo setup workflow
4. Populated dev branch env.cue via setup script
5. Jenkins build #57 succeeded (was failing before due to empty env.cue)

## Verification Commands

```bash
# Check dev branch env.cue
git fetch gitlab-deployments dev
git show gitlab-deployments/dev:env.cue | grep "image:"

# Check pod status
kubectl get pods -n dev
kubectl describe pod -n dev -l app=example-app | tail -20

# Check Jenkins update branch (has correct image)
git show gitlab-deployments/update-dev-1.0.6-SNAPSHOT-f54ec26:env.cue | grep "image:"
```
