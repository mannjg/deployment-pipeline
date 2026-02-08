# JENKINS-21: Refactor createPromotionMR Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor the 235-line `createPromotionMR` function in `k8s-deployments/Jenkinsfile` into 4 focused helper functions plus a slim orchestrator, preserving identical behavior.

**Architecture:** Extract `closeStalePromotionMRs`, `extractSourceImageTag`, `promoteArtifacts`, and `createPromotionBranchAndMR` as top-level `def` functions (same scope as existing helpers like `withGitCredentials`). The orchestrator `createPromotionMR` becomes a ~40-line coordinator that calls them in sequence, passing data via return values.

**Tech Stack:** Jenkins Declarative Pipeline (Groovy), GitLab API, shell scripts

---

### Task 1: Extract `closeStalePromotionMRs`

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (add new function before `createPromotionMR`, ~line 282)

**Step 1: Add the `closeStalePromotionMRs` function**

Insert this function immediately before `createPromotionMR` (before line 282, after the `waitForArgoCDSync` function). This is an exact extraction of lines 317-360 from the current `createPromotionMR`.

```groovy
/**
 * Closes stale open promotion MRs targeting the given environment.
 * New promotions always supersede old ones - prevents orphaned MR accumulation.
 * Requires GITLAB_TOKEN and GITLAB_URL from caller's withCredentials/environment scope.
 * @param encodedProject URL-encoded GitLab project path (e.g., "p2c%2Fk8s-deployments")
 * @param targetEnv Target environment branch (stage or prod)
 */
def closeStalePromotionMRs(String encodedProject, String targetEnv) {
    withEnv([
        "PROMO_ENCODED_PROJECT=${encodedProject}",
        "PROMO_TARGET=${targetEnv}",
        "PROMO_PREFIX=${PROMOTE_BRANCH_PREFIX}"
    ]) {
        sh '''
            STALE_MRS=$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/merge_requests?state=opened&target_branch=${PROMO_TARGET}" \
                2>/dev/null | jq -r --arg prefix "${PROMO_PREFIX}${PROMO_TARGET}-" \
                '[.[] | select(.source_branch | startswith($prefix))] | .[] | "\(.iid) \(.source_branch)"')

            if [ -z "${STALE_MRS}" ]; then
                echo "No stale promotion MRs found for ${PROMO_TARGET}"
            else
                echo "${STALE_MRS}" | while read -r MR_IID MR_BRANCH; do
                    [ -z "${MR_IID}" ] && continue
                    echo "Closing stale promotion MR !${MR_IID} (branch: ${MR_BRANCH})"

                    # Add comment explaining supersession
                    curl -sf -X POST \
                        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                        -H "Content-Type: application/json" \
                        -d "{\"body\":\"Superseded by promotion from build ${BUILD_URL}\"}" \
                        "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/merge_requests/${MR_IID}/notes" \
                        >/dev/null 2>&1 || echo "Warning: Could not add comment to MR !${MR_IID}"

                    # Close the MR
                    curl -sf -X PUT \
                        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                        -H "Content-Type: application/json" \
                        -d '{"state_event":"close"}' \
                        "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/merge_requests/${MR_IID}" \
                        >/dev/null 2>&1 || echo "Warning: Could not close MR !${MR_IID}"

                    # Delete the stale source branch
                    ENCODED_BRANCH=$(echo "${MR_BRANCH}" | sed 's/\//%2F/g')
                    curl -sf -X DELETE \
                        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                        "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/repository/branches/${ENCODED_BRANCH}" \
                        >/dev/null 2>&1 || echo "Warning: Could not delete branch ${MR_BRANCH}"
                done
            fi
        '''
    }
}
```

**Step 2: Verify no syntax errors**

Run: `cd k8s-deployments && groovy -e "new GroovyShell().parse(new File('Jenkinsfile'))" 2>&1 || echo "Groovy not available - visual inspection only"`

If groovy is not installed, visually verify matching braces/quotes. This is expected for Jenkins-only files.

