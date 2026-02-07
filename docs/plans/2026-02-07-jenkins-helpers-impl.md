# JENKINS-01: withGitCredentials and validateRequiredEnvVars Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace all inline git credential setup/cleanup and env var validation patterns with `withGitCredentials()` and `validateRequiredEnvVars()` helpers across three Jenkinsfiles.

**Architecture:** Two helper functions defined at the top of each Jenkinsfile (before `pipeline {}`). No shared library — helpers are copy-pasted identically into all three files. `withGitCredentials` wraps git config setup/cleanup in try/finally. `validateRequiredEnvVars` collects missing vars and fails with a single error.

**Tech Stack:** Jenkins Declarative Pipeline (Groovy), git config, Jenkins `withCredentials` step, `fileExists` pipeline step.

**Design document:** `docs/plans/2026-02-07-jenkins-helpers-design.md`

---

### Task 1: Add helpers to example-app/Jenkinsfile

**Files:**
- Modify: `example-app/Jenkinsfile:1-8` (add helpers before existing helpers)

**Step 1: Add the two helper functions at the top of the file**

Insert these two functions after line 3 (before the existing `// HELPER FUNCTIONS` section header on line 4), so they appear first in the helpers section:

```groovy
/**
 * Configures git credentials and identity, executes body, then cleans up.
 * Uses local git config when repoDir is provided (preferred), falls back to --global.
 * @param repoDir Optional directory for local git config scope. If null/empty, uses --global.
 * @param body Closure to execute with credentials configured
 */
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

/**
 * Validates that all listed environment variables are set.
 * Fails the build with a clear message listing all missing variables.
 * @param vars List of environment variable names to check
 */
def validateRequiredEnvVars(List<String> vars) {
    def missing = vars.findAll { !env."${it}" }
    if (missing) {
        error "Missing required ConfigMap variables: ${missing.join(', ')}. Check pipeline-config ConfigMap in Jenkins namespace."
    }
}
```

**Step 2: Verify file still has valid Groovy syntax**

Run: `cd /home/jmann/git/mannjg/deployment-pipeline && groovy -e "new GroovyShell().parse(new File('example-app/Jenkinsfile'))" 2>&1 || echo "Groovy not available - skip syntax check"`

If groovy isn't installed, visually confirm the file structure is intact (helpers before pipeline block).

**Step 3: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "feat(jenkins): add withGitCredentials and validateRequiredEnvVars helpers to example-app

JENKINS-01: Define helper functions that will replace inline credential
setup/cleanup and env var validation patterns."
```

---

### Task 2: Replace inline patterns in example-app/Jenkinsfile

**Files:**
- Modify: `example-app/Jenkinsfile`

**Step 1: Replace env var validation in "Checkout & Setup" stage**

Find the block at lines 228-236 (after helpers are added, line numbers will shift — search for the pattern):

```groovy
                        // Validate required environment variables from ConfigMap
                        def missingVars = []
                        if (!env.JENKINS_AGENT_IMAGE) missingVars.add('JENKINS_AGENT_IMAGE')
                        if (!env.GITLAB_URL_INTERNAL) missingVars.add('GITLAB_URL_INTERNAL')
                        if (!env.DEPLOYMENTS_REPO_URL) missingVars.add('DEPLOYMENTS_REPO_URL')
                        if (!env.DOCKER_REGISTRY_EXTERNAL) missingVars.add('DOCKER_REGISTRY_EXTERNAL')

                        if (missingVars.size() > 0) {
                            error "Missing required ConfigMap variables: ${missingVars.join(', ')}. Configure pipeline-config ConfigMap."
                        }
```

Replace with:

```groovy
                        // Validate required environment variables from ConfigMap
                        validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'DEPLOYMENTS_REPO_URL', 'DOCKER_REGISTRY_EXTERNAL'])
