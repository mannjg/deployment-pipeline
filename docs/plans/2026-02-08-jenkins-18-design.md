# JENKINS-18: Skip MR creation when deployToEnvironment has no changes

**Date:** 2026-02-08
**Status:** Design
**Files:** `example-app/Jenkinsfile` (`deployToEnvironment` function)

## Problem

When `deployToEnvironment` rebuilds the same commit (e.g., a pipeline retry), the
image tag hasn't changed. `update-app-image.sh` writes the same value, `git add`
stages nothing, and `git commit || echo "No changes to commit"` silently no-ops.
The function then pushes an empty branch and calls `create-gitlab-mr.sh`, creating
an MR with no diff. The operator sees "MR created successfully" for a no-op.

## Approach

Check for staged changes after `git add` using `git diff --cached --quiet`. This
is the earliest point we can detect "nothing to do" and avoids all unnecessary
downstream work (commit, push, MR creation).

We considered two options:

1. **Check after commit** — compare feature branch HEAD to target branch after
   the commit attempt. Catches the same condition but later in the flow.
2. **Check before commit (chosen)** — check staged changes immediately after
   `git add`. Short-circuits earlier, avoids the unnecessary commit attempt,
   and produces cleaner logs.

Both are functionally equivalent for idempotency detection. If `update-app-image.sh`
produces no diff, there are no staged changes, and there's nothing to commit or MR.
The reverse case (changes staged but branch identical to target) is impossible since
a commit on top of the target branch necessarily differs from it.

## Design

### Marker file for cross-block communication

`deployToEnvironment` uses three separate `sh '''` blocks in the Jenkinsfile:

1. Clone and create feature branch
2. Update config and commit
3. Push and create MR

Shell variables don't persist across separate `sh` invocations in a Jenkinsfile.
To communicate "no changes detected" from block 2 to block 3, we write a marker
file at `${WORKSPACE}/.no-changes-${BUILD_NUMBER}`. The `BUILD_NUMBER` suffix
prevents collisions (though irrelevant with `disableConcurrentBuilds`).

### Changes to block 2 (update & commit)

Replace the `git commit ... || echo "No changes to commit"` pattern with an
explicit staged-changes check:

```bash
# Check if update-app-image.sh and app.cue sync produced any staged changes.
# If the image tag already matches (e.g., rebuild of same commit), git add
# stages nothing. Skip commit/push/MR to avoid creating empty MRs (JENKINS-18).
if git diff --cached --quiet; then
    echo "No changes vs ${DEPLOY_ENV} - image tag already current. Skipping MR creation."
    # Marker file: needed because push/MR runs in a separate sh block
    # and shell variables don't persist across Jenkinsfile sh invocations.
    touch "${WORKSPACE}/.no-changes-${BUILD_NUMBER}"
else
    git commit -m "..."
fi
```

### Changes to block 3 (push & MR)

Add an early exit at the top:

```bash
# Skip push and MR if the update block detected no changes (see JENKINS-18 marker above)
if [ -f "${WORKSPACE}/.no-changes-${BUILD_NUMBER}" ]; then
    echo "Skipping push and MR creation - no changes detected."
    rm -f "${WORKSPACE}/.no-changes-${BUILD_NUMBER}"
    exit 0
fi
```

### Changes to Groovy echo

The success message after the `sh` blocks (currently unconditional) checks for
the marker via `fileExists` and logs the appropriate message:

```groovy
if (fileExists("${env.WORKSPACE}/.no-changes-${env.BUILD_NUMBER}")) {
    echo "[${environment.toUpperCase()}] No changes detected - MR creation skipped"
} else {
    echo "[${environment.toUpperCase()}] MR created successfully: ${branchPrefix}-${env.IMAGE_TAG} -> ${environment}"
}
```

### Cleanup

The marker file is cleaned up in block 3 on the skip path. It is also harmless
if left behind — the agent pod is ephemeral and destroyed after the build.

## Acceptance criteria

- Rebuilding the same commit does not create an empty MR
- Log output clearly states why MR creation was skipped
- Normal flow (with actual changes) is unaffected
