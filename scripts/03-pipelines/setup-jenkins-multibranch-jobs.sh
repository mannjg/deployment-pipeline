#!/usr/bin/env bash
# Setup Jenkins MultiBranch Pipeline jobs
#
# Creates MultiBranch Pipeline jobs for example-app and k8s-deployments
# via the Jenkins REST API.
#
# Usage: ./scripts/03-pipelines/setup-jenkins-multibranch-jobs.sh [config-file]
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - Jenkins running and accessible
#   - GitLab repos exist with code pushed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Load infrastructure config via lib/infra.sh
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set}"
GITLAB_URL="${GITLAB_URL_INTERNAL:?GITLAB_URL_INTERNAL not set}"

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
    local job_name="$1"
    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/job/$job_name/api/json")
    [[ "$status_code" == "200" ]]
}

# -----------------------------------------------------------------------------
# Create MultiBranch Pipeline Job Config XML
# -----------------------------------------------------------------------------
create_multibranch_config() {
    local job_name="$1"
    local repo_url="$2"
    local credentials_id="$3"

    cat <<JOBXML
<?xml version='1.1' encoding='UTF-8'?>
<org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject plugin="workflow-multibranch">
  <description>MultiBranch Pipeline for ${job_name}</description>
  <properties>
    <org.jenkinsci.plugins.pipeline.modeldefinition.config.FolderConfig plugin="pipeline-model-definition">
      <dockerLabel></dockerLabel>
      <registry plugin="docker-commons"/>
    </org.jenkinsci.plugins.pipeline.modeldefinition.config.FolderConfig>
  </properties>
  <folderViews class="jenkins.branch.MultiBranchProjectViewHolder" plugin="branch-api">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
  </folderViews>
  <healthMetrics/>
  <icon class="jenkins.branch.MetadataActionFolderIcon" plugin="branch-api">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
  </icon>
  <orphanedItemStrategy class="com.cloudbees.hudson.plugins.folder.computed.DefaultOrphanedItemStrategy" plugin="cloudbees-folder">
    <pruneDeadBranches>true</pruneDeadBranches>
    <daysToKeep>-1</daysToKeep>
    <numToKeep>-1</numToKeep>
    <abortBuilds>false</abortBuilds>
  </orphanedItemStrategy>
  <triggers>
    <com.igalg.jenkins.plugins.mswt.trigger.ComputedFolderWebHookTrigger plugin="multibranch-scan-webhook-trigger">
      <spec></spec>
      <token>${job_name}</token>
    </com.igalg.jenkins.plugins.mswt.trigger.ComputedFolderWebHookTrigger>
  </triggers>
  <disabled>false</disabled>
  <sources class="jenkins.branch.MultiBranchProject\$BranchSourceList" plugin="branch-api">
    <data>
      <jenkins.branch.BranchSource>
        <source class="jenkins.plugins.git.GitSCMSource" plugin="git">
          <id>${job_name}-git-source</id>
          <remote>${repo_url}</remote>
          <credentialsId>${credentials_id}</credentialsId>
          <traits>
            <jenkins.plugins.git.traits.BranchDiscoveryTrait/>
            <jenkins.plugins.git.traits.CloneOptionTrait>
              <extension class="hudson.plugins.git.extensions.impl.CloneOption">
                <shallow>false</shallow>
                <noTags>false</noTags>
                <reference></reference>
                <depth>0</depth>
                <honorRefspec>false</honorRefspec>
              </extension>
            </jenkins.plugins.git.traits.CloneOptionTrait>
          </traits>
        </source>
        <strategy class="jenkins.branch.DefaultBranchPropertyStrategy">
          <properties class="empty-list"/>
        </strategy>
      </jenkins.branch.BranchSource>
    </data>
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
  </sources>
  <factory class="org.jenkinsci.plugins.workflow.multibranch.WorkflowBranchProjectFactory">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
    <scriptPath>Jenkinsfile</scriptPath>
  </factory>
</org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
JOBXML
}

# -----------------------------------------------------------------------------
# Create or Update Job
# -----------------------------------------------------------------------------
create_or_update_job() {
    local job_name="$1"
    local repo_url="$2"
    local credentials_id="$3"

    log_step "Setting up MultiBranch Pipeline: $job_name"
    log_info "Repository: $repo_url"

    local config_xml
    config_xml=$(create_multibranch_config "$job_name" "$repo_url" "$credentials_id")

    if job_exists "$job_name"; then
        log_info "Job exists, updating..."
        local status_code
        status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -u "$JENKINS_USER:$JENKINS_TOKEN" \
            -b "$COOKIE_JAR" \
            -H "$CRUMB_FIELD: $CRUMB_VALUE" \
            -H "Content-Type: application/xml" \
            -X POST \
            --data-binary "$config_xml" \
            "$JENKINS_URL/job/$job_name/config.xml")

        if [[ "$status_code" == "200" ]]; then
            log_pass "Updated $job_name"
        else
            log_fail "Failed to update $job_name (HTTP $status_code)"
            return 1
        fi
    else
        log_info "Creating new job..."
        local status_code
        status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -u "$JENKINS_USER:$JENKINS_TOKEN" \
            -b "$COOKIE_JAR" \
            -H "$CRUMB_FIELD: $CRUMB_VALUE" \
            -H "Content-Type: application/xml" \
            -X POST \
            --data-binary "$config_xml" \
            "$JENKINS_URL/createItem?name=$job_name")

        if [[ "$status_code" == "200" ]]; then
            log_pass "Created $job_name"
        else
            log_fail "Failed to create $job_name (HTTP $status_code)"
            return 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Trigger Branch Scan