**Step 3: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): extract closeStalePromotionMRs from createPromotionMR (JENKINS-21)"
```

---

### Task 2: Extract `extractSourceImageTag`

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (add new function after `closeStalePromotionMRs`)

**Step 1: Add the `extractSourceImageTag` function**

Insert after `closeStalePromotionMRs`. This extracts lines 363-375 from the current `createPromotionMR`.

```groovy
/**
 * Extracts the current image reference from a source environment's env.cue via GitLab API.
 * Requires GITLAB_TOKEN and GITLAB_URL from caller's withCredentials/environment scope.
 * @param encodedProject URL-encoded GitLab project path
 * @param sourceEnv Source environment branch (dev or stage)
 * @return Full image reference string (e.g., "registry/group/example-app:1.0.0-SNAPSHOT-abc123")
 */
def extractSourceImageTag(String encodedProject, String sourceEnv) {
    return withEnv([
        "PROMO_ENCODED_PROJECT=${encodedProject}",
        "PROMO_SOURCE=${sourceEnv}"
    ]) {
        sh(
            script: '''
                curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                    "${GITLAB_URL}/api/v4/projects/${PROMO_ENCODED_PROJECT}/repository/files/env.cue?ref=${PROMO_SOURCE}" \
                    2>/dev/null | jq -r '.content' | base64 -d | grep 'image:' | sed -E 's/.*image:\\s*"([^"]+)".*/\\1/' | head -1
            ''',
            returnStdout: true
        ).trim()
    }
}
```

**Step 2: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): extract extractSourceImageTag from createPromotionMR (JENKINS-21)"
```

---

### Task 3: Extract `promoteArtifacts`

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (add new function after `extractSourceImageTag`)

**Step 1: Add the `promoteArtifacts` function**

Insert after `extractSourceImageTag`. This extracts lines 397-428 from the current `createPromotionMR`.

```groovy
/**
 * Promotes Maven and Docker artifacts from source to target environment.
 * Runs promote-artifact.sh and returns the new image tag.
 * Requires NEXUS_USER, NEXUS_PASSWORD, GITLAB_TOKEN from caller's withCredentials scope.
 * @param sourceEnv Source environment (dev or stage)
 * @param targetEnv Target environment (stage or prod)
 * @param gitHash Git commit hash extracted from source image tag
 * @return New image tag for the target environment
 */
def promoteArtifacts(String sourceEnv, String targetEnv, String gitHash) {
    // sh """ required: mixes Groovy-interpolated config (${env.*}, ${sourceEnv})
    // with \${}-escaped credentials (NEXUS_USER, NEXUS_PASSWORD, GITLAB_TOKEN)
    def promoteRc = sh(
        script: """
            export NEXUS_USER="\${NEXUS_USER}"
            export NEXUS_PASSWORD="\${NEXUS_PASSWORD}"
            export NEXUS_URL_INTERNAL="${env.NEXUS_URL_INTERNAL}"
            export DOCKER_REGISTRY_EXTERNAL="${env.DOCKER_REGISTRY_EXTERNAL}"
            export CONTAINER_REGISTRY_PATH_PREFIX="${env.CONTAINER_REGISTRY_PATH_PREFIX}"
            export GITLAB_URL_INTERNAL="${env.GITLAB_URL_INTERNAL}"
            export GITLAB_GROUP="${env.GITLAB_GROUP}"
            export GITLAB_TOKEN="\${GITLAB_TOKEN}"
            bash ./scripts/promote-artifact.sh \
                --source-env ${sourceEnv} \
                --target-env ${targetEnv} \
                --app-name example-app \
                --git-hash ${gitHash} \
                2>&1 | tee /tmp/promote.log
        """,
        returnStatus: true
    )

    if (promoteRc != 0) {
        echo "Artifact promotion output:"
        sh "cat /tmp/promote.log || true"
        error "Artifact promotion failed - cannot create promotion MR without valid image tag. If release version already exists in Nexus, bump the version in pom.xml."
    }

    def newImageTag = readFile('/tmp/promoted-image-tag').trim()
    echo "New image tag for ${targetEnv}: ${newImageTag}"
    return newImageTag
}
```

