# JENKINS-22: Remove Dead Credential Cleanup and Container Naming Consistency

**Date:** 2026-02-08
**Ticket:** JENKINS-22 from `docs/plans/2026-02-07-jenkinsfile-review-tickets.md`
**Files:** `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

## Summary

Three changes across all three Jenkinsfiles:

1. Remove dead credential cleanup from `withGitCredentials` finally blocks and `post.always` blocks
2. Standardize container name from `maven` to `pipeline`
3. Scope `withGitCredentials` to use `repoDir` where possible, using a two-phase pattern for files that clone repos

## Change 1: Remove Dead Credential Cleanup

### withGitCredentials (all three Jenkinsfiles)

The `finally` block currently unsets `credential.helper`, `user.name`, and `user.email`. Since Jenkins agents are ephemeral Kubernetes pods destroyed after each build, this cleanup is dead code.

**Before:**
```groovy
try {
    sh """
        ${gitCmd} user.name 'Jenkins CI'
        ${gitCmd} user.email 'jenkins@local'
        ${gitCmd} credential.helper '...'
    """
    body()
} finally {
    sh """
        ${gitCmd} --unset credential.helper || true
        ${gitCmd} --unset user.name || true
        ${gitCmd} --unset user.email || true
    """
}
```

**After:**
```groovy
try {
    sh """
        ${gitCmd} user.name 'Jenkins CI'
        ${gitCmd} user.email 'jenkins@local'
        ${gitCmd} credential.helper '...'
    """
    body()
} finally {
    // No cleanup needed: Jenkins agents are ephemeral Kubernetes pods
    // destroyed after each build. Credentials die with the pod.
}
```

### post.always blocks

**example-app/Jenkinsfile** - Remove `git config --global --unset credential.helper` and `rm -f /tmp/maven-settings.xml`. Keep workspace hygiene (`rm -rf k8s-deployments`, `rm -f .no-changes-*`).

**Jenkinsfile.promote** - Remove `git config --global --unset credential.helper`. Keep `rm -rf k8s-deployments`.

**k8s-deployments/Jenkinsfile** - Already minimal (`echo` only). No changes.

## Change 2: Standardize Container Name to `pipeline`

All three Jenkinsfiles use the same agent image. The container runs git, curl, kubectl, argocd, cue, and maven — `pipeline` is more accurate than `maven`.

| File | Current | After |
|------|---------|-------|
| `example-app/Jenkinsfile` | `name: maven` in pod YAML, `container('maven')` x7 | `name: pipeline`, `container('pipeline')` |
| `k8s-deployments/Jenkinsfile` | Already `pipeline` | No change |
| `Jenkinsfile.promote` | `name: maven` in pod YAML, `container('maven')` x3 | `name: pipeline`, `container('pipeline')` |

## Change 3: Scope repoDir in withGitCredentials

### Problem

By default (no `repoDir`), `withGitCredentials` uses `git config --global`, which writes to `~/.gitconfig`. While harmless in ephemeral pods, scoping credentials to the repo is better practice for a reference implementation.

### Constraint

`git clone` requires the credential helper to exist BEFORE the repo does. You can't set local repo config for a repo that doesn't exist yet. So clone must use global config.

### Solution: Two-phase pattern

For Jenkinsfiles that clone a repo (example-app, Jenkinsfile.promote):

```groovy
withCredentials([...]) {
    // Phase 1: Clone requires global credential helper (repo doesn't exist yet)
    withGitCredentials {
        sh 'git clone "${DEPLOYMENT_REPO}" k8s-deployments'
    }
    // Phase 2: All subsequent operations use repo-scoped config
    withGitCredentials('k8s-deployments') {
        sh '''
            cd k8s-deployments
            git fetch / checkout / commit / push ...
        '''
    }
}
```

Git config precedence (local > global) ensures the repo-scoped config takes effect for all operations inside the cloned repo.

For k8s-deployments/Jenkinsfile (workspace IS the repo, no clone needed):

```groovy
withGitCredentials('.') {
    // operates on the Jenkins SCM checkout workspace
}
```

### Per-file breakdown

| File | Clone step? | Approach |
|------|------------|----------|
| `example-app/Jenkinsfile` | Yes (clones k8s-deployments) | Two-phase: global for clone, `repoDir='k8s-deployments'` for the rest |
| `Jenkinsfile.promote` | Yes (clones k8s-deployments) | Same two-phase pattern |
| `k8s-deployments/Jenkinsfile` | No (Jenkins SCM checkout) | Pass `'.'` as repoDir |

## Acceptance Criteria

- [ ] No credential cleanup code in `finally` blocks or `post.always`
- [ ] All Jenkinsfiles use `container('pipeline')`
- [ ] Pod YAML container name is `pipeline` in all three files
- [ ] `withGitCredentials` callers use `repoDir` where possible (two-phase for clone, `.` for workspace)
- [ ] `withGitCredentials` finally block has explanatory comment about ephemeral pods
