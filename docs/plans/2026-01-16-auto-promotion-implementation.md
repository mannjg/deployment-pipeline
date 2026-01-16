# Auto-Promotion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement event-driven environment promotion where merging to dev/stage branches automatically creates promotion MRs.

**Architecture:** GitLab webhook triggers Jenkins `k8s-deployments-auto-promote` job on push to dev/stage branches. Job detects changed apps and triggers existing `promote-environment` job for each.

**Tech Stack:** Jenkins Pipeline (Groovy), Bash scripts, GitLab API, Jenkins REST API

**Design Doc:** `docs/plans/2026-01-16-auto-promotion-design.md`

---

## Task 1: Add Job Name to infra.env

**Files:**
- Modify: `config/infra.env`

**Step 1: Add the auto-promote job name variable**

Add after line 62 (JENKINS_PROMOTE_JOB_NAME):

```bash
JENKINS_AUTO_PROMOTE_JOB_NAME="k8s-deployments-auto-promote"
```

**Step 2: Verify syntax**

Run: `bash -n config/infra.env && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add config/infra.env
git commit -m "config: add JENKINS_AUTO_PROMOTE_JOB_NAME to infra.env"
```

---

## Task 2: Create Jenkinsfile.auto-promote

**Files:**
- Create: `k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote`

**Step 1: Create the Jenkinsfile**

```groovy
/**
 * Jenkins Pipeline: Auto-Promote on Merge
 *
 * Triggered by GitLab webhook on push to dev or stage branches.
 * Detects which apps changed and triggers promote-environment job for each.
 *
 * Flow:
 *   - Push to dev → creates stage MR(s)
 *   - Push to stage → creates prod MR(s)
 *   - Push to prod → no action
 */

def agentImage = System.getenv('JENKINS_AGENT_IMAGE')
if (!agentImage) {
    error "JENKINS_AGENT_IMAGE not set in pipeline-config ConfigMap."
}

def promotionPaths = [
    'dev': 'stage',
    'stage': 'prod'
]

pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: maven
    image: ${agentImage}
    command: [cat]
    tty: true
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
      limits:
        memory: "512Mi"
        cpu: "500m"
"""
        }
    }

    options {
        timeout(time: 10, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '14'))
    }

    environment {
        GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')
        DEPLOYMENT_REPO = System.getenv('DEPLOYMENTS_REPO_URL')
        GITLAB_CREDENTIALS = credentials('gitlab-credentials')
    }

    stages {
        stage('Determine Branch') {
            steps {
                container('maven') {
                    script {
                        // Webhook provides branch via environment or we detect it
                        def sourceBranch = env.gitlabBranch ?:
                                           env.GIT_BRANCH?.replace('origin/', '') ?:
                                           sh(script: "git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ''", returnStdout: true).trim()

                        if (!sourceBranch || sourceBranch == 'HEAD') {
                            echo "Could not determine branch. Skipping."
                            currentBuild.result = 'NOT_BUILT'
                            return
                        }

                        env.SOURCE_ENV = sourceBranch
                        env.TARGET_ENV = promotionPaths[sourceBranch] ?: ''

                        if (!env.TARGET_ENV) {
                            echo "Branch '${sourceBranch}' has no promotion target. Skipping."
                            currentBuild.result = 'NOT_BUILT'
                            currentBuild.description = "No promotion for ${sourceBranch}"
                            return
                        }

                        echo "Auto-promotion: ${env.SOURCE_ENV} → ${env.TARGET_ENV}"
                        currentBuild.description = "${env.SOURCE_ENV} → ${env.TARGET_ENV}"
                    }
                }
            }
        }

        stage('Detect Changed Apps') {
            when {
                expression { env.TARGET_ENV?.trim() }
            }
            steps {
                container('maven') {
                    script {
                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USER',
                                                          passwordVariable: 'GIT_PASS')]) {
                            sh '''
                                git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USER}" "${GIT_PASS}"; }; f'
                                rm -rf k8s-deployments-check
                                git clone --depth 10 ${DEPLOYMENT_REPO} k8s-deployments-check
                                cd k8s-deployments-check && git checkout ${SOURCE_ENV}
                            '''

                            def changedApps = sh(
                                script: '''
                                    cd k8s-deployments-check
                                    git diff --name-only HEAD~1 HEAD -- manifests/ 2>/dev/null | \
                                        grep -oP 'manifests/\\K[^/]+' | sort -u || echo ""
                                ''',
                                returnStdout: true
                            ).trim()

                            sh 'git config --global --unset credential.helper || true'

                            if (!changedApps) {
                                echo "No app manifests changed. Skipping."
                                currentBuild.result = 'NOT_BUILT'
                                currentBuild.description = "${env.SOURCE_ENV} → ${env.TARGET_ENV} (no changes)"
                                return
                            }

                            env.APPS_TO_PROMOTE = changedApps.split('\n').findAll { it.trim() }.join(',')
                            echo "Apps to promote: ${env.APPS_TO_PROMOTE}"
                        }
                    }
                }
            }
        }

        stage('Trigger Promotions') {
            when {
                expression { env.TARGET_ENV?.trim() && env.APPS_TO_PROMOTE?.trim() }
            }
            steps {
                container('maven') {
                    script {
                        def apps = env.APPS_TO_PROMOTE.split(',')
                        def triggered = []

                        apps.each { appName ->
                            appName = appName.trim()
                            if (!appName) return

                            echo "Triggering promotion: ${appName} ${env.SOURCE_ENV} → ${env.TARGET_ENV}"
                            try {
                                build job: 'promote-environment',
                                      parameters: [
                                          string(name: 'APP_NAME', value: appName),
                                          string(name: 'SOURCE_ENV', value: env.SOURCE_ENV),
                                          string(name: 'TARGET_ENV', value: env.TARGET_ENV),
                                          string(name: 'IMAGE_TAG', value: '')
                                      ],
                                      wait: false,
                                      propagate: false
                                triggered.add(appName)
                            } catch (Exception e) {
                                echo "Warning: Failed to trigger for ${appName}: ${e.message}"
                            }
                        }

                        if (triggered) {
                            currentBuild.description = "${env.SOURCE_ENV} → ${env.TARGET_ENV}: ${triggered.join(', ')}"
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            container('maven') {
                sh '''
                    git config --global --unset credential.helper || true
                    rm -rf k8s-deployments-check || true
                '''
            }
        }
        success {
            script {
                if (env.APPS_TO_PROMOTE?.trim()) {
                    echo "Promotion jobs triggered for: ${env.APPS_TO_PROMOTE}"
                }
            }
        }
    }
}
```