**Step 2: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): extract promoteArtifacts from createPromotionMR (JENKINS-21)"
```

---

### Task 4: Extract `createPromotionBranchAndMR`

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (add new function after `promoteArtifacts`)

**Step 1: Add the `createPromotionBranchAndMR` function**

Insert after `promoteArtifacts`. This extracts lines 434-517 from the current `createPromotionMR`. The caller wraps this in `withGitCredentials`.

```groovy
/**
 * Creates a promotion branch, promotes app config, generates manifests, and creates a GitLab MR.
 * Must be called within withGitCredentials and withCredentials (for GITLAB_TOKEN).
 * @param sourceEnv Source environment (dev or stage)
 * @param targetEnv Target environment (stage or prod)
 * @param imageTag Image tag from source environment (used for branch naming and config promotion)
 * @param newImageTag Promoted image tag (from promoteArtifacts), or empty string to skip image override
 */
def createPromotionBranchAndMR(String sourceEnv, String targetEnv, String imageTag, String newImageTag) {
    sh """
        # Fetch both branches
        git fetch origin ${sourceEnv} ${targetEnv}

        # Create promotion branch from target
        # Branch convention: promote-{env}-{appVersion}-{timestamp}
        # App version extracted from image tag by stripping trailing git hash
        APP_VERSION=\$(echo "${imageTag}" | sed 's/-[a-f0-9]\\{6,\\}\$//')
        TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
        PROMOTION_BRANCH="${PROMOTE_BRANCH_PREFIX}${targetEnv}-\${APP_VERSION}-\${TIMESTAMP}"

        git checkout -B ${targetEnv} origin/${targetEnv}
        git checkout -b "\${PROMOTION_BRANCH}"

        # Promote app config from source to target
        # If we have a promoted image tag, pass it as an override so
        # promote-app-config.sh writes the correct promoted image (e.g., RC)
        # instead of the source image (e.g., SNAPSHOT)
        NEW_IMAGE_TAG="${newImageTag}"
        IMAGE_OVERRIDE_FLAG=""
        if [ -n "\${NEW_IMAGE_TAG}" ]; then
            REGISTRY="\${DOCKER_REGISTRY_EXTERNAL}"
            PATH_PREFIX="\${CONTAINER_REGISTRY_PATH_PREFIX}"
            NEW_IMAGE="\${REGISTRY}/\${PATH_PREFIX}/example-app:\${NEW_IMAGE_TAG}"
            IMAGE_OVERRIDE_FLAG="--image-override example-app=\${NEW_IMAGE}"
            echo "Promoting with image override: \${NEW_IMAGE}"
        fi

        ./scripts/promote-app-config.sh \${IMAGE_OVERRIDE_FLAG} ${sourceEnv} ${targetEnv} || {
            echo "ERROR: App config promotion failed"
            exit 1
        }

        # Regenerate manifests with promoted config
        ./scripts/generate-manifests.sh ${targetEnv} || {
            echo "ERROR: Manifest generation failed"
            exit 1
        }

        # Check if there are any changes to commit
        if git diff --quiet && git diff --cached --quiet; then
            echo "No changes to promote - config already in sync"
            exit 0
        fi

        # Commit changes
        git add -A
        git commit -m "Promote ${sourceEnv} to ${targetEnv}

Automated promotion after successful ${sourceEnv} deployment.

Source: ${sourceEnv}
Target: ${targetEnv}
Build: ${env.BUILD_URL}"

        # Push promotion branch
        git push -u origin "\${PROMOTION_BRANCH}"

        # Create MR using GitLab API
        export GITLAB_URL_INTERNAL="${env.GITLAB_URL}"

        ./scripts/create-gitlab-mr.sh \\
            "\${PROMOTION_BRANCH}" \\
            "${targetEnv}" \\
            "Promote ${sourceEnv} to ${targetEnv}" \\
            "Automated promotion MR after successful ${sourceEnv} deployment.

## What's Promoted
- Container images (CI/CD managed)
- Application environment variables
- ConfigMap data

## What's Preserved
- Namespace: ${targetEnv}
- Replicas, resources, debug flags

---
**Source:** ${sourceEnv}
**Target:** ${targetEnv}
**Jenkins Build:** ${env.BUILD_URL}"

        echo "Created promotion MR: \${PROMOTION_BRANCH} → ${targetEnv}"
    """
}
```

**Step 2: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): extract createPromotionBranchAndMR from createPromotionMR (JENKINS-21)"
```

---

### Task 5: Rewrite `createPromotionMR` as orchestrator

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (replace the existing `createPromotionMR` function body)

