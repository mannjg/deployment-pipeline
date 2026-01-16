#!/bin/bash
# Script to create Jenkins job for k8s-deployments validation
# This job validates infrastructure changes before they're merged

set -e

# Source centralized GitLab configuration
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

JENKINS_URL="${JENKINS_URL:-http://jenkins.local}"
JOB_NAME="k8s-deployments-validation"
REPO_URL="${DEPLOYMENTS_REPO_URL}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setting up k8s-deployments validation job"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Jenkins URL: $JENKINS_URL"
echo "Job Name: $JOB_NAME"
echo "Repository: $REPO_URL"
echo ""

# Get Jenkins credentials
echo "Getting Jenkins credentials..."
JENKINS_PASSWORD=$(microk8s kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

# Create temporary files
COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"
JOB_CONFIG="/tmp/jenkins-job-config-$$.xml"

# Get CSRF crumb
echo "Getting CSRF crumb..."
curl -c "$COOKIE_JAR" -b "$COOKIE_JAR" -s "${JENKINS_URL}/crumbIssuer/api/json" \
  -u "admin:${JENKINS_PASSWORD}" \
  > "$CRUMB_FILE"

CRUMB=$(jq -r '.crumb' "$CRUMB_FILE")
echo "Crumb: ${CRUMB:0:16}..."

# Create job configuration XML
cat > "$JOB_CONFIG" <<'EOF'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@2.40">
  <actions/>
  <description>Validates k8s-deployments repository changes (CUE config, manifests, YAML)</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>BRANCH_NAME</name>
          <description>Branch to validate</description>
          <defaultValue>dev</defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.BooleanParameterDefinition>
          <name>VALIDATE_ALL_ENVS</name>
          <description>Validate all environments (dev, stage, prod)</description>
          <defaultValue>true</defaultValue>
        </hudson.model.BooleanParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <com.dabsquared.gitlabjenkins.GitLabPushTrigger plugin="gitlab-plugin@1.5.13">
          <spec></spec>
          <triggerOnPush>true</triggerOnPush>
          <triggerOnMergeRequest>true</triggerOnMergeRequest>
          <triggerOpenMergeRequestOnPush>never</triggerOpenMergeRequestOnPush>
          <triggerOnNoteRequest>false</triggerOnNoteRequest>
          <noteRegex>Jenkins please retry a build</noteRegex>
          <ciSkip>true</ciSkip>
          <skipWorkInProgressMergeRequest>false</skipWorkInProgressMergeRequest>
          <setBuildDescription>true</setBuildDescription>
          <branchFilterType>All</branchFilterType>
          <includeBranchesSpec></includeBranchesSpec>
          <excludeBranchesSpec></excludeBranchesSpec>
          <sourceBranchRegex></sourceBranchRegex>
          <targetBranchRegex></targetBranchRegex>
          <secretToken></secretToken>
          <pendingBuildName></pendingBuildName>
          <cancelPendingBuildsOnUpdate>false</cancelPendingBuildsOnUpdate>
        </com.dabsquared.gitlabjenkins.GitLabPushTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps@2.90">
    <scm class="hudson.plugins.git.GitSCM" plugin="git@4.10.0">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>REPO_URL_PLACEHOLDER</url>
          <credentialsId>gitlab-credentials</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="list"/>
      <extensions/>
    </scm>
    <scriptPath>jenkins/k8s-deployments-validation.Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF

# Replace placeholder with actual repo URL
sed -i "s|REPO_URL_PLACEHOLDER|$REPO_URL|g" "$JOB_CONFIG"

# Check if job already exists
echo "Checking if job exists..."
JOB_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "admin:${JENKINS_PASSWORD}" \
  "${JENKINS_URL}/job/${JOB_NAME}/config.xml")

if [ "$JOB_EXISTS" = "200" ]; then
    echo "Job already exists, updating configuration..."
    HTTP_STATUS=$(curl -X POST "${JENKINS_URL}/job/${JOB_NAME}/config.xml" \
      -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
      -u "admin:${JENKINS_PASSWORD}" \
      -H "Jenkins-Crumb: ${CRUMB}" \
      -H "Content-Type: application/xml" \
      --data-binary "@${JOB_CONFIG}" \
      -w "%{http_code}" \
      -s -o /dev/null)

    if [ "$HTTP_STATUS" = "200" ]; then
        echo "✓ Job updated successfully"
    else
        echo "✗ Failed to update job (HTTP $HTTP_STATUS)"
        exit 1
    fi
else
    echo "Creating new job..."
    HTTP_STATUS=$(curl -X POST "${JENKINS_URL}/createItem?name=${JOB_NAME}" \
      -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
      -u "admin:${JENKINS_PASSWORD}" \
      -H "Jenkins-Crumb: ${CRUMB}" \
      -H "Content-Type: application/xml" \
      --data-binary "@${JOB_CONFIG}" \
      -w "%{http_code}" \
      -s -o /dev/null)

    if [ "$HTTP_STATUS" = "200" ]; then
        echo "✓ Job created successfully"
    else
        echo "✗ Failed to create job (HTTP $HTTP_STATUS)"
        exit 1
    fi
fi

# Cleanup
rm -f "$COOKIE_JAR" "$CRUMB_FILE" "$JOB_CONFIG"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Job setup complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Job URL: ${JENKINS_URL}/job/${JOB_NAME}"
echo ""
echo "Next steps:"
echo "1. Set up webhook: ./scripts/setup-k8s-deployments-webhook.sh"
echo "2. Test with: curl -X POST ${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters \\"
echo "              -u admin:\$JENKINS_PASSWORD \\"
echo "              -d BRANCH_NAME=dev"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