**Step 2: Validate Groovy syntax**

Run: `cd k8s-deployments && groovy -e "new GroovyShell().parse(new File('jenkins/pipelines/Jenkinsfile.auto-promote'))" 2>&1 || echo "Groovy not installed - skip syntax check"`

**Step 3: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote
git commit -m "feat: add Jenkinsfile.auto-promote for event-driven promotion"
```

---

## Task 3: Create setup-jenkins-auto-promote-job.sh

**Files:**
- Create: `scripts/03-pipelines/setup-jenkins-auto-promote-job.sh`
- Reference: `scripts/03-pipelines/setup-jenkins-promote-job.sh` (copy pattern)

**Step 1: Create the script**

```bash
#!/bin/bash
# Setup Jenkins k8s-deployments-auto-promote job
#
# Creates the auto-promote pipeline job in Jenkins via the REST API.
# This job is triggered by webhook and creates promotion MRs automatically.
#
# Usage: ./scripts/03-pipelines/setup-jenkins-auto-promote-job.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - Jenkins running and accessible
#   - k8s-deployments repo synced to GitLab

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

source "$PROJECT_ROOT/config/infra.env"

JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"
JOB_NAME="${JENKINS_AUTO_PROMOTE_JOB_NAME:-k8s-deployments-auto-promote}"
GITLAB_REPO_URL="${DEPLOYMENTS_REPO_URL:?DEPLOYMENTS_REPO_URL not set}"

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Load Credentials
# -----------------------------------------------------------------------------
load_credentials() {
    log_step "Loading Jenkins credentials from K8s secrets..."

    JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true

    JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$JENKINS_USER" || -z "$JENKINS_TOKEN" ]]; then
        log_fail "Could not load Jenkins credentials from secret $JENKINS_ADMIN_SECRET"
        exit 1
    fi

    log_info "Loaded credentials for user: $JENKINS_USER"
}