**Step 1: Replace `createPromotionMR` with the slim orchestrator**

Replace the entire `createPromotionMR` function (lines 287-522) with:

```groovy
/**
 * Creates a promotion MR to the next environment.
 * Orchestrates: close stale MRs → extract image → promote artifacts → create branch + MR.
 * @param sourceEnv Source environment (dev or stage)
 */
def createPromotionMR(String sourceEnv) {
    container('pipeline') {
        script {
            def targetEnv = sourceEnv == 'dev' ? 'stage' : sourceEnv == 'stage' ? 'prod' : null
            if (!targetEnv) {
                echo "No promotion needed from ${sourceEnv}"
                return
            }

            echo "=== Creating Promotion MR: ${sourceEnv} -> ${targetEnv} ==="

            def projectPath = "${env.GITLAB_GROUP}/k8s-deployments"
            def encodedProject = projectPath.replace('/', '%2F')

            withCredentials([
                usernamePassword(credentialsId: 'gitlab-credentials',
                                usernameVariable: 'GIT_USERNAME',
                                passwordVariable: 'GIT_PASSWORD'),
                string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN'),
                usernamePassword(credentialsId: 'nexus-credentials',
                                usernameVariable: 'NEXUS_USER',
                                passwordVariable: 'NEXUS_PASSWORD')
            ]) {
                closeStalePromotionMRs(encodedProject, targetEnv)

                def sourceImageTag = extractSourceImageTag(encodedProject, sourceEnv)
                def imageTag = sourceImageTag.contains(':') ? sourceImageTag.split(':').last() : sourceImageTag

                def gitHash = sh(
                    script: "echo '${imageTag}' | grep -oE '[a-f0-9]{6,}\$' || echo ''",
                    returnStdout: true
                ).trim()

                if (!gitHash) {
                    echo "WARNING: Could not extract git hash from source image tag: ${sourceImageTag}"
                    echo "Skipping artifact promotion - MR will use existing image version"
                }

                echo "Source image tag: ${imageTag}"
                echo "Git hash: ${gitHash}"

                def newImageTag = ''
                if (gitHash) {
                    newImageTag = promoteArtifacts(sourceEnv, targetEnv, gitHash)
                }

                if (!imageTag) {
                    error "Cannot create promotion MR: no image tag found in ${sourceEnv} env.cue"
                }

                withGitCredentials {
                    createPromotionBranchAndMR(sourceEnv, targetEnv, imageTag, newImageTag)
                }
            }
        }
    }
}
```

**Step 2: Verify the function ordering in the file**

The functions should appear in this order in the file (between `waitForArgoCDSync` and the `pipeline` block):
1. `closeStalePromotionMRs`
2. `extractSourceImageTag`
3. `promoteArtifacts`
4. `createPromotionBranchAndMR`
5. `createPromotionMR` (orchestrator)

**Step 3: Verify no function exceeds ~50 lines**

Count lines in each function. The acceptance criteria is ~50 lines max per function.

**Step 4: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): rewrite createPromotionMR as slim orchestrator (JENKINS-21)"
```

---

### Task 6: Final review and squash commit

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (review only)

**Step 1: Review the complete refactored file**

Read the full Jenkinsfile and verify:
- All 4 helper functions + orchestrator are present
- No duplicate code between helpers and orchestrator
- The old monolithic `createPromotionMR` body is fully replaced
- No references to removed inline code
- The `pipeline` block's `Create Promotion MR` stage still calls `createPromotionMR(env.BRANCH_NAME)` unchanged

**Step 2: Verify line counts**

Count lines for each extracted function:
- `closeStalePromotionMRs`: should be ~45 lines
- `extractSourceImageTag`: should be ~20 lines
- `promoteArtifacts`: should be ~35 lines
- `createPromotionBranchAndMR`: should be ~50 lines (largest)
- `createPromotionMR` orchestrator: should be ~45 lines

**Step 3: Mark design as implemented**

Update `docs/plans/2026-02-08-jenkins-21-refactor-promotion-design.md`:
Change `**Status:** Design approved` to `**Status:** Implemented`

**Step 4: Commit**

```bash
git add docs/plans/2026-02-08-jenkins-21-refactor-promotion-design.md
git commit -m "docs: mark JENKINS-21 design as implemented"
```
