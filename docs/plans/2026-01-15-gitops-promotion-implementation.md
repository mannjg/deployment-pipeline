# GitOps Promotion Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Separate CI from promotion by creating a dedicated promotion pipeline and updating the validate script to trigger it.

**Architecture:** Jenkins CI pipeline creates only dev MR. A new `promote-environment` Jenkins job handles stage/prod promotions, triggered by the validate script after verifying the previous environment is healthy.

**Tech Stack:** Jenkins Pipeline (Groovy), Bash, GitLab API, kubectl

---

## Task 1: Create Promotion Jenkinsfile

**Files:**
- Create: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Step 1: Create the promotion pipeline file**

```groovy
/**
 * Jenkins Pipeline: Environment Promotion
 *
 * Purpose: Promote an application from one environment to the next
 * Trigger: Manual, API call, or webhook after previous env verified healthy
 *
 * This pipeline creates a merge request to update the target environment
 * with the image currently deployed in the source environment.
 */

pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
        timeout(time: 10, unit: 'MINUTES')
    }

    parameters {
        string(
            name: 'APP_NAME',
            defaultValue: 'example-app',
            description: 'Application name to promote'
        )
        choice(
            name: 'SOURCE_ENV',
            choices: ['dev', 'stage'],
            description: 'Environment to promote FROM'
        )
        choice(
            name: 'TARGET_ENV',
            choices: ['stage', 'prod'],
            description: 'Environment to promote TO'
        )
        string(
            name: 'IMAGE_TAG',
            defaultValue: '',
            description: 'Specific image tag (leave empty to auto-detect from source env)'
        )
    }

    environment {
        // Git configuration
        GIT_AUTHOR_NAME = 'Jenkins CI'
        GIT_AUTHOR_EMAIL = 'jenkins@deployment-pipeline.local'
        GIT_COMMITTER_NAME = 'Jenkins CI'
        GIT_COMMITTER_EMAIL = 'jenkins@deployment-pipeline.local'

        // GitLab configuration (from pipeline-config ConfigMap)
        GITLAB_URL = "${System.getenv('GITLAB_INTERNAL_URL') ?: 'http://gitlab.gitlab.svc.cluster.local'}"
        GITLAB_GROUP = "${System.getenv('GITLAB_GROUP') ?: 'p2c'}"
        DEPLOYMENT_REPO = "${System.getenv('DEPLOYMENTS_REPO_URL') ?: 'http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git'}"

        // External registry for deployment manifests
        DEPLOY_REGISTRY = "${System.getenv('DOCKER_REGISTRY') ?: 'docker.jmann.local'}"
        APP_GROUP = 'example'

        // Credentials
        GITLAB_CREDENTIALS = credentials('gitlab-credentials')
        GITLAB_API_TOKEN = credentials('gitlab-api-token-secret')
    }

    stages {
        stage('Validate Parameters') {
            steps {
                script {
                    echo "=== Environment Promotion ==="
                    echo "Application: ${params.APP_NAME}"
                    echo "Promotion: ${params.SOURCE_ENV} → ${params.TARGET_ENV}"

                    // Validate promotion path
                    def validPromotions = [
                        'dev': 'stage',
                        'stage': 'prod'
                    ]

                    if (validPromotions[params.SOURCE_ENV] != params.TARGET_ENV) {
                        error "Invalid promotion path: ${params.SOURCE_ENV} → ${params.TARGET_ENV}. Valid paths: dev→stage, stage→prod"
                    }

                    echo "✓ Promotion path validated"
                }
            }
        }

        stage('Resolve Image Tag') {
            steps {
                script {
                    if (params.IMAGE_TAG?.trim()) {
                        env.RESOLVED_IMAGE_TAG = params.IMAGE_TAG.trim()
                        echo "Using provided image tag: ${env.RESOLVED_IMAGE_TAG}"
                    } else {
                        // Auto-detect from source environment's deployment
                        echo "Auto-detecting image from ${params.SOURCE_ENV} environment..."

                        def namespaceMap = [
                            'dev': 'dev',
                            'stage': 'stage',
                            'prod': 'prod'
                        ]
                        def namespace = namespaceMap[params.SOURCE_ENV]

                        // Get current image from running deployment
                        def currentImage = sh(
                            script: """
                                kubectl get deployment ${params.APP_NAME} -n ${namespace} \
                                    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo ""
                            """,
                            returnStdout: true
                        ).trim()

                        if (!currentImage) {
                            error "Could not detect image from ${params.SOURCE_ENV} deployment. Is the app deployed?"
                        }

                        // Extract tag from image (format: registry/group/app:tag)
                        env.RESOLVED_IMAGE_TAG = currentImage.split(':').last()
                        env.RESOLVED_FULL_IMAGE = currentImage

                        echo "Detected image: ${currentImage}"
                        echo "Resolved tag: ${env.RESOLVED_IMAGE_TAG}"
                    }

                    // Construct full image reference for deployment
                    if (!env.RESOLVED_FULL_IMAGE) {
                        env.RESOLVED_FULL_IMAGE = "${DEPLOY_REGISTRY}/${APP_GROUP}/${params.APP_NAME}:${env.RESOLVED_IMAGE_TAG}"
                    }

                    echo "Image for promotion: ${env.RESOLVED_FULL_IMAGE}"
                }
            }
        }

        stage('Create Promotion MR') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                      usernameVariable: 'GIT_USERNAME',
                                                      passwordVariable: 'GIT_PASSWORD')]) {
                        try {
                            // Setup git credentials
                            sh '''
                                git config --global user.name "${GIT_AUTHOR_NAME}"
                                git config --global user.email "${GIT_AUTHOR_EMAIL}"
                                git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'
                            '''

                            // Clone and prepare
                            sh """
                                rm -rf k8s-deployments
                                git clone ${DEPLOYMENT_REPO} k8s-deployments
                                cd k8s-deployments

                                # Checkout target environment branch
                                git fetch origin ${params.TARGET_ENV}
                                git checkout ${params.TARGET_ENV}
                                git pull origin ${params.TARGET_ENV}

                                # Create feature branch for this promotion
                                FEATURE_BRANCH="promote-${params.TARGET_ENV}-${RESOLVED_IMAGE_TAG}"
                                git checkout -b "\${FEATURE_BRANCH}"

                                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                echo "Promoting ${params.APP_NAME} from ${params.SOURCE_ENV} to ${params.TARGET_ENV}"
                                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                echo "Image: ${RESOLVED_FULL_IMAGE}"
                                echo ""

                                # Update the image in target environment's env.cue
                                ./scripts/update-app-image.sh ${params.TARGET_ENV} ${params.APP_NAME} "${RESOLVED_FULL_IMAGE}"
                                echo "✓ Updated ${params.APP_NAME} image in env.cue"

                                # Regenerate Kubernetes manifests
                                ./scripts/generate-manifests.sh ${params.TARGET_ENV}
                                echo "✓ Regenerated manifests"

                                # Stage changes
                                git add env.cue manifests/

                                # Commit
                                git commit -m "Promote ${params.APP_NAME} to ${params.TARGET_ENV}: ${RESOLVED_IMAGE_TAG}

Automated promotion from ${params.SOURCE_ENV} environment.

Changes:
- Updated ${params.TARGET_ENV} environment image to ${RESOLVED_IMAGE_TAG}
- Regenerated Kubernetes manifests

Build: ${BUILD_URL}
Image: ${RESOLVED_FULL_IMAGE}
Source environment: ${params.SOURCE_ENV}

Generated manifests from CUE configuration." || echo "No changes to commit"
                            """

                            // Push and create MR
                            sh """
                                cd k8s-deployments
                                FEATURE_BRANCH="promote-${params.TARGET_ENV}-${RESOLVED_IMAGE_TAG}"

                                # Delete remote branch if exists, then push fresh
                                git push origin --delete "\${FEATURE_BRANCH}" 2>/dev/null || echo "Branch does not exist remotely"
                                git push -u origin "\${FEATURE_BRANCH}"

                                # Create MR using GitLab API
                                export GITLAB_TOKEN="${GITLAB_API_TOKEN}"
                                export GITLAB_URL="${GITLAB_URL}"
                                export GITLAB_GROUP="${GITLAB_GROUP}"

                                ./scripts/create-gitlab-mr.sh \\
                                    "\${FEATURE_BRANCH}" \\
                                    "${params.TARGET_ENV}" \\
                                    "Promote ${params.APP_NAME} to ${params.TARGET_ENV}: ${RESOLVED_IMAGE_TAG}" \\
                                    "## Promotion from ${params.SOURCE_ENV}

**Application**: ${params.APP_NAME}
**Image Tag**: ${RESOLVED_IMAGE_TAG}
**Build**: ${BUILD_URL}

### Changes

This merge request promotes the application from ${params.SOURCE_ENV} to ${params.TARGET_ENV}.

**Image**: ${RESOLVED_FULL_IMAGE}

### Deployment

Once merged, ArgoCD will automatically deploy to the ${params.TARGET_ENV} namespace.

---
*Generated by Jenkins Promotion Pipeline*"
                            """

                            echo "✓ Promotion MR created: promote-${params.TARGET_ENV}-${env.RESOLVED_IMAGE_TAG} → ${params.TARGET_ENV}"

                        } finally {
                            sh 'git config --global --unset credential.helper || true'
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            echo """
=======================================================
✓ PROMOTION MR CREATED SUCCESSFULLY
=======================================================
Application: ${params.APP_NAME}
Promotion: ${params.SOURCE_ENV} → ${params.TARGET_ENV}
Image Tag: ${env.RESOLVED_IMAGE_TAG}
=======================================================
"""
        }
        failure {
            echo """
=======================================================
✗ PROMOTION FAILED
=======================================================
Application: ${params.APP_NAME}
Promotion: ${params.SOURCE_ENV} → ${params.TARGET_ENV}
Check logs above for error details
=======================================================
"""
        }
        cleanup {
            sh 'rm -rf k8s-deployments || true'
        }
    }
}
```

