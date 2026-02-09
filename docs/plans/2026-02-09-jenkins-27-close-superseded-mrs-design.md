# JENKINS-27: Close superseded MRs on new build

**Date:** 2026-02-09
**Files:** `k8s-deployments/scripts/close-superseded-mrs.sh` (new), `example-app/Jenkinsfile`

## Problem

When two commits to `example-app/main` land in quick succession, both builds create MRs to `k8s-deployments/dev` with different image tags (e.g., `update-dev-1.0.0-SNAPSHOT-abc123` and `update-dev-1.0.0-SNAPSHOT-def456`). The operator sees two open MRs and must manually determine which is latest. Stale MRs accumulate.

The k8s-deployments Jenkinsfile already handles this for promotion MRs via `closeStalePromotionMRs` (lines 287-332), but the example-app pipeline has no equivalent.

## Design

Two changes:

### 1. New script: `k8s-deployments/scripts/close-superseded-mrs.sh`

A standalone script following the same patterns as `create-gitlab-mr.sh`: sources `lib/preflight.sh`, validates required env vars, uses `jq` for JSON construction, and operates against the GitLab API.

```
Usage: close-superseded-mrs.sh <target_branch> <branch_prefix> <new_branch>
```

**Arguments:**
- `target_branch` — MR target branch to filter on (e.g., `dev`)
- `branch_prefix` — Source branch prefix to match (e.g., `update-dev`)
- `new_branch` — The new branch being created; excluded from closure (e.g., `update-dev-1.0.0-SNAPSHOT-def456`)

**Environment (same as `create-gitlab-mr.sh`):**
- `GITLAB_TOKEN` — API authentication
- `GITLAB_URL_INTERNAL` — GitLab base URL
- `GITLAB_GROUP` — Project group (e.g., `p2c`)

**Logic:**
1. Query `GET /projects/:id/merge_requests?state=opened&target_branch=<target>`
2. Filter with `jq` where `source_branch` starts with `<prefix>` AND `source_branch != <new_branch>`
3. For each match:
   a. POST comment: "Superseded by `<new_branch>`"
   b. PUT `state_event: close`
   c. DELETE source branch (belt-and-suspenders — `remove_source_branch: true` on the original MR should handle this, but the MR is being closed not merged)
4. Each individual operation is non-fatal (log warning, continue to next MR)

**Exit code:** Always 0. Supersession cleanup is best-effort and must never break the build.

### 2. Jenkinsfile integration: `deployToEnvironment`

Call `close-superseded-mrs.sh` after pushing the new feature branch (line 189) but before calling `create-gitlab-mr.sh` (line 195). At this point:
- The new branch exists on the remote (so the supersession comment references a real branch)
- `GITLAB_TOKEN` and `GITLAB_URL_INTERNAL` are already in scope from the `withCredentials` block
- `DEPLOY_ENV` and `DEPLOY_BRANCH_PREFIX` are already in scope from `withEnv`

The call is inside the existing `sh '''...'''` block that handles push and MR creation, between the `git push` and the `create-gitlab-mr.sh` invocation:

```bash
# Close any open MRs superseded by this build (JENKINS-27)
./scripts/close-superseded-mrs.sh \
    "${DEPLOY_ENV}" \
    "${DEPLOY_BRANCH_PREFIX}" \
    "${FEATURE_BRANCH}"
```

The no-changes early exit (lines 182-185) naturally skips this too, since the entire block exits before reaching the supersession call.

### Why delete the branch explicitly

`create-gitlab-mr.sh` sets `remove_source_branch: true` on MR creation, which tells GitLab to auto-delete the source branch when the MR is **merged**. But we're **closing** the MR, not merging it — GitLab does not auto-delete branches on close. The explicit DELETE prevents orphaned branches.

## Acceptance criteria

- When a new deployment MR is created, any prior open MRs with the same prefix to the same target are closed
- Closed MRs have a comment indicating which branch superseded them
- Stale source branches are deleted
- Already-merged MRs are not affected (query filters `state=opened`)
- Failures in supersession cleanup do not break the build
