# Git Remote Strategy

**Date:** 2026-01-13
**Status:** Active

## Overview

This repository uses a **monorepo-with-subtree-publishing** pattern to support both centralized development (GitHub) and distributed CI/CD execution (GitLab).

## The Problem

We need:
1. A single repository for development containing all pipeline infrastructure
2. Separate GitLab repositories for CI/CD execution (webhooks, Jenkins triggers, ArgoCD)
3. The ability to develop everything together while deploying components independently

## Solution Architecture

```
deployment-pipeline/              ← GitHub: mannjg/deployment-pipeline (full monorepo)
├── example-app/                  ← GitLab: p2c/example-app (subtree)
│   ├── src/
│   ├── Jenkinsfile
│   └── pom.xml
├── k8s-deployments/              ← GitLab: p2c/k8s-deployments (subtree)
│   ├── manifests/
│   ├── Jenkinsfile
│   └── scripts/
├── scripts/                      ← Not synced to GitLab
├── argocd/                       ← Not synced to GitLab
├── k8s/                          ← Not synced to GitLab
├── config/                       ← Not synced to GitLab
└── docs/                         ← Not synced to GitLab
```

## Key Principle: GitHub is Always Complete

GitHub (`origin`) ALWAYS receives the complete monorepo—every file, every commit, every folder.

The phrase "not synced to GitLab" means those files are not duplicated to GitLab subtrees.
It does NOT mean they skip GitHub or have special handling.

**Push workflow (always in this order):**
1. Push to GitHub (`git push origin main`) — full repo, all files
2. Sync subtrees to GitLab — only if `example-app/` or `k8s-deployments/` changed

```
Your commit
    │
    ├──► GitHub (origin)     ← ALWAYS gets everything
    │
    └──► GitLab subtrees     ← Only example-app/ and k8s-deployments/
                               (and only when those folders changed)
```

## Remote Configuration

### Required Remotes

| Remote Name | URL | Purpose |
|-------------|-----|---------|
| `origin` | `git@github.com:mannjg/deployment-pipeline.git` | Primary development (full monorepo) |
| `gitlab-app` | `https://gitlab.jmann.local/p2c/example-app.git` | Subtree target for example-app |
| `gitlab-deployments` | `https://gitlab.jmann.local/p2c/k8s-deployments.git` | Subtree target for k8s-deployments |

### Setup Commands

```bash
# From deployment-pipeline root directory

# Set origin to GitHub (primary remote)
git remote remove origin 2>/dev/null || true
git remote add origin git@github.com:mannjg/deployment-pipeline.git

# Add GitLab remotes for subtree publishing
git remote add gitlab-app https://gitlab.jmann.local/p2c/example-app.git
git remote add gitlab-deployments https://gitlab.jmann.local/p2c/k8s-deployments.git

# Verify
git remote -v
```

## Workflows

### Daily Development

All development happens in the monorepo. Push to GitHub as normal:

```bash
git add -A
git commit -m "feat: your changes"
git push origin main
```

### Syncing to GitLab

After pushing to GitHub, sync the subtrees to GitLab for CI/CD:

```bash
# Sync example-app subfolder to GitLab
git subtree push --prefix=example-app gitlab-app main

# Sync k8s-deployments subfolder to GitLab
git subtree push --prefix=k8s-deployments gitlab-deployments main
```

Or use the helper script:

```bash
./scripts/sync-to-gitlab.sh
```

### Helper Script

Create `scripts/sync-to-gitlab.sh`:

```bash
#!/bin/bash
# Sync subtrees to GitLab for CI/CD pipeline execution
#
# This script publishes the example-app and k8s-deployments subfolders
# to their respective GitLab repositories, enabling:
# - GitLab webhooks to trigger Jenkins
# - ArgoCD to watch k8s-deployments
# - Independent CI/CD execution per component

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "=== Syncing subtrees to GitLab ==="

echo "Syncing example-app..."
git subtree push --prefix=example-app gitlab-app main

echo "Syncing k8s-deployments..."
git subtree push --prefix=k8s-deployments gitlab-deployments main

echo ""
echo "✓ Sync complete"
echo "  - example-app      → gitlab.jmann.local/p2c/example-app"
echo "  - k8s-deployments  → gitlab.jmann.local/p2c/k8s-deployments"
```

