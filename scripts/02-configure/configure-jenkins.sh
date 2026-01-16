#!/bin/bash
set -euo pipefail

# Jenkins Configuration Script
# Documents manual configuration steps for Jenkins

# Source centralized GitLab configuration
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"

JENKINS_URL="http://jenkins.local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_jenkins() {
    log_info "Waiting for Jenkins to be ready..."
    for i in {1..30}; do
        if curl -sf "${JENKINS_URL}" > /dev/null 2>&1; then
            log_info "Jenkins is ready!"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    log_error "Jenkins did not become ready in time"
    return 1
}

print_configuration_guide() {
    cat << EOF

========================================
Jenkins Configuration Guide
========================================

IMPORTANT: Jenkins is running WITHOUT authentication (local dev only!)

1. Access Jenkins:
   URL: http://jenkins.local

2. Install Required Plugins:
   - Go to: Manage Jenkins → Plugins → Available Plugins

   Required Plugins:
   ✓ Git Plugin (usually pre-installed)
   ✓ GitLab Plugin (for webhook integration)
   ✓ Pipeline Plugin (usually pre-installed)
   ✓ Docker Plugin (for Docker builds)
   ✓ Docker Pipeline Plugin (for Docker in pipelines)
   ✓ Kubernetes Plugin (for dynamic agents)
   ✓ Credentials Plugin (usually pre-installed)
   ✓ Credentials Binding Plugin (for secret injection)

   Search and install:
   - gitlab-plugin
   - docker-workflow
   - kubernetes

   Click "Download now and install after restart"
   Check "Restart Jenkins when installation is complete"

3. Configure Credentials:
   Go to: Manage Jenkins → Credentials → System → Global credentials

   A. GitLab Personal Access Token:
      - Click "Add Credentials"
      - Kind: GitLab API token
      - Scope: Global
      - API token: <paste token from GitLab>
      - ID: gitlab-api-token
      - Description: GitLab API Token for Jenkins

   B. GitLab Username/Password (for git clone):
      - Click "Add Credentials"
      - Kind: Username with password
      - Scope: Global
      - Username: root
      - Password: <your GitLab password>
      - ID: gitlab-credentials
      - Description: GitLab Username/Password

   C. Nexus Credentials:
      - Click "Add Credentials"
      - Kind: Username with password
      - Scope: Global
      - Username: admin
      - Password: admin123
      - ID: nexus-credentials
      - Description: Nexus Repository Credentials

   D. Docker Registry Credentials (Nexus):
      - Click "Add Credentials"
      - Kind: Username with password
      - Scope: Global
      - Username: admin
      - Password: admin123
      - ID: docker-registry-credentials
      - Description: Docker Registry (Nexus) Credentials

4. Configure Kubernetes Plugin:
   Go to: Manage Jenkins → Clouds → New cloud

   - Name: kubernetes
   - Type: Kubernetes
   - Kubernetes URL: https://kubernetes.default.svc.cluster.local
   - Kubernetes Namespace: jenkins
   - Credentials: (leave empty - uses in-cluster service account)
   - Jenkins URL: http://jenkins.jenkins.svc.cluster.local:8080

   Pod Template:
   - Name: jenkins-agent
   - Namespace: jenkins
   - Labels: jenkins-agent
   - Container Template:
     - Name: jnlp
     - Docker image: nexus.local:5000/jenkins-agent-custom:latest
     - Working directory: /home/jenkins/agent
     - Command to run: (leave empty)
     - Arguments to pass: (leave empty)

   - Add Volume:
     - Type: Host Path Volume
     - Host path: /var/run/docker.sock
     - Mount path: /var/run/docker.sock
     (This enables Docker-in-Docker)

5. Configure GitLab Connection:
   Go to: Manage Jenkins → System

   Scroll to "GitLab" section:
   - Connection name: gitlab
   - GitLab host URL: ${GITLAB_URL_EXTERNAL}
   - Credentials: Select "gitlab-api-token"
   - Test Connection (should show success)

6. Configure Maven:
   Go to: Manage Jenkins → Tools

   Maven installations:
   - Name: maven-3.9.6
   - Install automatically: No
   - MAVEN_HOME: /opt/maven
   (Maven is pre-installed in custom agent image)

7. Configure JDK:
   Go to: Manage Jenkins → Tools

   JDK installations:
   - Name: jdk-17
   - Install automatically: No
   - JAVA_HOME: /opt/java/openjdk
   (JDK 17 is pre-installed in custom agent image)

========================================
Pipeline Jobs Setup
========================================

After manual configuration above, you'll create these pipeline jobs:

1. example-app-ci
   - Type: Pipeline (Jenkinsfile from SCM)
   - SCM: Git
   - Repository URL: ${APP_REPO_URL_EXTERNAL}
   - Credentials: gitlab-credentials
   - Branch: */main
   - Script Path: Jenkinsfile
   - Build Triggers:
     ✓ Build when a change is pushed to GitLab
     ✓ Accepted Merge Request Events

2. deployment-updater
   - Type: Pipeline (parameterized)
   - Parameters:
     - APP_NAME (string)
     - APP_VERSION (string)
     - IMAGE_TAG (string)
     - TARGET_ENV (choice: dev, stage, prod)

3. environment-promoter
   - Type: Pipeline (parameterized)
   - Parameters:
     - APP_NAME (string)
     - SOURCE_ENV (choice: dev, stage)
     - TARGET_ENV (choice: stage, prod)

========================================
Webhook Configuration (Done Later)
========================================

After creating the example-app project in GitLab:
1. Go to: example-app → Settings → Webhooks
2. URL: http://jenkins.local/project/example-app-ci
3. Secret Token: (leave empty for now)
4. Trigger: Push events, Merge request events
5. SSL verification: Disable (local dev)

========================================
Test Configuration
========================================

1. Create test pipeline:
   - New Item → Pipeline
   - Name: test-pipeline
   - Pipeline script:

pipeline {
    agent {
        kubernetes {
            label 'jenkins-agent'
        }
    }
    stages {
        stage('Test') {
            steps {
                sh 'java -version'
                sh 'mvn -version'
                sh 'docker --version'
                sh 'cue version'
                sh 'kubectl version --client'
            }
        }
    }
}

2. Run the pipeline
3. Verify all tools are available

========================================
Environment Variables (Optional)
========================================

Go to: Manage Jenkins → System → Global properties
Check "Environment variables"

Add these for convenience:
- NEXUS_URL: http://nexus.local
- NEXUS_DOCKER_REGISTRY: nexus.local:5000
- GITLAB_URL: ${GITLAB_URL_EXTERNAL}
- ARGOCD_SERVER: argocd.local
- K8S_NAMESPACE_DEV: dev
- K8S_NAMESPACE_STAGE: stage
- K8S_NAMESPACE_PROD: prod

========================================
Next Steps:
========================================
1. Complete manual configuration above
2. Install and configure plugins
3. Add all credentials
4. Configure Kubernetes cloud
5. Test with test-pipeline
6. Create actual pipeline jobs (after app creation)

========================================
EOF
}

main() {
    log_info "Starting Jenkins configuration..."

    wait_for_jenkins
    print_configuration_guide

    # Save configuration guide
    print_configuration_guide > /home/jmann/git/mannjg/deployment-pipeline/JENKINS_SETUP_GUIDE.md
    log_info "Configuration guide saved to: JENKINS_SETUP_GUIDE.md"
}

main "$@"