# -----------------------------------------------------------------------------
# Get Jenkins CSRF Crumb
# -----------------------------------------------------------------------------
get_crumb() {
    log_step "Getting Jenkins CSRF crumb..."

    COOKIE_JAR=$(mktemp)
    trap "rm -f $COOKIE_JAR" EXIT

    local crumb_response
    crumb_response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -c "$COOKIE_JAR" \
        "$JENKINS_URL/crumbIssuer/api/json" 2>/dev/null)

    CRUMB_FIELD=$(echo "$crumb_response" | jq -r '.crumbRequestField // empty')
    CRUMB_VALUE=$(echo "$crumb_response" | jq -r '.crumb // empty')

    if [[ -z "$CRUMB_FIELD" || -z "$CRUMB_VALUE" ]]; then
        log_fail "Could not get Jenkins CSRF crumb"
        exit 1
    fi

    log_info "Got crumb: $CRUMB_FIELD"
}

# -----------------------------------------------------------------------------
# Check if Job Exists
# -----------------------------------------------------------------------------
job_exists() {
    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/job/$JOB_NAME/api/json")
    [[ "$status_code" == "200" ]]
}

# -----------------------------------------------------------------------------
# Create Job Config XML
# -----------------------------------------------------------------------------
create_job_config() {
    cat <<'JOBXML'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Auto-promote on merge to environment branches.

Triggered by GitLab webhook when MR is merged to dev or stage branch.
Detects which apps changed and triggers promote-environment job for each.

Flow:
- Push to dev → creates stage promotion MR(s)
- Push to stage → creates prod promotion MR(s)
- Push to prod → no action</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <com.dabsquared.gitlabjenkins.GitLabPushTrigger plugin="gitlab-plugin">
          <spec></spec>
          <triggerOnPush>true</triggerOnPush>
          <triggerOnMergeRequest>false</triggerOnMergeRequest>
          <triggerOnPipelineEvent>false</triggerOnPipelineEvent>
          <triggerOnAcceptedMergeRequest>false</triggerOnAcceptedMergeRequest>
          <triggerOnClosedMergeRequest>false</triggerOnClosedMergeRequest>
          <triggerOnApprovedMergeRequest>false</triggerOnApprovedMergeRequest>
          <triggerOpenMergeRequestOnPush>never</triggerOpenMergeRequestOnPush>
          <triggerOnNoteRequest>false</triggerOnNoteRequest>
          <branchFilterType>NameBasedFilter</branchFilterType>
          <includeBranchesSpec>dev,stage</includeBranchesSpec>
          <excludeBranchesSpec></excludeBranchesSpec>
          <secretToken>WEBHOOK_TOKEN_PLACEHOLDER</secretToken>
        </com.dabsquared.gitlabjenkins.GitLabPushTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>GITLAB_REPO_URL_PLACEHOLDER</url>
          <credentialsId>gitlab-credentials</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="empty-list"/>
      <extensions/>
    </scm>
    <scriptPath>jenkins/pipelines/Jenkinsfile.auto-promote</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
JOBXML
}

