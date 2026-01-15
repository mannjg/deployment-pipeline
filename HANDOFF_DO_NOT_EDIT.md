# Session Handoff

**Date:** 2026-01-15
**Last Version:** 1.0.20-SNAPSHOT deployed to dev/stage/prod

## Completed Iterations

| Iteration | Description | Status |
|-----------|-------------|--------|
| 1 | Dev deployment (commit → build → deploy) | Done |
| 2 | Stage promotion (dev → stage) | Done |
| 3 | Prod promotion (stage → prod) | Done |
| 4 | Infrastructure health checks | Done |
| 5 | Pattern validation (CUE schema) | **Not started** |

## Key Scripts

| Script | Purpose | Runtime |
|--------|---------|---------|
| `./validate-pipeline.sh` | Full pipeline: bump version → dev → stage → prod | ~4 min |
| `./check-health.sh` | Quick infra health check (no pipeline exercise) | ~5 sec |

## What's Working

- Full GitOps flow: dev → stage → prod with automated MR creation and merge
- Jenkins CSRF crumb handling for API calls
- ArgoCD sync detection waits for revision change (not just status)
- Image tag validation before merge
- Separate promotion pipeline (promotes what's proven, not planned)

## Known Issues / Gotchas

1. **ArgoCD prod app URL** - Had to change from internal (`gitlab.gitlab.svc`) to external URL (`gitlab.jmann.local`) for credentials to work
2. **Nexus API requires auth** - Health check uses web UI response code instead of REST API
3. **Pod label variations** - Jenkins uses `app=jenkins`, not `app.kubernetes.io/name=jenkins`

## Reference Documents

See `docs/plans/` for detailed designs:
- `2026-01-14-validate-pipeline-design.md` - Original iteration roadmap (Iterations 1-5)
- `2026-01-15-gitops-promotion-redesign.md` - Promotion architecture
- `2026-01-15-gitops-promotion-implementation.md` - Step-by-step implementation

## Next: Iteration 5 (Pattern Validation)

From `docs/plans/2026-01-14-validate-pipeline-design.md`:
- CUE schema compilation
- GitOps repo structure validation
- Webhook configuration checks

## Quick Commands

```bash
# Check infrastructure health
./check-health.sh

# Run full pipeline validation
./validate-pipeline.sh

# Reset demo state (after changing k8s-deployments)
git push origin main && ./scripts/sync-to-gitlab.sh && ./scripts/setup-gitlab-env-branches.sh --reset

# Create Jenkins promote job (if missing)
./scripts/setup-jenkins-promote-job.sh
```

## Git State

Working tree should be clean. All changes pushed to GitHub origin.
