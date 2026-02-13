#!/usr/bin/env bash
# Setup Jenkins promote-environment job
#
# Creates the promote-environment pipeline job in Jenkins via the REST API.
# This job handles promotions between environments (dev→stage, stage→prod).
#
# Usage: ./scripts/setup-jenkins-promote-job.sh
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
JOB_NAME="${JENKINS_PROMOTE_JOB_NAME:-promote-environment}"

# GitLab repo URL (internal, for Jenkins to access)
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

    # Create cookie jar for session
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
        log_info "Response: $crumb_response"
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
    cat <<'EOF'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Promotes applications between environments (dev→stage, stage→prod).

This job creates a GitLab merge request to update the target environment
with the image currently deployed in the source environment.

Parameters:
- APP_NAME: Application to promote (default: example-app)
- SOURCE_ENV: Environment to promote from (dev or stage)
- TARGET_ENV: Environment to promote to (stage or prod)
- IMAGE_TAG: Optional specific image tag (auto-detects if empty)

Triggered by: validate-pipeline.sh, manual, or webhook after deployment verification.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>APP_NAME</name>
          <description>Application name to promote</description>
          <defaultValue>example-app</defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>SOURCE_ENV</name>
          <description>Environment to promote FROM</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>dev</string>
              <string>stage</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>TARGET_ENV</name>
          <description>Environment to promote TO</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>stage</string>
              <string>prod</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>IMAGE_TAG</name>
          <description>Specific image tag (leave empty to auto-detect from source env)</description>
          <defaultValue></defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
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
    <scriptPath>jenkins/pipelines/Jenkinsfile.promote</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF
}

# -----------------------------------------------------------------------------
# Create Job
# -----------------------------------------------------------------------------
create_job() {
    log_step "Creating Jenkins job: $JOB_NAME..."

    # Generate config with actual repo URL
    local config
    config=$(create_job_config | sed "s|GITLAB_REPO_URL_PLACEHOLDER|$GITLAB_REPO_URL|g")

    local response
    response=$(curl -sk -X POST \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "Content-Type: application/xml" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -d "$config" \
        -w "\n%{http_code}" \
        "$JENKINS_URL/createItem?name=$JOB_NAME")

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        log_pass "Job '$JOB_NAME' created successfully"
        return 0
    elif [[ "$http_code" == "400" && "$body" == *"already exists"* ]]; then
        log_info "Job '$JOB_NAME' already exists"
        return 0
    else
        log_fail "Failed to create job (HTTP $http_code)"
        echo "$body" | head -20
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Update Job (if exists)
# -----------------------------------------------------------------------------
update_job() {
    log_step "Updating Jenkins job: $JOB_NAME..."

    # Generate config with actual repo URL
    local config
    config=$(create_job_config | sed "s|GITLAB_REPO_URL_PLACEHOLDER|$GITLAB_REPO_URL|g")

    local response
    response=$(curl -sk -X POST \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "Content-Type: application/xml" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -d "$config" \
        -w "\n%{http_code}" \
        "$JENKINS_URL/job/$JOB_NAME/config.xml")

    local http_code
    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" ]]; then
        log_pass "Job '$JOB_NAME' updated successfully"
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
    echo "=== Setup Jenkins Promote Job ==="
    echo ""

    load_credentials
    get_crumb

    if job_exists; then
        log_info "Job '$JOB_NAME' already exists"
        read -p "Update existing job? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            update_job
        else
            log_info "Skipping update"
        fi
    else
        create_job
    fi

    echo ""
    log_pass "Jenkins promote job setup complete"
    log_info "Job URL: $JENKINS_URL/job/$JOB_NAME"
}

main "$@"