# -----------------------------------------------------------------------------
# Create or Update Job
# -----------------------------------------------------------------------------
create_job() {
    log_step "Creating Jenkins job: $JOB_NAME..."

    # Generate webhook token (deterministic based on job name for idempotency)
    local webhook_token
    webhook_token=$(echo -n "${JOB_NAME}-webhook" | sha256sum | cut -c1-32)

    local config
    config=$(create_job_config | \
        sed "s|GITLAB_REPO_URL_PLACEHOLDER|$GITLAB_REPO_URL|g" | \
        sed "s|WEBHOOK_TOKEN_PLACEHOLDER|$webhook_token|g")

    local response http_code body
    response=$(curl -sk -X POST \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "Content-Type: application/xml" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -d "$config" \
        -w "\n%{http_code}" \
        "$JENKINS_URL/createItem?name=$JOB_NAME")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        log_pass "Job '$JOB_NAME' created successfully"
        log_info "Webhook token: $webhook_token"
        return 0
    elif [[ "$http_code" == "400" && "$body" == *"already exists"* ]]; then
        log_info "Job already exists, updating..."
        update_job "$webhook_token"
        return $?
    else
        log_fail "Failed to create job (HTTP $http_code)"
        echo "$body" | head -10
        return 1
    fi
}

update_job() {
    local webhook_token="$1"
    log_step "Updating Jenkins job: $JOB_NAME..."

    local config
    config=$(create_job_config | \
        sed "s|GITLAB_REPO_URL_PLACEHOLDER|$GITLAB_REPO_URL|g" | \
        sed "s|WEBHOOK_TOKEN_PLACEHOLDER|$webhook_token|g")

    local response http_code
    response=$(curl -sk -X POST \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "Content-Type: application/xml" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -d "$config" \
        -w "\n%{http_code}" \
        "$JENKINS_URL/job/$JOB_NAME/config.xml")

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" ]]; then
        log_pass "Job '$JOB_NAME' updated successfully"
        log_info "Webhook token: $webhook_token"
        return 0
    else
        log_fail "Failed to update job (HTTP $http_code)"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "=== Setup Jenkins Auto-Promote Job ==="
    echo ""

    load_credentials
    get_crumb
    create_job

    echo ""
    log_pass "Jenkins auto-promote job setup complete"
    log_info "Job URL: $JENKINS_URL/job/$JOB_NAME"
    echo ""
    echo "Next: Run setup-auto-promote-webhook.sh to configure GitLab webhook"
}

main "$@"
```

**Step 2: Make executable**

Run: `chmod +x scripts/03-pipelines/setup-jenkins-auto-promote-job.sh`

**Step 3: Validate syntax**

Run: `bash -n scripts/03-pipelines/setup-jenkins-auto-promote-job.sh && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add scripts/03-pipelines/setup-jenkins-auto-promote-job.sh
git commit -m "feat: add setup-jenkins-auto-promote-job.sh"
```

---

## Task 4: Create setup-auto-promote-webhook.sh

**Files:**
- Create: `scripts/03-pipelines/setup-auto-promote-webhook.sh`
- Reference: `scripts/03-pipelines/ensure-webhook.sh` (adapt pattern)

**Step 1: Create the script**

```bash
#!/bin/bash
# Setup GitLab webhook for k8s-deployments auto-promote
#
# Configures GitLab webhook to trigger Jenkins auto-promote job
# when MRs are merged to dev or stage branches.
#
# Usage: ./scripts/03-pipelines/setup-auto-promote-webhook.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - GitLab running and accessible
#   - Jenkins auto-promote job created

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

source "$PROJECT_ROOT/config/infra.env"

GITLAB_URL="${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set}"
JENKINS_URL_INT="${JENKINS_URL_INTERNAL:?JENKINS_URL_INTERNAL not set}"
JOB_NAME="${JENKINS_AUTO_PROMOTE_JOB_NAME:-k8s-deployments-auto-promote}"
PROJECT_PATH="${DEPLOYMENTS_REPO_PATH:?DEPLOYMENTS_REPO_PATH not set}"

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Load GitLab Token
# -----------------------------------------------------------------------------
load_gitlab_token() {
    log_step "Loading GitLab credentials from K8s secrets..."

    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_fail "Could not load GitLab token"
        exit 1
    fi

    log_info "GitLab token loaded"
}