```

**Step 2: Replace credential setup/cleanup in `deployToEnvironment()`**

Find the block inside `deployToEnvironment()` (currently lines 21-114). The structure is:

```groovy
            withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                              usernameVariable: 'GIT_USERNAME',
                                              passwordVariable: 'GIT_PASSWORD')]) {
                try {
                    // Setup git credentials (ephemeral, memory-only)
                    sh '''
                        git config --global user.name "Jenkins CI"
                        git config --global user.email "jenkins@local"
                        git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'
                    '''

                    // ... all the git clone/push/MR logic ...

                } finally {
                    // Always cleanup git credentials, even on failure
                    sh 'git config --global --unset credential.helper || true'
                }
            }
```

Replace with:

```groovy
            withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                              usernameVariable: 'GIT_USERNAME',
                                              passwordVariable: 'GIT_PASSWORD')]) {
                withGitCredentials {
                    // ... all the git clone/push/MR logic stays exactly as-is ...
                }
            }
```

Specifically:
1. Remove the `try {` and the 3-line `sh '''...'''` credential setup block (lines 24-30)
2. Replace `try {` with `withGitCredentials {`
3. Remove the `} finally {` block and its `sh 'git config --global --unset credential.helper || true'` (lines 111-114)
4. The closing `}` of `withGitCredentials` replaces the closing `}` of the old try block

The body (lines 32-109) stays completely unchanged.

**Step 3: Verify post.always cleanup block is untouched**

Confirm these lines still exist in the `post { always { ... } }` section:

```groovy
                        git config --global --unset credential.helper || true
```

This stays as a safety net. Do not modify it.

**Step 4: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "refactor(jenkins): replace inline patterns with helper calls in example-app

JENKINS-01: Replace credential setup/cleanup with withGitCredentials()
and env var checks with validateRequiredEnvVars(). No behavioral change."
```

---

### Task 3: Add helpers to k8s-deployments/Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile:1-12` (add helpers before existing helpers)

**Step 1: Add the two helper functions at the top of the file**

Insert the same two helper functions (`withGitCredentials` and `validateRequiredEnvVars`) after the file header comment (line 9) and before the existing `// HELPER FUNCTIONS` section header (line 12). Use the exact same implementations as Task 1.

**Step 2: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "feat(jenkins): add withGitCredentials and validateRequiredEnvVars helpers to k8s-deployments

JENKINS-01: Define helper functions that will replace inline credential
setup/cleanup and env var validation patterns."
```

---

### Task 4: Replace inline patterns in k8s-deployments/Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile`

There are 4 replacement sites. Handle them in order.

**Step 1: Replace env var validation in "Initialize" stage**

Find the block (currently lines 565-574):

```groovy
                        // Validate required environment variables from ConfigMap
                        def missingVars = []
                        if (!env.JENKINS_AGENT_IMAGE) missingVars.add('JENKINS_AGENT_IMAGE')
                        if (!env.GITLAB_URL_INTERNAL) missingVars.add('GITLAB_URL_INTERNAL')
                        if (!env.DOCKER_REGISTRY_EXTERNAL) missingVars.add('DOCKER_REGISTRY_EXTERNAL')
                        if (!env.CONTAINER_REGISTRY_PATH_PREFIX) missingVars.add('CONTAINER_REGISTRY_PATH_PREFIX')

                        if (missingVars.size() > 0) {
                            error "Missing required ConfigMap variables: ${missingVars.join(', ')}. Configure pipeline-config ConfigMap."
                        }
```

Replace with:

```groovy
                        // Validate required environment variables from ConfigMap
                        validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'DOCKER_REGISTRY_EXTERNAL', 'CONTAINER_REGISTRY_PATH_PREFIX'])
```

**Step 2: Replace credential setup/cleanup in "Prepare Merge Preview" stage**

Find the block (currently lines 659-669):

```groovy
                        withCredentials([
                            usernamePassword(credentialsId: 'gitlab-credentials',
                                            usernameVariable: 'GIT_USERNAME',
                                            passwordVariable: 'GIT_PASSWORD')
                        ]) {
                            sh 'git config --global credential.helper \'!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f\''
                            if (!mergeTargetBranchForPreview(env.MR_TARGET_ENV, isPromoteBranch)) {
                                error "Could not merge ${env.MR_TARGET_ENV} - cannot proceed"
                            }
                            sh 'git config --global --unset credential.helper || true'
                        }
```

Replace with:

```groovy
                        withCredentials([
                            usernamePassword(credentialsId: 'gitlab-credentials',
                                            usernameVariable: 'GIT_USERNAME',
                                            passwordVariable: 'GIT_PASSWORD')
                        ]) {
                            withGitCredentials {
                                if (!mergeTargetBranchForPreview(env.MR_TARGET_ENV, isPromoteBranch)) {
                                    error "Could not merge ${env.MR_TARGET_ENV} - cannot proceed"
                                }
                            }
                        }
```

**Important note on `mergeTargetBranchForPreview()`:** This function (lines 110-193) sets `git config user.name` and `git config user.email` **locally** (without `--global`) at lines 117-118. This is fine — the helper sets them globally (or scoped), and the function overrides them locally within the workspace. No conflict.

**Step 3: Replace credential setup/cleanup in "Generate Manifests" stage**

Find the block (currently lines 726-755):

```groovy
                        withCredentials([
                            usernamePassword(credentialsId: 'gitlab-credentials',
                                            usernameVariable: 'GIT_USERNAME',
                                            passwordVariable: 'GIT_PASSWORD')
                        ]) {
                            sh '''
                                git config --global user.name "Jenkins CI"
                                git config --global user.email "jenkins@local"
                                git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'
                            '''

                            sh """
                                git add manifests/ 2>/dev/null || true
                                ...
                                git config --global --unset credential.helper || true
                            """
                        }
```

Replace with:

```groovy
                        withCredentials([
                            usernamePassword(credentialsId: 'gitlab-credentials',
                                            usernameVariable: 'GIT_USERNAME',
                                            passwordVariable: 'GIT_PASSWORD')
                        ]) {
                            withGitCredentials {
                                sh """
                                    git add manifests/ 2>/dev/null || true

                                    if git diff --cached --quiet manifests/ 2>/dev/null && \
                                       [ -z "\$(git status --porcelain manifests/ 2>/dev/null)" ]; then
                                        echo "No manifest changes to commit"
                                    else
                                        echo "Committing generated manifests..."
                                        git add manifests/
                                        git commit -m "chore: regenerate manifests [jenkins-ci]

Generated by Jenkins CI.
Build: ${env.BUILD_URL}"
                                        git push origin HEAD:\${GIT_BRANCH#origin/}
                                        echo "Manifests committed and pushed"
                                    fi
                                """
                            }
                        }
```

Key changes:
1. Remove the 3-line `sh '''...'''` credential setup block
2. Remove the `git config --global --unset credential.helper || true` line from inside the `sh """` block
3. Wrap the remaining `sh """..."""` in `withGitCredentials { ... }`

**Step 4: Replace credential setup/cleanup in `createPromotionMR()` helper**

Find the block (currently lines 383-476):

```groovy
                sh '''
                    git config --global user.name "Jenkins CI"
                    git config --global user.email "jenkins@local"
                    git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'
                '''

                sh """
                    # Fetch both branches
                    ...
                """

                sh 'git config --global --unset credential.helper || true'
```

Replace with:

```groovy
                withGitCredentials {
                    sh """
                        # Fetch both branches
                        ...
                    """
                }
```

Specifically:
1. Remove the 3-line `sh '''...'''` credential setup block (lines 383-387)
2. Wrap the `sh """..."""` block (lines 389-474) in `withGitCredentials { ... }`
3. Remove the cleanup line `sh 'git config --global --unset credential.helper || true'` (line 476)

**Step 5: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): replace inline patterns with helper calls in k8s-deployments