## How Git Subtree Works

Git subtree extracts a subfolder's history and pushes it as if it were a standalone repository:

1. **Filtering**: Only commits affecting `example-app/` are included
2. **Path rewriting**: `example-app/src/Main.java` becomes `src/Main.java`
3. **History preservation**: Commit messages and authors are preserved
4. **No submodules**: The subfolder remains regular files (not a submodule reference)

### Example

```
# In deployment-pipeline (GitHub)
deployment-pipeline/
├── example-app/
│   └── src/Main.java        ← commit: "feat: add feature"
└── scripts/
    └── setup.sh             ← commit: "chore: update script"

# After subtree push to GitLab p2c/example-app
example-app/
└── src/Main.java            ← commit: "feat: add feature"
                             (scripts/ commit is NOT included)
```

## When to Sync

| Scenario | Action |
|----------|--------|
| Changed files only in `example-app/` | Sync example-app to GitLab |
| Changed files only in `k8s-deployments/` | Sync k8s-deployments to GitLab |
| Changed files in both | Sync both to GitLab |
| Changed files outside subfolders | No GitLab sync needed |
| Want to trigger CI/CD | Sync the relevant subtree |

## CI/CD Flow

```
Developer Machine                    GitHub                         GitLab (Airgap)
─────────────────                    ──────                         ───────────────

git commit
git push origin ──────────────────> mannjg/deployment-pipeline
                                         │
./scripts/sync-to-gitlab.sh              │
    │                                    │
    ├── subtree push example-app ────────┼───────────────────────> p2c/example-app
    │                                    │                              │
    │                                    │                              ├── Webhook
    │                                    │                              │     │
    │                                    │                              │     ▼
    │                                    │                              │   Jenkins
    │                                    │                              │     │
    └── subtree push k8s-deployments ────┼───────────────────────> p2c/k8s-deployments
                                         │                              │
                                         │                              ├── ArgoCD watches
                                         │                              │     │
                                         │                              │     ▼
                                         │                              │   Kubernetes
```

## Troubleshooting

### "Updates were rejected because the tip of your current branch is behind"

The GitLab repo has commits not in your local subtree. This shouldn't happen if GitLab is only written to via subtree push. To fix:

```bash
# Force push (use with caution)
git push gitlab-app $(git subtree split --prefix=example-app):main --force
```

### Subtree push is slow

For large repositories, `git subtree push` can be slow because it recalculates the split each time. Use split + push for speed:

```bash
# Split once, push the result
git subtree split --prefix=example-app -b temp-split
git push gitlab-app temp-split:main
git branch -D temp-split
```

### "Working tree has modifications"

Subtree operations require a clean working tree:

```bash
git stash
git subtree push --prefix=example-app gitlab-app main
git stash pop
```

## Why Not Alternatives?

### Why not Git Submodules?

- GitHub would only contain submodule references, not actual files
- Breaks requirement #3 (GitHub should have full source)
- Submodule workflows are complex and error-prone

### Why not Three Separate Repos?

- Coordinating changes across repos is painful
- Can't atomic commit changes spanning app + deployment config
- Harder to maintain consistency

### Why not Just GitLab?

- GitHub provides better visibility for the reference implementation
- Airgap environments can't reach GitHub
- Need both for different purposes

## Related Documentation

Historical design docs (archived):
- [Revitalization Design](archives/plans/2026-01-12-revitalization-design.md)
- [GitLab P2C Migration](archives/plans/2026-01-13-gitlab-p2c-migration-design.md)
