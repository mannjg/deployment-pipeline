# JENKINS-22: Remove Dead Credential Cleanup and Container Naming Consistency

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove dead credential cleanup code, standardize container names to `pipeline`, and scope `withGitCredentials` callers to use `repoDir` where possible.

**Architecture:** Three Jenkinsfiles share the same `withGitCredentials` helper and agent image. Changes are mechanical: strip dead code from finally/post.always, rename container references, and restructure clone-containing callers to use two-phase `withGitCredentials` (global for clone, scoped for everything else).

**Tech Stack:** Jenkins Pipeline (Groovy DSL), Kubernetes pod templates

**Design doc:** `docs/plans/2026-02-08-jenkins-22-design.md`

---

### Task 1: Update `withGitCredentials` in all three Jenkinsfiles

**Context:** The `withGitCredentials` function is duplicated identically across all three Jenkinsfiles. The `finally` block unsets `credential.helper`, `user.name`, and `user.email` — dead code because Jenkins agents are ephemeral Kubernetes pods destroyed after each build. Replace the cleanup code with a comment explaining why cleanup isn't needed, keeping the `try/finally` structure.

**Files:**
- Modify: `example-app/Jenkinsfile:25-31`
- Modify: `k8s-deployments/Jenkinsfile:38-43`
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote:44-49`

**Step 1: Update example-app/Jenkinsfile**

Replace lines 25-31 (the `finally` block contents):

```groovy
    } finally {
        // No cleanup needed: Jenkins agents are ephemeral Kubernetes pods
        // destroyed after each build. Credentials die with the pod.
    }
```

This replaces:
```groovy
    } finally {
        sh """
            ${gitCmd} --unset credential.helper || true
            ${gitCmd} --unset user.name || true
            ${gitCmd} --unset user.email || true
        """
    }
```

**Step 2: Update k8s-deployments/Jenkinsfile**

Same change at lines 38-43. Replace the `finally` block contents with the same comment.

**Step 3: Update k8s-deployments/jenkins/pipelines/Jenkinsfile.promote**

Same change at lines 44-49. Replace the `finally` block contents with the same comment.

**Step 4: Commit**

```bash
git add example-app/Jenkinsfile k8s-deployments/Jenkinsfile k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "refactor(jenkins): remove dead credential cleanup from withGitCredentials (JENKINS-22)

Jenkins agents are ephemeral Kubernetes pods destroyed after each build.
The finally block unsetting credential.helper, user.name, and user.email
is dead code. Replaced with explanatory comment."
```

---

### Task 2: Remove dead cleanup from `post.always` blocks

**Context:** Two Jenkinsfiles have `post.always` blocks that unset credentials and remove temp files. These are dead code in ephemeral pods. Remove credential-related cleanup lines but keep workspace hygiene (`rm -rf k8s-deployments`, `rm -f .no-changes-*`).

**Files:**
- Modify: `example-app/Jenkinsfile:527-541` (post.always block)
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote:389-401` (post.always block)

**Step 1: Update example-app/Jenkinsfile post.always**

Replace the `sh '''...'''` block inside `post.always` (lines 531-537). Remove two lines:
- `git config --global --unset credential.helper || true`
- `rm -f /tmp/maven-settings.xml || true`

The block becomes:
```groovy
                    sh '''
                        echo "Performing cleanup..."
                        rm -rf k8s-deployments || true
                        rm -f "${WORKSPACE}"/.no-changes-* || true
                        echo "Cleanup completed"
                    '''
```

Note: also remove the `✓` from "Cleanup completed" for consistency with Jenkinsfile.promote.

**Step 2: Update Jenkinsfile.promote post.always**

Replace the `sh '''...'''` block inside `post.always` (lines 393-397). Remove one line:
- `git config --global --unset credential.helper || true`

The block becomes:
```groovy
                    sh '''
                        echo "Performing cleanup..."
                        rm -rf k8s-deployments || true
                        echo "Cleanup completed"
                    '''
```

**Step 3: Commit**

```bash
git add example-app/Jenkinsfile k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "refactor(jenkins): remove dead post.always credential cleanup (JENKINS-22)

Remove git config --global --unset and rm maven-settings.xml from
post.always blocks. Dead code in ephemeral Kubernetes pods."
```

---

### Task 3: Rename container from `maven` to `pipeline` in example-app/Jenkinsfile

