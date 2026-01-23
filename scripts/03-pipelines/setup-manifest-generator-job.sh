#!/bin/bash
# Script to create the k8s-manifest-generator Jenkins job
# This job automatically generates Kubernetes manifests from CUE configuration

set -e

# Source infrastructure configuration
source "$(dirname "${BASH_SOURCE[0]}")/../lib/infra.sh"

JENKINS_URL="${JENKINS_URL:-http://jenkins.local}"
JOB_NAME="k8s-manifest-generator"

# Get Jenkins admin password from Kubernetes secret
echo "Getting Jenkins credentials..."
JENKINS_PASSWORD=$(kubectl get secret jenkins -n jenkins -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)

# Create temporary files for cookies and crumb
COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"
CONFIG_FILE="/tmp/k8s-manifest-generator-config.xml"

# Check if job already exists
echo "Checking if job already exists..."
JOB_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${JENKINS_URL}/job/${JOB_NAME}/api/json" \
  -u "admin:${JENKINS_PASSWORD}")

if [ "$JOB_EXISTS" = "200" ]; then
  echo "✓ Job '${JOB_NAME}' already exists"
  echo "  View at: ${JENKINS_URL}/job/${JOB_NAME}"
  exit 0
fi

# Create job configuration XML
cat > "$CONFIG_FILE" << EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@2.40">
  <description>Automated Kubernetes manifest generation from CUE configuration files.

This job is triggered automatically when CUE files change in the k8s-deployments repository.
It runs generate-manifests.sh and commits the results back to the repository.

IMPORTANT: Never run generate-manifests.sh manually - this pipeline owns manifest generation!</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <hudson.triggers.SCMTrigger>
          <spec>H/5 * * * *</spec>
          <ignorePostCommitHooks>false</ignorePostCommitHooks>
        </hudson.triggers.SCMTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps@2.90">
    <scm class="hudson.plugins.git.GitSCM" plugin="git@4.8.2">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${DEPLOYMENTS_REPO_URL}</url>
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
      <extensions>
        <hudson.plugins.git.extensions.impl.PathRestriction>
          <includedRegions>envs/.*\.cue
services/.*\.cue
k8s/.*\.cue
scripts/generate-manifests\.sh</includedRegions>
          <excludedRegions>manifests/.*</excludedRegions>
        </hudson.plugins.git.extensions.impl.PathRestriction>
      </extensions>
    </scm>
    <scriptPath>jenkins/pipelines/Jenkinsfile.k8s-manifest-generator</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF

# Get crumb with cookies
echo "Getting CSRF crumb..."
curl -c "$COOKIE_JAR" -b "$COOKIE_JAR" -s "${JENKINS_URL}/crumbIssuer/api/json" \
  -u "admin:${JENKINS_PASSWORD}" \
  > "$CRUMB_FILE"

CRUMB=$(jq -r '.crumb' "$CRUMB_FILE")
echo "Crumb: ${CRUMB:0:16}..."

# Create the job
echo "Creating Jenkins job: $JOB_NAME"
HTTP_STATUS=$(curl -X POST "${JENKINS_URL}/createItem?name=${JOB_NAME}" \
  -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
  -u "admin:${JENKINS_PASSWORD}" \
  -H "Jenkins-Crumb: ${CRUMB}" \
  -H "Content-Type: application/xml" \
  --data-binary @"$CONFIG_FILE" \
  -w "%{http_code}" \
  -s -o /tmp/jenkins-create-response.txt)

# Cleanup
rm -f "$COOKIE_JAR" "$CRUMB_FILE" "$CONFIG_FILE"

if [ "$HTTP_STATUS" = "200" ]; then
  echo "✓ Job created successfully (HTTP $HTTP_STATUS)"
  echo "  View at: ${JENKINS_URL}/job/${JOB_NAME}"
  echo ""
  echo "Note: The Jenkinsfile must be committed to the k8s-deployments repo at:"
  echo "  jenkins/pipelines/Jenkinsfile.k8s-manifest-generator"
  exit 0
else
  echo "✗ Failed to create job (HTTP $HTTP_STATUS)"
  cat /tmp/jenkins-create-response.txt
  exit 1
fi
