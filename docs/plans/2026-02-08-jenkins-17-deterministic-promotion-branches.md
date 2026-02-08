# JENKINS-17: Deterministic Promotion Branch Names with Stale MR Cleanup

**Date:** 2026-02-08
**Status:** Approved
**Scope:** `k8s-deployments/Jenkinsfile` — `createPromotionMR` function

## Problem

`createPromotionMR` uses `TIMESTAMP=$(date +%Y%m%d-%H%M%S)` for promotion branch names. If a pipeline fails after pushing the branch but before creating the MR, re-running creates a second orphaned branch. Over time, failed retries and superseded promotions accumulate orphaned branches and MRs in GitLab.

## Design Decisions

### Branch Naming: `promote-{targetEnv}-{appVersion}-{timestamp}`

**Convention:** `promote-stage-1.0.0-SNAPSHOT-20260208-143022`

- `appVersion` — extracted from the source image tag by stripping the trailing git hash (e.g., `1.0.0-SNAPSHOT-abc123` → `1.0.0-SNAPSHOT`). Gives operators immediate visibility into what version is being promoted.
- `timestamp` — ensures uniqueness. Required because SNAPSHOT versions can be legitimately re-promoted (same app version, different artifact or config state).

**Why not fully deterministic names (no timestamp)?**

We considered using `promote-{env}-{imageTag}` or `promote-{env}-{appVersion}-{deployHash}` for full idempotency. These approaches break down for SNAPSHOTs: the pipeline allows re-promoting the same SNAPSHOT version (overwriting the previous), so branch existence cannot be used as a "promotion already done" guard. Timestamps ensure the pipeline always moves forward.

**Why include the app version at all?**

Pure timestamps (`promote-stage-20260208-143022`) give operators no context. Including the app version makes MR lists in GitLab immediately scannable — you can see what's being promoted without clicking through.

### Stale MR Cleanup (folded from JENKINS-27 scope)

Before creating a new promotion MR, close any existing open promotion MRs targeting the same environment:

1. Query GitLab for open MRs with source branch matching `promote-{targetEnv}-*` targeting `{targetEnv}`
2. Close each with a comment: "Superseded by promotion from build {BUILD_URL}"
3. Delete the stale source branches (auto-generated, no manual work to preserve)
4. Proceed with creating the new promotion

This replaces the current "skip if exists" behavior (lines 317-336). A new promotion always supersedes old ones — no orphaned MRs accumulate.

### Guard Against Empty Image Tag

If `imageTag` is empty (source env.cue has no parseable image), error early with a clear message rather than producing a malformed branch name.

## Changes

**File:** `k8s-deployments/Jenkinsfile`, `createPromotionMR` function

1. **Lines 412-413** — Replace branch naming:
   ```bash
   # Before
   TIMESTAMP=$(date +%Y%m%d-%H%M%S)
   PROMOTION_BRANCH="promote-${targetEnv}-${TIMESTAMP}"

   # After
   APP_VERSION=$(echo "${imageTag}" | sed 's/-[a-f0-9]\{6,\}$//')
   TIMESTAMP=$(date +%Y%m%d-%H%M%S)
   PROMOTION_BRANCH="promote-${targetEnv}-${APP_VERSION}-${TIMESTAMP}"
   ```

2. **Lines 315-336** — Replace "skip if exists" with stale MR cleanup:
   - Query for all open MRs with source branch `promote-{targetEnv}-*` targeting `{targetEnv}`
   - Close each with a superseded comment
   - Delete stale source branches
   - Continue with promotion

3. **Before line 407** — Add imageTag empty guard:
   ```groovy
   if (!imageTag) {
       error "Cannot create promotion MR: no image tag found in ${sourceEnv} env.cue"
   }
   ```

## Acceptance Criteria

- Branch names follow `promote-{env}-{appVersion}-{timestamp}` convention
- Re-running a failed promotion creates a new branch (no collision) and closes any stale MR from the previous attempt
- Stale open promotion MRs are closed with a comment before creating the new one
- Stale promotion branches are deleted
- Empty image tag causes early failure with clear error message
- Normal promotion flow (with changes) is unaffected
- SNAPSHOT re-promotions work (timestamp ensures uniqueness)