**Context:** The container is named `maven` but runs git, curl, kubectl, argocd, cue, AND maven. The k8s-deployments Jenkinsfile already uses `pipeline`. Standardize across all files.

**Files:**
- Modify: `example-app/Jenkinsfile`

**Step 1: Rename in pod YAML template**

At line 248, change:
```yaml
  - name: maven
```
to:
```yaml
  - name: pipeline
```

**Step 2: Rename all `container('maven')` calls**

There are 8 occurrences in example-app/Jenkinsfile. Change each `container('maven')` to `container('pipeline')`:
- Line 89: in `deployToEnvironment`
- Line 317: in `Checkout & Setup` stage
- Line 365: in `Unit Tests` stage
- Line 384: in `Integration Tests` stage
- Line 400: in `Build & Publish` stage
- Line 505: in `post.success`
- Line 522: in `post.failure`
- Line 528: in `post.always`

Use find-and-replace — the string `container('maven')` is unique to this usage.

**Step 3: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "refactor(jenkins): rename container 'maven' to 'pipeline' in example-app (JENKINS-22)

The container runs git, curl, kubectl, argocd, cue, and maven.
'pipeline' is more accurate and consistent with k8s-deployments."
```

---

### Task 4: Rename container from `maven` to `pipeline` in Jenkinsfile.promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Step 1: Rename in pod YAML template**

At line 81, change:
```yaml
  - name: maven
```
to:
```yaml
  - name: pipeline
```

**Step 2: Rename all `container('maven')` calls**

There are 4 occurrences. Change each to `container('pipeline')`:
- Line 147: in `Validate Parameters` stage
- Line 181: in `Detect Image` stage
- Line 232: in `Create Promotion MR` stage
- Line 390: in `post.always`

**Step 3: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "refactor(jenkins): rename container 'maven' to 'pipeline' in Jenkinsfile.promote (JENKINS-22)

Consistent with k8s-deployments Jenkinsfile and example-app."
```

---

### Task 5: Two-phase `withGitCredentials` in example-app/Jenkinsfile `deployToEnvironment`

**Context:** Currently `withGitCredentials` wraps everything including `git clone`. Since clone needs the credential helper BEFORE the repo exists, it must use global config. But post-clone operations (fetch, checkout, commit, push) can use repo-scoped config. Split into two phases.

**Files:**
- Modify: `example-app/Jenkinsfile:102-206` (the `withCredentials` block inside `deployToEnvironment`)

**Step 1: Restructure to two-phase pattern**

Current structure (lines 102-206):
```groovy
withCredentials([...]) {
    withGitCredentials {
        sh '''  # clone + checkout
        '''
        sh '''  # modify files + commit
        '''
        sh '''  # push + create MR
        '''
        if (fileExists(...)) { ... }
    }
}
```

New structure:
```groovy
withCredentials([...]) {
    // Phase 1: Clone requires global credential helper (repo doesn't exist yet)
    withGitCredentials {
        sh '''
            rm -rf k8s-deployments
            git clone "${DEPLOYMENT_REPO}" k8s-deployments
        '''
    }
    // Phase 2: All subsequent operations use repo-scoped config
    withGitCredentials('k8s-deployments') {
        sh '''
            cd k8s-deployments

            # Fetch and checkout target environment branch
            git fetch origin "${DEPLOY_ENV}"
            git checkout "${DEPLOY_ENV}"
            git pull origin "${DEPLOY_ENV}"

            # Create feature branch for this update
            FEATURE_BRANCH="${DEPLOY_BRANCH_PREFIX}-${IMAGE_TAG}"
            git checkout -b "${FEATURE_BRANCH}"
        '''

        // Update environment configuration (L5 + L6 only, no manifest generation)
        sh '''
            cd k8s-deployments
            ... (unchanged)
        '''

        // Push feature branch and create merge request (skip if no changes - JENKINS-18)
        sh '''
            cd k8s-deployments
            ... (unchanged)
        '''

        if (fileExists("${env.WORKSPACE}/.no-changes-${env.BUILD_NUMBER}")) {
            ... (unchanged)
        }
    }
}
```

The key change: the `git clone` is isolated in a global `withGitCredentials` call, and everything else moves into `withGitCredentials('k8s-deployments')`. The three `sh` blocks after clone and the `if (fileExists(...))` block remain unchanged — only their wrapping changes.

**Step 2: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "refactor(jenkins): scope withGitCredentials to repoDir in deployToEnvironment (JENKINS-22)

