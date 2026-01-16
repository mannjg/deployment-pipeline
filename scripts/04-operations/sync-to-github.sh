#!/bin/bash
#
# Sync subproject source code to GitHub
#
# This script temporarily moves nested .git directories so the root repo
# can track subproject source files, then restores them.
#
# Usage: ./scripts/sync-to-github.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== GitHub Sync Script ==="
echo ""

cd "$ROOT_DIR"

# List of subprojects with nested git repos
SUBPROJECTS=("example-app" "k8s-deployments" "argocd")

# Step 1: Temporarily move nested .git directories
echo "Step 1: Temporarily hiding nested .git directories..."
for project in "${SUBPROJECTS[@]}"; do
    if [ -d "$project/.git" ]; then
        echo "  - Moving $project/.git to $project/.git.tmp"
        mv "$project/.git" "$project/.git.tmp"
    fi
done
echo ""

# Step 2: Add all files to git
echo "Step 2: Adding subproject source files to root repo..."
git add .
echo ""

# Step 3: Show what's staged
echo "Step 3: Files staged for commit:"
git status --short
echo ""

# Step 4: Restore nested .git directories
echo "Step 4: Restoring nested .git directories..."
for project in "${SUBPROJECTS[@]}"; do
    if [ -d "$project/.git.tmp" ]; then
        echo "  - Restoring $project/.git"
        mv "$project/.git.tmp" "$project/.git"
    fi
done
echo ""

echo "=== Sync Complete ==="
echo ""
echo "Next steps:"
echo "  1. Review staged changes: git status"
echo "  2. Commit: git commit -m 'Snapshot: $(date +%Y-%m-%d)'"
echo "  3. Push to GitHub: git push origin main"
echo ""
