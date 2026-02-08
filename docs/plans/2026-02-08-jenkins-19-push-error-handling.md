# JENKINS-19: Add error handling for git push in Generate Manifests stage

**Date:** 2026-02-08
**Status:** Approved
**Files:** `k8s-deployments/Jenkinsfile`

## Problem

The `git push` in the Generate Manifests stage (line 783) has no explicit error handling. If the push fails (force-push protection, network error, auth failure), the pipeline relies solely on `set -e` — which is notoriously unreliable in certain shell constructs. On failure, the MR would show stale manifests while the pipeline could report success.

## Design

Two edits in the Generate Manifests stage:

### 1. Explicit push error handling

Add `|| { ...; exit 1; }` to the git push command:

```bash
git push origin HEAD:${GIT_BRANCH#origin/} || {
    echo "ERROR: Failed to push generated manifests to feature branch"
    echo "Possible causes: force-push protection, auth failure, network error"
    exit 1
}
```

### 2. Document SHA fallback behavior

Add a comment above `FINAL_COMMIT_SHA` explaining the fallback:

```groovy
// FINAL_COMMIT_SHA is only set after successful push.
// On push failure, the stage fails and post block falls back to
// ORIGINAL_COMMIT_SHA — which correctly reports status against
// the pre-manifest-generation commit.
env.FINAL_COMMIT_SHA = ...
```

## Acceptance Criteria

- Push failure causes stage failure
- GitLab commit status reports against the correct SHA on both success and failure