JENKINS-01: Replace 3 credential setup/cleanup sites with
withGitCredentials() and env var checks with validateRequiredEnvVars().
No behavioral change."
```

---

### Task 5: Add helpers and replace patterns in Jenkinsfile.promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Step 1: Add the two helper functions at the top of the file**

Insert the same two helper functions after the file header comment (line 16) and before the `// Agent image from environment` line (line 18). Use the exact same implementations as Task 1.

**Step 2: Replace env var validation in "Validate Parameters" stage**

Find the block (currently lines 101-113):

```groovy
                        // Validate required environment variables
                        if (!env.GITLAB_URL) {
                            error "GITLAB_URL_INTERNAL not set. Configure pipeline-config ConfigMap."
                        }
                        if (!env.GITLAB_GROUP) {
                            error "GITLAB_GROUP not set. Configure pipeline-config ConfigMap."
                        }
                        if (!env.DEPLOYMENT_REPO) {
                            error "DEPLOYMENTS_REPO_URL not set. Configure pipeline-config ConfigMap."
                        }
                        if (!env.DEPLOY_REGISTRY) {
                            error "DOCKER_REGISTRY_EXTERNAL not set. Configure pipeline-config ConfigMap."
                        }
```

Replace with:

```groovy
                        // Validate required environment variables
                        validateRequiredEnvVars(['GITLAB_URL', 'GITLAB_GROUP', 'DEPLOYMENT_REPO', 'DEPLOY_REGISTRY'])
```

