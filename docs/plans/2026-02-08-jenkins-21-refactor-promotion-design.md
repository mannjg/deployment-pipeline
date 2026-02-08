# JENKINS-21: Refactor createPromotionMR into Smaller Functions

**Date:** 2026-02-08
**Status:** Implemented
**File:** `k8s-deployments/Jenkinsfile`
**Depends on:** JENKINS-15, JENKINS-16, JENKINS-17 (all implemented)

## Problem

`createPromotionMR` (lines 287-522) is a ~235-line function performing 5+ distinct operations inline: close stale MRs, extract image tags, promote artifacts, create branch + update config + generate manifests, push + create MR. This is difficult to read, test, and debug.

## Design

Extract into 4 single-responsibility functions. The orchestrator `createPromotionMR` keeps inline target-env routing and coordinates the 4 functions via return values.

### Function Breakdown

#### 1. `closeStalePromotionMRs(String encodedProject, String targetEnv)`
- Queries GitLab for open MRs with `promote-{targetEnv}-*` source branches targeting `targetEnv`
- For each: adds "superseded" comment, closes MR, deletes source branch
- Returns nothing (fire-and-forget cleanup, warnings on failure)
- Needs: `GITLAB_TOKEN`, `GITLAB_URL`, `BUILD_URL` from caller's `withCredentials` scope

#### 2. `extractSourceImageTag(String encodedProject, String sourceEnv)`
- Fetches `env.cue` from source environment branch via GitLab API
- Parses image tag with `jq` + `grep` + `sed`
- Returns the full image string (e.g., `registry/group/example-app:1.0.0-SNAPSHOT-abc123`)
- Needs: `GITLAB_TOKEN`, `GITLAB_URL`

#### 3. `promoteArtifacts(String sourceEnv, String targetEnv, String gitHash)`
- Exports required env vars and runs `promote-artifact.sh`
- Returns new image tag from `/tmp/promoted-image-tag`
- Fails the build on promotion failure
- Needs: `NEXUS_USER`, `NEXUS_PASSWORD`, `GITLAB_TOKEN`, and pipeline env vars

#### 4. `createPromotionBranchAndMR(String sourceEnv, String targetEnv, String imageTag, String newImageTag)`
- Fetches both branches, creates `promote-{env}-{appVersion}-{timestamp}` branch from target
- Runs `promote-app-config.sh` with `--image-override` if `newImageTag` is set
- Runs `generate-manifests.sh`, commits, pushes
- Calls `create-gitlab-mr.sh` to create the MR
- Wrapped in `withGitCredentials` by the caller

### Orchestrator

`createPromotionMR(sourceEnv)` becomes a ~40-line coordinator:
1. Determines target env (inline: `dev→stage`, `stage→prod`, else skip)
2. Sets up `withCredentials` block wrapping all 4 calls
3. Calls functions in sequence, passing return values forward
4. `withGitCredentials` wraps only `createPromotionBranchAndMR`

### Credential Scoping

- `withCredentials([gitlab, nexus])` wraps all 4 function calls
- `withGitCredentials` wraps only `createPromotionBranchAndMR` (only function needing git auth)
- Each function uses its own `withEnv([...])` to scope Groovy variables into shell `'''` blocks

### What Does NOT Change

- The sequence of API calls, git operations, and shell commands
- Error handling behavior (warnings vs failures)
- The `container('pipeline')` wrapper in the orchestrator
- Integration with `promote-artifact.sh`, `promote-app-config.sh`, `generate-manifests.sh`, `create-gitlab-mr.sh`

## Acceptance Criteria

- No function exceeds ~50 lines
- Each function has a clear single responsibility
- Existing behavior is preserved
- Variable scoping is correct (Groovy vs shell, withCredentials vs withEnv)

## Implementation Notes

- All 4 functions are `def` at script level (same scope as existing helpers like `withGitCredentials`)
- Functions called within `withCredentials` closure have access to bound shell vars in `sh` blocks
- `extractSourceImageTag` returns a value via `sh(returnStdout: true)` — orchestrator uses it
- `promoteArtifacts` returns a value via `readFile` — orchestrator uses it
