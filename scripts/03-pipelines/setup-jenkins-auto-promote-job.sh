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

# Load infrastructure config via lib/infra.sh
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

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
    trap "rm -f '$COOKIE_JAR'" EXIT

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

    local response http_code body
    response=$(curl -sk -X POST \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "Content-Type: application/xml" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -d "$config" \
        -w "\n%{http_code}" \
        "$JENKINS_URL/job/$JOB_NAME/config.xml")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        log_pass "Job '$JOB_NAME' updated successfully"
        log_info "Webhook token: $webhook_token"
        return 0
    else
        log_fail "Failed to update job (HTTP $http_code)"
        echo "$body" | head -10
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
