# GitHub Sync Workflow

## Remote Configuration

**Root repository** (`deployment-pipeline/`):
- `origin` → GitHub (https://github.com/mannjg/deployment-pipeline.git)
- Purpose: Public portfolio/sharing

**Subprojects** (`example-app/`, `k8s-deployments/`, `argocd/`):
- `origin` → gitlab.local
- Purpose: CI/CD pipeline demonstration

## Why the Sync Script?

Git automatically ignores **all files** inside directories containing `.git/` subdirectories. The sync script works around this by:

1. Temporarily moving subproject `.git/` → `.git.tmp/`
2. Allowing root repo to track subproject source files
3. Restoring `.git.tmp/` → `.git/` after staging

## Sync Workflow

### 1. Run the sync script
```bash
./scripts/sync-to-github.sh
```

### 2. Review what will be committed
```bash
git status
```

### 3. Commit the snapshot
```bash
git commit -m "Snapshot: $(date +%Y-%m-%d)"
```

### 4. Push to GitHub
```bash
git push origin main
```

## Important Notes

- **One-way sync**: GitHub is a read-only snapshot, no pulls needed
- **Subproject independence**: Each subproject maintains its own git history
- **CI/CD preservation**: Subprojects always push to gitlab.local for pipeline demo
- **No conflicts**: Root and subproject repos never interact directly

## Daily Workflow

**For subproject changes** (example-app, k8s-deployments):
```bash
cd example-app/
git add .
git commit -m "Feature update"
git push origin main  # → gitlab.local (triggers CI/CD)
```

**For GitHub snapshot** (root repo):
```bash
cd /path/to/deployment-pipeline
./scripts/sync-to-github.sh
git commit -m "Snapshot: 2025-11-03"
git push origin main  # → GitHub
```