# -----------------------------------------------------------------------------
trigger_scan() {
    local job_name="$1"

    log_step "Triggering branch scan for $job_name..."

    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        -b "$COOKIE_JAR" \
        -H "$CRUMB_FIELD: $CRUMB_VALUE" \
        -X POST \
        "$JENKINS_URL/job/$job_name/build")

    if [[ "$status_code" == "201" || "$status_code" == "200" ]]; then
        log_pass "Triggered scan for $job_name"
    else
        log_info "Scan trigger returned HTTP $status_code (may already be scanning)"
    fi
}

# -----------------------------------------------------------------------------
# Setup Jenkins Credentials for GitLab
# -----------------------------------------------------------------------------
setup_gitlab_credentials() {
    local credentials_id="gitlab-credentials"

    # NOTE: This function's output is captured, so log to stderr
    log_step "Setting up GitLab credentials in Jenkins..." >&2

    # Get GitLab token
    local gitlab_token
    gitlab_token=$(kubectl get secret "$GITLAB_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -z "$gitlab_token" ]]; then
        log_fail "Could not get GitLab token" >&2
        return 1
    fi

    # Create credentials XML
    local cred_xml
    cred_xml=$(cat <<CREDXML
<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>${credentials_id}</id>
  <description>GitLab credentials for ${CLUSTER_NAME}</description>
  <username>${GITLAB_USER:-root}</username>
  <password>${gitlab_token}</password>
</com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
CREDXML
)

    # Check if credentials exist
    local status_code
    status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/credentials/store/system/domain/_/credential/$credentials_id/api/json")

    if [[ "$status_code" == "200" ]]; then
        log_info "Credentials already exist, updating..." >&2
        status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -u "$JENKINS_USER:$JENKINS_TOKEN" \
            -b "$COOKIE_JAR" \
            -H "$CRUMB_FIELD: $CRUMB_VALUE" \
            -H "Content-Type: application/xml" \
            -X POST \
            --data-binary "$cred_xml" \
            "$JENKINS_URL/credentials/store/system/domain/_/credential/$credentials_id/config.xml")
    else
        log_info "Creating new credentials..." >&2
        status_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -u "$JENKINS_USER:$JENKINS_TOKEN" \
            -b "$COOKIE_JAR" \
            -H "$CRUMB_FIELD: $CRUMB_VALUE" \
            -H "Content-Type: application/xml" \
            -X POST \
            --data-binary "$cred_xml" \
            "$JENKINS_URL/credentials/store/system/domain/_/createCredentials")
    fi

    if [[ "$status_code" == "200" ]]; then
        log_pass "GitLab credentials configured" >&2
    else
        log_fail "Failed to configure credentials (HTTP $status_code)" >&2
        return 1
    fi

    # Output ONLY the credentials ID (captured by caller)
    echo "$credentials_id"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo ""
    echo "=========================================="
    echo "Jenkins MultiBranch Pipeline Setup"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Jenkins: $JENKINS_URL"
    log_info "GitLab:  $GITLAB_URL"
    echo ""

    load_credentials
    get_crumb

    # Setup GitLab credentials in Jenkins
    local cred_id
    cred_id=$(setup_gitlab_credentials) || exit 1

    # Create example-app MultiBranch Pipeline
    create_or_update_job "example-app" "${GITLAB_URL}/${APP_REPO_PATH}.git" "$cred_id" || exit 1

    # Create k8s-deployments MultiBranch Pipeline
    create_or_update_job "k8s-deployments" "${GITLAB_URL}/${DEPLOYMENTS_REPO_PATH}.git" "$cred_id" || exit 1

    echo ""
    log_step "Triggering initial branch scans..."
    # Only scan k8s-deployments to discover env branches (dev/stage/prod).
    # example-app is NOT scanned here — its first build should come from
    # a user/demo action via webhook, not from bootstrap.
    trigger_scan "k8s-deployments"

    echo ""
    echo "=========================================="
    log_pass "MultiBranch Pipeline setup complete"
    echo "=========================================="
    echo ""
    log_info "Jobs created:"
    log_info "  - example-app"
    log_info "  - k8s-deployments"
    echo ""
    log_info "Branch scans have been triggered."
    log_info "Check Jenkins at: $JENKINS_URL"
    echo ""
}

main "$@"