**Step 2: Verify the file was created correctly**

Run: `head -20 k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

Expected: Shows the pipeline header and options block.

**Step 3: Commit the new Jenkinsfile**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "feat: add promotion pipeline Jenkinsfile

Separate promotion logic from CI pipeline:
- Takes APP_NAME, SOURCE_ENV, TARGET_ENV, IMAGE_TAG params
- Auto-detects image from source env if not provided
- Creates MR targeting the appropriate environment branch
- Reuses existing helper scripts (update-app-image.sh, etc.)"
```

---

## Task 2: Update infra.env with Promotion Job Config

**Files:**
- Modify: `config/infra.env`

**Step 1: Add promotion job configuration**

Add at the end of the Jenkins section (after line 59):

```bash
# Promotion job
JENKINS_PROMOTE_JOB_NAME="promote-environment"
```

**Step 2: Commit the config change**

```bash
git add config/infra.env
git commit -m "config: add promotion job name to infra.env"
```

---

## Task 3: Modify CI Jenkinsfile to Remove Promotion Stages

**Files:**
- Modify: `example-app/Jenkinsfile`

**Step 1: Remove SKIP_STAGE_PROMOTION parameter (lines 358-362)**

Delete:
```groovy
        booleanParam(
            name: 'SKIP_STAGE_PROMOTION',
            defaultValue: false,
            description: 'Skip creating stage promotion MR'
        )
```