# -----------------------------------------------------------------------------
# GitLab API Helper
# -----------------------------------------------------------------------------
gitlab_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    curl -sk -X "$method" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        "${GITLAB_URL}/api/v4${endpoint}" \
        "$@"
}

url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

# -----------------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------------
setup_webhook() {
    log_step "Setting up webhook for $PROJECT_PATH..."

    # Generate webhook token (must match Jenkins job config)
    local webhook_token
    webhook_token=$(echo -n "${JOB_NAME}-webhook" | sha256sum | cut -c1-32)

    # Webhook URL uses GitLab plugin endpoint
    local webhook_url="${JENKINS_URL_INT}/project/${JOB_NAME}"

    log_info "Webhook URL: $webhook_url"
    log_info "Token: ${webhook_token:0:8}..."

    local encoded_path
    encoded_path=$(url_encode "$PROJECT_PATH")

    # Get existing webhooks
    local existing_hooks
    existing_hooks=$(gitlab_api GET "/projects/${encoded_path}/hooks")

    if [[ -z "$existing_hooks" ]] || [[ "$existing_hooks" == "null" ]]; then
        log_fail "Could not fetch webhooks (project may not exist)"
        exit 1
    fi

    # Check for existing webhook with this URL
    local existing_id
    existing_id=$(echo "$existing_hooks" | jq -r --arg url "$webhook_url" \
        '.[] | select(.url == $url) | .id' | head -1)

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        log_info "Webhook already exists (id: $existing_id), updating..."

        local update_result
        update_result=$(gitlab_api PUT "/projects/${encoded_path}/hooks/${existing_id}" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"push_events_branch_filter\": \"dev,stage\", \"enable_ssl_verification\": false, \"token\": \"${webhook_token}\"}")

        if echo "$update_result" | jq -e '.id' &>/dev/null; then
            log_pass "Webhook updated successfully"
        else
            log_fail "Failed to update webhook"
            echo "$update_result"
            exit 1
        fi
    else
        log_step "Creating new webhook..."

        local create_result
        create_result=$(gitlab_api POST "/projects/${encoded_path}/hooks" \
            -d "{\"url\": \"${webhook_url}\", \"push_events\": true, \"push_events_branch_filter\": \"dev,stage\", \"enable_ssl_verification\": false, \"token\": \"${webhook_token}\"}")

        if echo "$create_result" | jq -e '.id' &>/dev/null; then
            local new_id
            new_id=$(echo "$create_result" | jq -r '.id')
            log_pass "Webhook created (id: $new_id)"
        else
            log_fail "Failed to create webhook"
            echo "$create_result"
            exit 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "=== Setup Auto-Promote Webhook ==="
    echo ""

    load_gitlab_token

    log_info "GitLab: $GITLAB_URL"
    log_info "Project: $PROJECT_PATH"
    log_info "Jenkins job: $JOB_NAME"
    echo ""

    setup_webhook

    echo ""
    log_pass "Webhook setup complete"
    echo ""
    echo "The webhook will trigger on push to 'dev' and 'stage' branches."
    echo "This happens automatically when MRs are merged to these branches."
}

main "$@"
```

**Step 2: Make executable**

Run: `chmod +x scripts/03-pipelines/setup-auto-promote-webhook.sh`

**Step 3: Validate syntax**

Run: `bash -n scripts/03-pipelines/setup-auto-promote-webhook.sh && echo "Syntax OK"`

Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add scripts/03-pipelines/setup-auto-promote-webhook.sh
git commit -m "feat: add setup-auto-promote-webhook.sh"
```

---

## Task 5: Delete waitForHealthyDeployment.groovy

**Files:**
- Delete: `example-app/vars/waitForHealthyDeployment.groovy`
- Delete: `example-app/vars/` (directory, if empty)
- Delete: `example-app/scripts/` (directory, if empty)

**Step 1: Remove files and empty directories**

Run:
```bash
rm -f example-app/vars/waitForHealthyDeployment.groovy
rmdir example-app/vars 2>/dev/null || true
rmdir example-app/scripts 2>/dev/null || true
```

**Step 2: Verify removal**