Note: This file validates the *derived* env var names (set in the `environment {}` block), not the raw ConfigMap names. This is correct — the helper doesn't care about the source, just whether the var is set.

**Step 3: Replace credential setup/cleanup in "Create Promotion MR" stage**

Find the block (currently lines 197-315):

```groovy
                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USERNAME',
                                                          passwordVariable: 'GIT_PASSWORD')]) {
                            try {
                                // Setup git credentials (ephemeral, memory-only)
                                sh '''
                                    git config --global user.name "Jenkins CI"
                                    git config --global user.email "jenkins@local"
                                    git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'
                                '''

                                // ... all the clone/update/push/MR logic ...

                            } finally {
                                // Always cleanup git credentials, even on failure
                                sh 'git config --global --unset credential.helper || true'
                            }
                        }
```

Replace with:

```groovy
                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USERNAME',
                                                          passwordVariable: 'GIT_PASSWORD')]) {
                            withGitCredentials {
                                // ... all the clone/update/push/MR logic stays exactly as-is ...
                            }
                        }
```

Specifically:
1. Replace `try {` with `withGitCredentials {`
2. Remove the 3-line `sh '''...'''` credential setup block (lines 202-206)
3. Remove the `} finally { ... }` block (lines 311-314)
4. The body (lines 208-309) stays completely unchanged

**Step 4: Verify post.always cleanup block is untouched**

Confirm these lines still exist in the `post { always { ... } }` section:

```groovy
                        git config --global --unset credential.helper || true
```

**Step 5: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "refactor(jenkins): replace inline patterns with helper calls in Jenkinsfile.promote

JENKINS-01: Replace credential setup/cleanup with withGitCredentials()
and env var checks with validateRequiredEnvVars(). No behavioral change."
```

---

### Task 6: Final review and squash commit

**Step 1: Review all three files for consistency**

Read all three Jenkinsfiles and verify:
1. Both helpers are defined identically in all three files (same implementation, same Javadoc)
2. No remaining inline `git config --global credential.helper` setup blocks (only post.always safety nets remain)
3. No remaining inline `if (!env.X) missingVars.add(...)` patterns
4. All `withGitCredentials` calls are nested inside `withCredentials` blocks
5. post.always cleanup blocks are unchanged in all files

**Step 2: Verify no behavioral change**

Check that:
- The same env vars are validated in each file (list contents unchanged)
- The same credential IDs are used (`gitlab-credentials`)
- The same git user identity is set (`Jenkins CI` / `jenkins@local`)
- All business logic (clone, push, MR creation, etc.) is untouched

**Step 3: Update design document status**

Change status from "Draft" to "Implemented" in `docs/plans/2026-02-07-jenkins-helpers-design.md`.

**Step 4: Commit design status update**

```bash
git add docs/plans/2026-02-07-jenkins-helpers-design.md
git commit -m "docs: mark JENKINS-01 design as implemented"
```
