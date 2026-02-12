# Invariants

These rules are non-negotiable. Violations should be prevented by checks and surfaced early.

## Git Remote Strategy (Critical)

This repo uses **monorepo-with-subtree-publishing**:

- **GitHub (`origin`)**: Always receives the COMPLETE repo - every file, every commit.
- **GitLab**: Receives only `example-app/` and `k8s-deployments/` as separate repos for CI/CD.

**Workflow (always in this order):**
1. `git push origin main` - full repo to GitHub.
2. `./scripts/04-operations/sync-to-gitlab.sh` - subtrees to GitLab (only if those folders changed).

**Why:** GitLab triggers Jenkins webhooks and ArgoCD watches. GitHub is the source of truth.

See `docs/GIT_REMOTE_STRATEGY.md` for full details.

## Environment Branch Modification Invariant (Critical)

**Environment branches (dev, stage, prod) are ONLY modified via merged MRs. No exceptions.**

This invariant ensures:
1. Jenkins regenerates manifests (it skips manifest generation on direct env branch commits).
2. All changes are auditable via MR history.
3. Operational scripts follow the same workflow as development.

**Correct pattern:**
```
feature branch -> commit changes -> MR to env -> Jenkins CI -> merge
```

**Incorrect patterns (NEVER do these):**
- Direct GitLab API file modifications to env branches.
- Git push directly to env branches.
- Any bypass of the MR workflow.

The reset-demo-state.sh script follows this pattern by creating MRs for each environment.

## Workflow Order (Critical)

| Scenario | Commands |
|---------|----------|
| Initial bootstrap (first time) | `git push origin main` -> `sync-to-gitlab.sh` -> `setup-gitlab-env-branches.sh` |
| After k8s-deployments core changes | `git push origin main` -> `sync-to-gitlab.sh` -> `reset-demo-state.sh` |
| After example-app changes only | `git push origin main` -> `demo-uc-e1-app-deployment.sh` (syncs example-app internally) |
| Demo reset / validation | `reset-demo-state.sh` -> `run-all-demos.sh` |