Run: `ls -la example-app/vars example-app/scripts 2>&1 | head -5`

Expected: "No such file or directory" for both

**Step 3: Commit**

```bash
git add -A example-app/vars example-app/scripts
git commit -m "chore: remove unused vars/ and scripts/ directories from example-app"
```

---

## Task 6: Update validate-pipeline.sh (if needed)

**Files:**
- Review: `scripts/test/validate-pipeline.sh`

**Step 1: Check if script triggers promote job manually**

Run: `grep -n "trigger_promotion_job\|promote-environment" scripts/test/validate-pipeline.sh | head -10`

**Step 2: Evaluate impact**

The validate-pipeline.sh script manually triggers promotions. With auto-promotion, this may create duplicate MRs. Options:
- Leave as-is (validation script runs in controlled environment)
- Add flag to skip auto-created MRs

**Decision**: Leave as-is for now. The validation script is for testing; duplicate MRs can be closed. Document this in the script header if needed.

**Step 3: Add comment to script header (optional)**

If desired, add note after line 10:
```bash
# Note: With auto-promotion enabled, promotion MRs may be created automatically
# after merging. This script may create additional MRs which can be ignored/closed.
```

**Step 4: Commit (if changes made)**

```bash
git add scripts/test/validate-pipeline.sh
git commit -m "docs: add auto-promotion note to validate-pipeline.sh"
```

---

## Task 7: Commit Documentation Updates

**Files:**
- Already modified: `docs/WORKFLOWS.md`, `docs/ARCHITECTURE.md`, `CLAUDE.md`

**Step 1: Stage documentation changes**

Run: `git status docs/ CLAUDE.md`

**Step 2: Commit**

```bash
git add docs/WORKFLOWS.md docs/ARCHITECTURE.md CLAUDE.md docs/plans/
git commit -m "docs: update documentation for event-driven auto-promotion

- Add multi-app architecture intent to ARCHITECTURE.md
- Document event-driven promotion flow in WORKFLOWS.md
- Update CLAUDE.md promotion section
- Add approved design document"
```

---

## Task 8: Integration Test

**Step 1: Run Jenkins job setup script**

Run: `./scripts/03-pipelines/setup-jenkins-auto-promote-job.sh`

Expected: Job created or updated successfully

**Step 2: Run webhook setup script**

Run: `./scripts/03-pipelines/setup-auto-promote-webhook.sh`

Expected: Webhook created or updated successfully

**Step 3: Verify idempotency - run both again**

Run:
```bash
./scripts/03-pipelines/setup-jenkins-auto-promote-job.sh
./scripts/03-pipelines/setup-auto-promote-webhook.sh
```

Expected: Both complete successfully without errors (updates existing resources)

**Step 4: Sync to GitLab and test (optional full test)**

```bash
git push origin main
./scripts/04-operations/sync-to-gitlab.sh
```

Then trigger a dev MR merge and verify stage MR is auto-created.

---

## Task 9: Final Commit and Summary

**Step 1: Verify all changes committed**

Run: `git status`

Expected: Clean working tree

**Step 2: Create summary commit if any stragglers**

```bash
git add -A
git commit -m "feat: complete event-driven auto-promotion implementation" --allow-empty
```

**Step 3: Push to origin**

Run: `git push origin main`

---

## Summary

| Task | Files | Purpose |
|------|-------|---------|
| 1 | `config/infra.env` | Add job name variable |
| 2 | `k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote` | Pipeline logic |
| 3 | `scripts/03-pipelines/setup-jenkins-auto-promote-job.sh` | Create Jenkins job |
| 4 | `scripts/03-pipelines/setup-auto-promote-webhook.sh` | Configure GitLab webhook |
| 5 | `example-app/vars/`, `example-app/scripts/` | Remove dead code |
| 6 | `scripts/test/validate-pipeline.sh` | Optional documentation |
| 7 | `docs/*`, `CLAUDE.md` | Commit documentation |
| 8 | - | Integration test |
| 9 | - | Final commit |
