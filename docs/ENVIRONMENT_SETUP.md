# Environment Setup

This doc covers environment branch setup and demo state management.

## Demo Setup: Environment Branches

The k8s-deployments repo uses **branch-per-environment** (dev/stage/prod branches in GitLab).
These branches are NOT managed by subtree sync - they're created directly in GitLab.

**Initial Setup (run once after syncing subtrees):**
```bash
export GITLAB_USER="root"  # or your GitLab username
export GITLAB_TOKEN="your-gitlab-token"  # or let script get from K8s secret
./scripts/03-pipelines/setup-gitlab-env-branches.sh
```

This script:
1. Clones k8s-deployments from GitLab.
2. Creates dev/stage/prod branches from main.
3. Transforms `seed-env.cue` into `env.cue` with environment-specific values.
4. Pushes all branches to GitLab.

## Reset Demo State (and propagate core changes)

```bash
./scripts/03-pipelines/reset-demo-state.sh
```

This script resets demo state AND propagates core files from main to env branches:
- Cleans up MRs, demo branches, Jenkins queue.
- Syncs `templates/`, `scripts/`, `Jenkinsfile` from GitLab main to dev/stage/prod via MR workflow.
- Preserves CI/CD-managed image tags in env.cue.

## Seed Template Maintenance

- `k8s-deployments/seed-env.cue` is the seed template (persisted to GitHub).
- Only used during INITIAL bootstrap (when branches don't exist).
- Once branches have valid CI/CD images, they are managed by the pipeline.