Split into two phases: global credential helper for git clone (repo
doesn't exist yet), then repo-scoped config for fetch/commit/push.
Avoids global git config pollution."
```

---

### Task 6: Two-phase `withGitCredentials` in Jenkinsfile.promote `Create Promotion MR` stage

**Context:** Same pattern as Task 5. The `Create Promotion MR` stage clones k8s-deployments inside `withGitCredentials`. Split into clone phase (global) and work phase (repo-scoped).

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote:236-348`

**Step 1: Restructure to two-phase pattern**

Current structure (lines 236-348):
```groovy
withCredentials([...]) {
    withGitCredentials {
        sh """  # clone + checkout
        """
        sh """  # modify + commit
        """
        // mrDescription + writeFile
        withEnv([...]) {
            sh '''  # push + create MR
            '''
        }
        echo "..."
    }
}
```

New structure:
```groovy
withCredentials([...]) {
    // Phase 1: Clone requires global credential helper (repo doesn't exist yet)
    withGitCredentials {
        sh """
            rm -rf k8s-deployments
            git clone ${DEPLOYMENT_REPO} k8s-deployments
        """
    }
    // Phase 2: All subsequent operations use repo-scoped config
    withGitCredentials('k8s-deployments') {
        sh """
            cd k8s-deployments

            # Fetch target environment branch
            git fetch origin ${params.TARGET_ENV}
            git checkout ${params.TARGET_ENV}
            git pull origin ${params.TARGET_ENV}

            # Create feature branch for this promotion
            FEATURE_BRANCH="${PROMOTE_BRANCH_PREFIX}${params.TARGET_ENV}-${PROMOTE_IMAGE_TAG}"
            git checkout -b "\${FEATURE_BRANCH}"

            echo "============================================"
            echo "Promoting ${params.APP_NAME} from ${params.SOURCE_ENV} to ${params.TARGET_ENV}"
            echo "============================================"
            echo "Image: ${PROMOTE_FULL_IMAGE}"
            echo "Feature branch: \${FEATURE_BRANCH}"
            echo ""
        """

        // Update image and generate manifests
        sh """
            cd k8s-deployments
            ... (unchanged)
        """

        // mrDescription + writeFile (unchanged)

        withEnv([...]) {
            sh '''
                cd k8s-deployments
                ... (unchanged)
            '''
        }

        echo "..."
    }
}
```

Same pattern: isolate the clone, move fetch/checkout/commit/push into scoped block.

**Step 2: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "refactor(jenkins): scope withGitCredentials to repoDir in Jenkinsfile.promote (JENKINS-22)

Split into two phases: global credential helper for git clone, then
repo-scoped config for fetch/commit/push."
```

---

### Task 7: Scope `withGitCredentials` to `'.'` in k8s-deployments/Jenkinsfile

**Context:** The k8s-deployments/Jenkinsfile uses Jenkins SCM checkout — the workspace IS the git repo. No clone is needed, so no two-phase split required. Just pass `'.'` as `repoDir` to write config to the workspace's `.git/config` instead of `~/.gitconfig`.

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (3 call sites)

**Step 1: Update line 551** (inside `createPromotionMR`)

Change:
```groovy
                withGitCredentials {
```
to:
```groovy
                withGitCredentials('.') {
```

**Step 2: Update line 750** (inside `Prepare Merge Preview` stage)

Change:
```groovy
                            withGitCredentials {
```
to:
```groovy
                            withGitCredentials('.') {
```

**Step 3: Update line 817** (inside `Generate Manifests` stage)

Change:
```groovy
                            withGitCredentials {
```
to:
```groovy
                            withGitCredentials('.') {
```

**Step 4: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): scope withGitCredentials to workspace repoDir in k8s-deployments (JENKINS-22)

Pass '.' as repoDir so git config writes to .git/config (local)
instead of ~/.gitconfig (global). Workspace is the repo (SCM checkout)."
```

---

### Task 8: Update ticket status

**Files:**
- Modify: `docs/plans/2026-02-07-jenkinsfile-review-tickets.md`

**Step 1: Mark JENKINS-22 as implemented**

Add `**Status: IMPLEMENTED**` under the JENKINS-22 heading, matching the pattern used for other completed tickets.

**Step 2: Commit**

```bash
git add docs/plans/2026-02-07-jenkinsfile-review-tickets.md
git commit -m "docs: mark JENKINS-22 as implemented"
```
