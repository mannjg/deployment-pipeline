# JENKINS-01: withGitCredentials and validateRequiredEnvVars Helpers

**Date:** 2026-02-07
**Status:** Implemented

## Problem Statement

All three Jenkinsfiles repeat two patterns:
1. **Git credential setup/cleanup** — `git config --global credential.helper '!f() { ... }; f'` with matching `--unset` in finally blocks. Scattered across 5 call sites total.
2. **ConfigMap variable validation** — collect missing env vars into a list, fail with error message. 3 separate implementations with slightly different formatting.

This duplication increases maintenance burden and risk of inconsistent cleanup.

## Solution

Extract two helpers, defined per-file (no shared library):

### `withGitCredentials(String repoDir = null, Closure body)`

Manages git credential.helper, user.name, and user.email lifecycle.

**Scope selection:**
- `repoDir` non-null and non-empty → `git -C ${repoDir} config` (local)
- `repoDir` null or empty → `git config --global`
- `repoDir` provided but directory doesn't exist → `error` (fail fast)

**Setup phase (before body):**
- `credential.helper` → `!f() { printf "username=%s\npassword=%s\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f`
- `user.name` → `Jenkins CI`
- `user.email` → `jenkins@local`

**Cleanup phase (in finally, always runs):**
- Unsets `credential.helper`, `user.name`, `user.email` (all with `|| true`)

**Implementation:**
```groovy
def withGitCredentials(String repoDir = null, Closure body) {
    def gitCmd = 'git config --global'
    if (repoDir?.trim()) {
        if (!fileExists(repoDir)) {
            error "withGitCredentials: repoDir '${repoDir}' does not exist"
        }
        gitCmd = "git -C ${repoDir} config"
    }
    try {
        sh """
            ${gitCmd} user.name 'Jenkins CI'
            ${gitCmd} user.email 'jenkins@local'
            ${gitCmd} credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "\${GIT_USERNAME}" "\${GIT_PASSWORD}"; }; f'
        """
        body()
    } finally {
        sh """
            ${gitCmd} --unset credential.helper || true
            ${gitCmd} --unset user.name || true
            ${gitCmd} --unset user.email || true
        """
    }
}
```

### `validateRequiredEnvVars(List<String> vars)`

Validates that all listed environment variables are set. Fails the build with a clear message listing all missing variables.

**Implementation:**
```groovy
def validateRequiredEnvVars(List<String> vars) {
    def missing = vars.findAll { !env."${it}" }
    if (missing) {
        error "Missing required ConfigMap variables: ${missing.join(', ')}. Check pipeline-config ConfigMap in Jenkins namespace."
    }
}
```

## Call Site Replacements

### example-app/Jenkinsfile

| Location | Before | After |
|----------|--------|-------|
| "Checkout & Setup" stage | 4 individual `if (!env.X)` checks | `validateRequiredEnvVars([...])` |
| `deployToEnvironment()` helper | Inline credential setup + try/finally cleanup | `withGitCredentials { ... }` inside existing `withCredentials` |
| post.always | `git config --global --unset credential.helper` | Stays (safety net) |

### k8s-deployments/Jenkinsfile

| Location | Before | After |
|----------|--------|-------|
| "Initialize" stage | 4 individual `if (!env.X)` checks | `validateRequiredEnvVars([...])` |
| "Prepare Merge Preview" stage | Inline global setup + cleanup | `withGitCredentials` inside existing `withCredentials` |
| "Generate Manifests" stage | Inline global setup + cleanup | `withGitCredentials` inside existing `withCredentials` |
| `createPromotionMR()` helper | Inline global setup + try/finally | `withGitCredentials` inside existing `withCredentials` |
| post.always | `git config --global --unset credential.helper` | Stays (safety net) |

### k8s-deployments/jenkins/pipelines/Jenkinsfile.promote

| Location | Before | After |
|----------|--------|-------|
| "Validate Parameters" stage | 4 individual `if (!env.X)` checks | `validateRequiredEnvVars([...])` |
| "Create Promotion MR" stage | Inline global setup + try/finally | `withGitCredentials` inside existing `withCredentials` |
| post.always | `git config --global --unset credential.helper` | Stays (safety net) |

## Design Decisions

1. **Helpers nest inside `withCredentials`, not replace it.** Jenkins credential injection (`GIT_USERNAME`/`GIT_PASSWORD` env vars) is still needed. `withGitCredentials` consumes those vars to configure git.

2. **User identity included in helper.** `user.name`/`user.email` are always needed alongside `credential.helper`. Consolidating prevents identity leaking between stages.

3. **Separate calls per stage in k8s-deployments.** Each stage keeps its own `withGitCredentials` call. Credentials are scoped to the minimum duration needed.

4. **post.always cleanup retained.** Belt-and-suspenders defense against credential leaks between builds, even though the helper handles cleanup via try/finally.

5. **Per-file duplication is intentional.** These repos are separate in GitLab. No shared library exists. Identical helper implementations in all three files.

## What Does NOT Change

- `withCredentials` blocks (Jenkins credential injection)
- Stage structure and ordering
- Business logic validations (IMAGE_TAG format, promotion paths, MR queries)
- post.always cleanup blocks
- Non-credential git operations