**Step 2: Remove SKIP_PROD_PROMOTION parameter (lines 363-367)**

Delete:
```groovy
        booleanParam(
            name: 'SKIP_PROD_PROMOTION',
            defaultValue: false,
            description: 'Skip creating prod promotion MR'
        )
```

**Step 3: Remove Promote to Stage stage (lines 570-609)**

Delete the entire `stage('Promote to Stage')` block.

**Step 4: Remove Promote to Prod stage (lines 612-655)**

Delete the entire `stage('Promote to Prod')` block.

**Step 5: Remove the promoteEnvironment function (lines 183-282)**

Delete the entire `promoteEnvironment` function definition. (It's now in Jenkinsfile.promote)

**Step 6: Verify the changes**

Run: `grep -n "Promote to Stage\|Promote to Prod\|SKIP_STAGE\|SKIP_PROD\|promoteEnvironment" example-app/Jenkinsfile`

Expected: No matches (all promotion-related code removed).

**Step 7: Commit the CI Jenkinsfile changes**

```bash
git add example-app/Jenkinsfile
git commit -m "refactor: remove promotion stages from CI pipeline

CI pipeline now only creates dev MR. Promotions are handled
by the separate promote-environment job, triggered after
the previous environment is verified healthy.

This follows proper GitOps: promote what's proven, not planned."
```

---

## Task 4: Add Promotion Functions to Validate Script

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Add JENKINS_PROMOTE_JOB_NAME to configuration section (after line 68)**

Add:
```bash
JENKINS_PROMOTE_JOB_NAME="${JENKINS_PROMOTE_JOB_NAME:-promote-environment}"
```

**Step 2: Add trigger_promotion_job function (after verify_mr_image function, ~line 467)**

Add:
```bash
# -----------------------------------------------------------------------------
# Promotion Job
# -----------------------------------------------------------------------------
trigger_promotion_job() {
    local source_env="$1"
    local target_env="$2"

    log_step "Triggering promotion: $source_env → $target_env..."

    # Trigger Jenkins promotion job
    local trigger_url="$JENKINS_URL/job/$JENKINS_PROMOTE_JOB_NAME/buildWithParameters"

    local response=$(curl -sk -X POST -u "$JENKINS_USER:$JENKINS_TOKEN" \
        --data-urlencode "APP_NAME=$APP_REPO_NAME" \
        --data-urlencode "SOURCE_ENV=$source_env" \
        --data-urlencode "TARGET_ENV=$target_env" \
        -w "\n%{http_code}" \
        "$trigger_url" 2>/dev/null)

    local http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" != "201" && "$http_code" != "200" ]]; then
        log_fail "Failed to trigger promotion job (HTTP $http_code)"
        log_info "URL: $trigger_url"
        exit 1
    fi

    log_info "Promotion job triggered"
}

wait_for_promotion_job() {
    log_step "Waiting for promotion job to complete..."

    local timeout="${JENKINS_BUILD_TIMEOUT:-600}"
    local poll_interval=10
    local elapsed=0
    local build_number=""
    local build_url=""

    # Get the last build number before we triggered
    local last_build=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/job/$JENKINS_PROMOTE_JOB_NAME/lastBuild/api/json" 2>/dev/null | jq -r '.number // 0')

    log_info "Waiting for new build (last was #$last_build)..."

    while [[ $elapsed -lt $timeout ]]; do
        local current_build=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/job/$JENKINS_PROMOTE_JOB_NAME/lastBuild/api/json" 2>/dev/null | jq -r '.number // 0')

        if [[ "$current_build" -gt "$last_build" ]]; then
            build_number="$current_build"
            build_url="$JENKINS_URL/job/$JENKINS_PROMOTE_JOB_NAME/$build_number"
            log_info "Build #$build_number started"
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        log_fail "Timeout waiting for promotion build to start"
        exit 1
    fi

    # Wait for build to complete
    while [[ $elapsed -lt $timeout ]]; do
        local build_info=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$build_url/api/json")

        local building=$(echo "$build_info" | jq -r '.building')
        local result=$(echo "$build_info" | jq -r '.result // "null"')

        if [[ "$building" == "false" ]]; then
            local duration=$(echo "$build_info" | jq -r '.duration')
            local duration_sec=$((duration / 1000))

            if [[ "$result" == "SUCCESS" ]]; then
                log_pass "Promotion build #$build_number completed (${duration_sec}s)"
                echo ""
                return 0
            else
                log_fail "Promotion build #$build_number $result"
                echo ""
                echo "--- Build Console (last 50 lines) ---"
                curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
                    "$build_url/consoleText" | tail -50
                echo "--- End Console ---"
                exit 1
            fi
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for promotion build to complete"
    exit 1
}
```

**Step 3: Add generic merge_env_mr function (after merge_dev_mr function)**

Add:
```bash
merge_env_mr() {
    local target_env="$1"
    local branch_prefix="promote-${target_env}"

    log_step "Finding and merging $target_env MR..."

    local deployments_project="${DEPLOYMENTS_REPO_PATH:?DEPLOYMENTS_REPO_PATH not set}"
    local encoded_project=$(echo "$deployments_project" | sed 's/\//%2F/g')

    # Match MR by version
    local branch_pattern="${branch_prefix}-${NEW_VERSION}-"

    local timeout=60
    local poll_interval=5
    local elapsed=0
    local mr_iid=""
    local source_branch=""

    log_info "Looking for MR with branch: ${branch_pattern}*"

    while [[ $elapsed -lt $timeout ]]; do
        local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_env" 2>/dev/null)

        local match=$(echo "$mrs" | jq -r --arg prefix "$branch_pattern" \
            'first(.[] | select(.source_branch | startswith($prefix))) // empty')

        if [[ -n "$match" ]]; then
            mr_iid=$(echo "$match" | jq -r '.iid')
            source_branch=$(echo "$match" | jq -r '.source_branch')
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$mr_iid" ]]; then
        log_fail "No MR found for $target_env promotion"
        log_info "Open MRs targeting $target_env:"
        curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_env" | \
            jq -r '.[] | "  !\(.iid): \(.source_branch)"' 2>/dev/null || echo "  (none)"
        exit 1
    fi

    log_info "Found MR !$mr_iid (branch: $source_branch)"

    # Merge the MR
    log_info "Merging MR !$mr_iid..."
    local merge_result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid/merge" 2>/dev/null)

    local merge_state=$(echo "$merge_result" | jq -r '.state // .message // "unknown"')

    if [[ "$merge_state" == "merged" ]]; then
        log_pass "MR !$mr_iid merged successfully"
        echo ""
    else
        log_fail "Failed to merge MR: $merge_state"
        echo "$merge_result" | jq .
        exit 1
    fi
}
```

**Step 4: Add generic wait_for_env_sync function (after wait_for_argocd_sync)**

Add:
```bash
wait_for_env_sync() {
    local env_name="$1"
    local app_name="${APP_REPO_NAME}-${env_name}"

    log_step "Waiting for ArgoCD sync ($env_name)..."

    local timeout="${ARGOCD_SYNC_TIMEOUT:-300}"
    local poll_interval=15
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local app_status=$(kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)

        local sync_status=$(echo "$app_status" | jq -r '.status.sync.status // "Unknown"')
        local health_status=$(echo "$app_status" | jq -r '.status.health.status // "Unknown"')

        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            log_pass "$app_name synced and healthy (${elapsed}s)"
            echo ""
            return 0
        fi

        log_info "Status: sync=$sync_status health=$health_status (${elapsed}s elapsed)"

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for ArgoCD sync ($env_name)"
    echo ""
    echo "--- ArgoCD Application Status ---"
    kubectl describe application "$app_name" -n "$ARGOCD_NAMESPACE" 2>/dev/null | tail -30
    echo "--- End Status ---"
    exit 1
}
```

**Step 5: Add generic verify_env_deployment function (after verify_deployment)**

Add:
```bash
verify_env_deployment() {
    local env_name="$1"
    local namespace="${env_name}"

    log_step "Verifying deployment ($env_name)..."

    local pod_info=$(kubectl get pods -n "$namespace" -l "$APP_LABEL" -o json 2>/dev/null)
    local pod_count=$(echo "$pod_info" | jq '.items | length')

    if [[ "$pod_count" -eq 0 ]]; then
        log_fail "No pods found with label $APP_LABEL in $namespace"
        exit 1
    fi

    local ready_pods=$(echo "$pod_info" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$ready_pods" -eq 0 ]]; then
        log_fail "No pods in Running state ($env_name)"
        echo ""
        echo "--- Pod Status ---"
        kubectl get pods -n "$namespace" -l "$APP_LABEL"
        echo "--- End ---"
        exit 1
    fi

    local deployed_image=$(echo "$pod_info" | jq -r '.items[0].spec.containers[0].image')

    log_pass "Pod running with image: $deployed_image ($env_name)"
    echo ""
}
```

**Step 6: Update main() to include stage promotion (modify existing main function)**

Replace the main function with:
```bash
main() {
    local start_time=$(date +%s)

    preflight_checks
    bump_version
    commit_and_push
    wait_for_jenkins_build
    merge_dev_mr
    wait_for_argocd_sync
    verify_deployment

    # Stage promotion
    trigger_promotion_job "dev" "stage"
    wait_for_promotion_job
    merge_env_mr "stage"
    wait_for_env_sync "stage"
    verify_env_deployment "stage"

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo "=== VALIDATION PASSED ==="
    echo "Version $NEW_VERSION deployed to dev and stage in ${minutes}m ${seconds}s"
}
```

**Step 7: Commit validate script changes**

```bash
git add validate-pipeline.sh
git commit -m "feat: add stage promotion to validate script

After dev deployment is verified healthy:
1. Trigger promote-environment Jenkins job
2. Wait for promotion build to complete
3. Merge the stage MR
4. Wait for ArgoCD sync
5. Verify stage pod is healthy

Functions are generic (env_name parameter) for future prod support."
```

---

## Task 5: Create Jenkins Job (Manual Step)

**This task requires manual Jenkins UI interaction.**

**Step 1: Access Jenkins**

Open: `http://jenkins.local`

**Step 2: Create new Pipeline job**

1. Click "New Item"
2. Enter name: `promote-environment`
3. Select "Pipeline"
4. Click "OK"

**Step 3: Configure the job**

In the Pipeline section:
- Definition: "Pipeline script from SCM"
- SCM: "Git"
- Repository URL: `http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git`
- Credentials: Select `gitlab-credentials`
- Branch Specifier: `*/main`
- Script Path: `jenkins/pipelines/Jenkinsfile.promote`

**Step 4: Enable "This project is parameterized"**

The parameters are defined in the Jenkinsfile, but Jenkins needs to know it's parameterized.

**Step 5: Save the job**

Click "Save"

**Step 6: Verify job appears**

Run: `curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/job/promote-environment/api/json" | jq '.name'`

Expected: `"promote-environment"`

---

## Task 6: Sync Changes to GitLab

**Step 1: Push all changes to GitHub**

```bash
git push origin main
```

**Step 2: Sync k8s-deployments subtree to GitLab**

```bash
./scripts/sync-to-gitlab.sh
```

**Step 3: Sync example-app subtree to GitLab**

This happens automatically in sync-to-gitlab.sh, but verify:

```bash
GIT_SSL_NO_VERIFY=true git subtree push --prefix=example-app gitlab-app main
```

---

## Task 7: End-to-End Test

**Step 1: Reset demo environment (if needed)**

```bash
./scripts/setup-gitlab-env-branches.sh --reset
```

**Step 2: Run the validation script**

```bash
./validate-pipeline.sh
```

**Expected output:**
```
=== Pipeline Validation ===

[✓] Pre-flight checks passed
[→] Bumping version...
[✓] Committed and pushed to GitLab

[→] Waiting for Jenkins build...
[✓] Build #N completed successfully

[→] Finding and merging dev MR...
[✓] MR !N merged successfully

[→] Waiting for ArgoCD sync...
[✓] example-app-dev synced and healthy

[→] Verifying deployment...
[✓] Pod running with image: ... (dev)

[→] Triggering promotion: dev → stage...
[✓] Promotion job triggered

[→] Waiting for promotion job to complete...
[✓] Promotion build #N completed

[→] Finding and merging stage MR...
[✓] MR !N merged successfully

[→] Waiting for ArgoCD sync (stage)...
[✓] example-app-stage synced and healthy

[→] Verifying deployment (stage)...
[✓] Pod running with image: ... (stage)

=== VALIDATION PASSED ===
Version X.Y.Z deployed to dev and stage in Nm Ns
```

**Step 3: Verify both environments**

```bash
kubectl get pods -n dev -l app=example-app
kubectl get pods -n stage -l app=example-app
```

Both should show running pods with the same image tag.

---

## Summary

| Task | Files | Commits |
|------|-------|---------|
| 1 | Create `Jenkinsfile.promote` | 1 |
| 2 | Update `config/infra.env` | 1 |
| 3 | Modify `example-app/Jenkinsfile` | 1 |
| 4 | Update `validate-pipeline.sh` | 1 |
| 5 | Create Jenkins job | Manual |
| 6 | Sync to GitLab | - |
| 7 | End-to-end test | - |

**Total estimated time:** 30-45 minutes
