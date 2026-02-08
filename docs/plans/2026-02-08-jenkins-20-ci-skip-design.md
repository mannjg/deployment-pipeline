# JENKINS-20: Prevent manifest push from triggering redundant webhook build

**Date:** 2026-02-08
**Status:** Approved
**Files:** `k8s-deployments/Jenkinsfile`

## Problem

The Generate Manifests stage (line 783) pushes manifests back to feature branches with a `[jenkins-ci]` commit message. This push triggers the GitLab webhook, which triggers another k8s-deployments build. The second build queues (due to `disableConcurrentBuilds`), runs, finds no changes, and exits. Not broken, but wastes resources and confuses operators.

## Design

In the Initialize stage, after setting `ORIGINAL_COMMIT_SHA` but before MR queries, detect `[jenkins-ci]` commits on non-env branches and early-exit with `NOT_BUILT`.

### Change location

`k8s-deployments/Jenkinsfile`, Initialize stage — insert after line 619 (`echo "Commit SHA: ..."`).

### New code

```groovy
// JENKINS-20: Skip redundant builds triggered by manifest push
// The Generate Manifests stage pushes [jenkins-ci] commits back to feature
// branches, which triggers the webhook again. Detect and skip these.
if (env.BRANCH_NAME && !(env.BRANCH_NAME in ENV_BRANCHES)) {
    def lastCommitMsg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
    if (lastCommitMsg.contains('[jenkins-ci]')) {
        currentBuild.result = 'NOT_BUILT'
        currentBuild.description = 'Skipped: CI-generated commit'
        echo "Skipping build: last commit is CI-generated ([jenkins-ci] marker found)"
        return  // exits script block; TARGET_ENV stays empty, all stages skip
    }
}
```

### Why no other changes are needed

- `return` exits the `script` closure — `TARGET_ENV` is never set
- Every subsequent stage gates on `TARGET_ENV != ''`, `IS_ENV_BRANCH`, or `PROMOTE_BRANCHES` — all skip naturally
- `ORIGINAL_COMMIT_SHA` is already set, so the post block can still report status
- Post block reports `success` for NOT_BUILT builds — harmless, no guard needed

### Scope decision

The `[jenkins-ci]` check only runs on non-env branches (option 1 from brainstorm). Environment branches always proceed regardless of commit message. This is safe because:
- `[jenkins-ci]` commits are only pushed to feature branches (Generate Manifests stage)
- Env branches only receive changes via merged MRs (per Environment Branch Modification Invariant)
- Merge commit messages use GitLab's default format, never `[jenkins-ci]`

## Acceptance criteria

- Manifest push commit does not trigger a second build (build shows NOT_BUILT)
- Manual pushes and MR merges still trigger builds normally
- Environment branch builds are never skipped
