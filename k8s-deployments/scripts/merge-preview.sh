#!/usr/bin/env bash
set -euo pipefail

# Merge target environment branch into current branch for MR preview,
# resolving expected conflicts with per-path strategies.
#
# Usage: ./scripts/merge-preview.sh [--promote] <targetEnv>
#
# Conflict resolution strategies:
#   env.cue     - promote: keep ours (promoted image tags)
#               - feature: take theirs (target env config)
#   manifests/  - always keep ours (derivative, will be regenerated)
#   .mr-trigger - always keep ours
#   services/   - always keep ours (feature branch version)
#
# Exit codes:
#   0 - merge successful
#   1 - unresolved conflicts or missing env.cue

IS_PROMOTE=false
if [[ "${1:-}" == "--promote" ]]; then
    IS_PROMOTE=true
    shift
fi

TARGET_ENV="${1:-}"
if [[ -z "$TARGET_ENV" ]]; then
    echo "ERROR: targetEnv argument required" >&2
    echo "Usage: ./scripts/merge-preview.sh [--promote] <targetEnv>" >&2
    exit 1
fi

echo "Merging ${TARGET_ENV} into feature branch for clean MR-preview..."
git fetch origin "${TARGET_ENV}"

# Merge target branch into feature branch
git merge "origin/${TARGET_ENV}" --no-commit --no-edit || true

# --- Resolve env.cue conflicts ---
if git diff --name-only --diff-filter=U | grep -q "^env.cue$"; then
    if [[ "$IS_PROMOTE" == "true" ]]; then
        echo "Resolving env.cue conflict (keeping promote branch version with promoted images)"
        git checkout --ours env.cue
    else
        echo "Resolving env.cue conflict (taking version from ${TARGET_ENV})"
        git show "origin/${TARGET_ENV}:env.cue" > env.cue
    fi
    git add env.cue
fi

# --- Resolve manifests/ conflicts (always keep ours - derivative files) ---
MANIFEST_CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null | grep "^manifests/" || true)
if [[ -n "$MANIFEST_CONFLICTS" ]]; then
    echo "Resolving manifests/ conflicts (keeping current version - derivative files)"
    for file in $MANIFEST_CONFLICTS; do
        git checkout --ours "$file" 2>/dev/null || true
        git add "$file" 2>/dev/null || true
    done
fi

# --- Resolve .mr-trigger conflicts (keep ours) ---
if git diff --name-only --diff-filter=U | grep -q "^\.mr-trigger$"; then
    echo "Resolving .mr-trigger conflict (keeping current version)"
    git checkout --ours .mr-trigger
    git add .mr-trigger
fi

# --- Resolve services/ conflicts (keep ours) ---
SERVICE_CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null | grep "^services/" || true)
if [[ -n "$SERVICE_CONFLICTS" ]]; then
    echo "Resolving services/ conflicts (keeping feature branch version):"
    echo "$SERVICE_CONFLICTS"
    for file in $SERVICE_CONFLICTS; do
        git checkout --ours "$file"
        git add "$file"
    done
fi

# --- Check for remaining unresolved conflicts ---
CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
if [[ -n "$CONFLICTS" ]]; then
    echo "ERROR: Unresolved merge conflicts:" >&2
    echo "$CONFLICTS" >&2
    exit 1
fi

# Commit the merge if there were changes
if ! git diff --staged --quiet; then
    git commit --no-edit -m "Merge ${TARGET_ENV} into feature branch for MR-preview"
fi

echo "Successfully merged ${TARGET_ENV} into feature branch"

# Verify env.cue exists
if [[ ! -f "env.cue" ]]; then
    echo "ERROR: env.cue not found after merge" >&2
    exit 1
fi
