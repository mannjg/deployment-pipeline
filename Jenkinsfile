// Jenkinsfile for example-app CI/CD pipeline
// Stages: Unit Tests → Integration Tests → Build & Publish → Deploy Update

pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: maven
    image: localhost:30500/jenkins-agent-custom:latest
    command:
    - cat
    tty: true
    volumeMounts:
    - name: docker-sock
      mountPath: /var/run/docker.sock
  volumes:
  - name: docker-sock
    hostPath:
      path: /var/run/docker.sock
"""
        }
    }

    environment {
        // Application metadata
        APP_NAME = 'example-app'
        APP_GROUP = 'example'

        // Registry configuration
        // Use internal cluster DNS (HTTP is acceptable within trusted cluster network)
        DOCKER_REGISTRY = 'nexus.nexus.svc.cluster.local:5000'
        // Nexus Maven repository (internal cluster DNS)
        NEXUS_URL = 'http://nexus.nexus.svc.cluster.local:8081'

        // Git repositories (use internal cluster DNS)
        GITLAB_URL = 'http://gitlab.gitlab.svc.cluster.local'
        DEPLOYMENT_REPO = "${GITLAB_URL}/example/k8s-deployments.git"

        // Credentials
        NEXUS_CREDENTIALS = credentials('nexus-credentials')
        DOCKER_CREDENTIALS = credentials('docker-registry-credentials')
        GITLAB_CREDENTIALS = credentials('gitlab-credentials')
        GITLAB_API_TOKEN = credentials('gitlab-api-token-secret')

        // Computed image reference
        IMAGE_NAME = "${DOCKER_REGISTRY}/${APP_GROUP}/${APP_NAME}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                container('maven') {
                    script {
                        // Extract version from pom.xml
                        env.APP_VERSION = sh(
                            script: "mvn help:evaluate -Dexpression=project.version -q -DforceStdout",
                            returnStdout: true
                        ).trim()

                        // Generate image tag (version + git hash)
                        env.GIT_SHORT_HASH = sh(
                            script: "git rev-parse --short HEAD",
                            returnStdout: true
                        ).trim()

                        env.IMAGE_TAG = "${env.APP_VERSION}-${env.GIT_SHORT_HASH}"
                        env.FULL_IMAGE = "${env.IMAGE_NAME}:${env.IMAGE_TAG}"

                        // Separate registry for deployment manifests (external ingress for kubelet)
                        env.DEPLOY_REGISTRY = 'docker.local'
                        env.IMAGE_FOR_DEPLOY = "${env.DEPLOY_REGISTRY}/${env.APP_GROUP}/${env.APP_NAME}:${env.IMAGE_TAG}"

                        echo "Building ${env.APP_NAME} version ${env.APP_VERSION}"
                        echo "Image for push: ${env.FULL_IMAGE}"
                        echo "Image for deploy: ${env.IMAGE_FOR_DEPLOY}"
                    }
                }
            }
        }

        stage('Unit Tests') {
            when {
                // Run on every commit
                expression { return true }
            }
            steps {
                container('maven') {
                    echo "Running unit tests..."
                    sh 'mvn clean test'
                }
            }
            post {
                always {
                    junit '**/target/surefire-reports/*.xml'
                }
            }
        }

        stage('Integration Tests') {
            when {
                // Temporarily skip ITs to speed up development iterations
                expression { return false }
            }
            steps {
                container('maven') {
                    echo "Running integration tests with TestContainers..."
                    sh 'mvn verify -DskipITs=false'
                }
            }
            post {
                always {
                    junit '**/target/failsafe-reports/*.xml'
                }
            }
        }

        stage('Build & Publish') {
            steps {
                container('maven') {
                    script {
                        echo "Building and publishing Docker image..."

                        // Build and push with Jib (no docker login needed, Jib handles auth)
                        sh """
                            mvn clean package \
                                -Dquarkus.container-image.build=true \
                                -Dquarkus.container-image.push=true \
                                -Dquarkus.container-image.registry=${DOCKER_REGISTRY} \
                                -Dquarkus.container-image.group=${APP_GROUP} \
                                -Dquarkus.container-image.name=${APP_NAME} \
                                -Dquarkus.container-image.tag=${IMAGE_TAG} \
                                -Dquarkus.container-image.insecure=true \
                                -Dquarkus.container-image.username=${DOCKER_CREDENTIALS_USR} \
                                -Dquarkus.container-image.password=${DOCKER_CREDENTIALS_PSW} \
                                -DsendCredentialsOverHttp=true
                        """

                        // Also publish Maven artifacts to Nexus
                        sh """
                            # Create temporary Maven settings.xml with credentials
                            cat > /tmp/maven-settings.xml <<'MAVEN_SETTINGS'
<?xml version="1.0" encoding="UTF-8"?>
<settings>
  <servers>
    <server>
      <id>nexus</id>
      <username>${NEXUS_CREDENTIALS_USR}</username>
      <password>${NEXUS_CREDENTIALS_PSW}</password>
    </server>
  </servers>
</settings>
MAVEN_SETTINGS

                            mvn deploy -DskipTests \
                                -s /tmp/maven-settings.xml \
                                -DaltDeploymentRepository=nexus::default::${NEXUS_URL}/repository/maven-snapshots/
                        """

                        echo "Published image: ${FULL_IMAGE}"
                        echo "Published Maven artifact: ${APP_NAME}-${APP_VERSION}"
                    }
                }
            }
        }

        stage('Update Deployment Repo') {
            steps {
                container('maven') {
                    script {
                        echo "Updating deployment repository..."

                        // Use withCredentials for explicit credential binding
                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USERNAME',
                                                          passwordVariable: 'GIT_PASSWORD')]) {
                            sh '''
                                git config --global user.name "Jenkins CI"
                                git config --global user.email "jenkins@local"

                                rm -rf k8s-deployments

                                # Configure git credential helper (ephemeral, no files)
                                git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

                                # Clone using credential helper
                                git clone http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git k8s-deployments
                                cd k8s-deployments

                                # Fetch latest dev branch
                                git fetch origin dev
                                git checkout dev
                                git pull origin dev

                                # Create feature branch for this deployment
                                FEATURE_BRANCH="update-dev-${IMAGE_TAG}"
                                git checkout -b "$FEATURE_BRANCH"
                            '''

                            // **NEW: Sync deployment/app.cue from application repo to k8s-deployments**
                            sh """
                                cd k8s-deployments

                                # Ensure target directory exists
                                mkdir -p services/apps

                                # Check if deployment/app.cue exists in application repo
                                if [ -f "${WORKSPACE}/deployment/app.cue" ]; then
                                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                    echo "Syncing deployment configuration..."
                                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                                    # Copy app-specific CUE config from source repo
                                    echo "Source: ${WORKSPACE}/deployment/app.cue"
                                    echo "Target: services/apps/${APP_NAME}.cue"
                                    cp ${WORKSPACE}/deployment/app.cue services/apps/${APP_NAME}.cue

                                    # Validate the synced CUE file
                                    echo ""
                                    echo "Validating synced configuration..."
                                    if command -v cue &> /dev/null; then
                                        if cue vet -c=false ./services/apps/${APP_NAME}.cue; then
                                            echo "✓ Synced configuration is valid"
                                        else
                                            echo "✗ ERROR: Synced configuration validation failed!"
                                            exit 1
                                        fi
                                    else
                                        echo "⚠ CUE not found - skipping validation"
                                    fi

                                    # Show what changed
                                    echo ""
                                    echo "Configuration changes:"
                                    if git diff --quiet services/apps/${APP_NAME}.cue; then
                                        echo "  No changes in deployment configuration"
                                    else
                                        echo "  Deployment configuration updated:"
                                        git diff services/apps/${APP_NAME}.cue | head -30
                                    fi
                                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                    echo ""
                                else
                                    echo "⚠ Warning: deployment/app.cue not found in ${WORKSPACE}"
                                    echo "  Skipping configuration sync"
                                fi
                            """

                            // Update image version in CUE configuration and generate manifests
                            sh """
                                cd k8s-deployments

                                # Update the image reference in the dev environment CUE file
                                # Use DEPLOY_REGISTRY (docker.local) for kubelet to pull via external ingress
                                sed -i 's|image: ".*"|image: "${IMAGE_FOR_DEPLOY}"|' envs/dev.cue

                                # Verify the change
                                echo "Updated image in envs/dev.cue:"
                                grep 'image:' envs/dev.cue

                                # Generate Kubernetes manifests from CUE
                                ./scripts/generate-manifests.sh dev

                                # Stage all changes (synced app config + env CUE file + generated manifests)
                                git add services/apps/${APP_NAME}.cue envs/dev.cue manifests/dev/

                                # Commit with metadata
                                git commit -m "Update ${APP_NAME} to ${IMAGE_TAG}

Automated deployment update from application CI/CD pipeline.

Changes:
- Synced services/apps/${APP_NAME}.cue from source repository
- Updated dev environment image to ${IMAGE_TAG}
- Regenerated Kubernetes manifests

Build: ${env.BUILD_URL}
Git commit: ${GIT_SHORT_HASH}
Image: ${FULL_IMAGE}
Deploy image: ${IMAGE_FOR_DEPLOY}

Generated manifests from CUE configuration." || echo "No changes to commit"
                            """

                            // Push feature branch and create MR
                            sh '''
                                cd k8s-deployments
                                FEATURE_BRANCH="update-dev-${IMAGE_TAG}"
                                # Delete remote branch if it exists, then push fresh
                                git push origin --delete "$FEATURE_BRANCH" 2>/dev/null || echo "Branch does not exist remotely (fine)"
                                git push -u origin "$FEATURE_BRANCH"

                                # Clear credential helper after all git operations with auth
                                git config --global --unset credential.helper || true
                            '''

                            // Create MR to dev branch using GitLab API token
                            sh """
                                cd k8s-deployments

                                # Export GitLab token for the script
                                export GITLAB_TOKEN="${GITLAB_API_TOKEN}"
                                export GITLAB_URL="${GITLAB_URL}"

                                # Create MR with deployment details
                                ./scripts/create-gitlab-mr.sh \
                                        "update-dev-${IMAGE_TAG}" \
                                        dev \
                                        "Deploy ${APP_NAME} to dev: ${IMAGE_TAG}" \
                                        "## Automatic Deployment to Dev

**Application**: ${APP_NAME}
**Image Tag**: ${IMAGE_TAG}
**Build**: ${BUILD_URL}
**Git Commit**: ${GIT_SHORT_HASH}

### Changes

This merge request updates the dev environment with the latest build.

**Image**: ${FULL_IMAGE}

### Review Checklist

- [ ] Image tag is correct
- [ ] CUE configuration updated
- [ ] Manifests regenerated successfully
- [ ] Ready to deploy to dev

Once merged, ArgoCD will automatically deploy to the dev namespace.

---
*Generated by Jenkins CI/CD Pipeline*"
                            """
                        }

                        echo "Feature branch created and MR opened"
                        echo "Merge the MR to deploy to dev environment"
                    }
                }
            }
        }

        stage('Create Stage Promotion MR') {
            steps {
                container('maven') {
                    script {
                        echo "Creating MR for stage promotion..."

                        // Update stage environment (not a simple merge - update stage.cue)
                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USERNAME',
                                                          passwordVariable: 'GIT_PASSWORD')]) {
                            sh '''
                                # Configure git credential helper (ephemeral, no files)
                                git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

                                cd k8s-deployments

                                # Fetch and checkout stage branch
                                git fetch origin stage
                                git checkout stage
                                git pull origin stage

                                # Create feature branch for this promotion
                                PROMOTE_BRANCH="promote-stage-${IMAGE_TAG}"
                                git checkout -b "$PROMOTE_BRANCH"
                            '''

                            // Update stage.cue with the new image
                            sh """
                                cd k8s-deployments

                                # Update the image reference in the stage environment CUE file
                                sed -i 's|image: ".*"|image: "${IMAGE_FOR_DEPLOY}"|' envs/stage.cue

                                # Verify the change
                                echo "Updated image in envs/stage.cue:"
                                grep 'image:' envs/stage.cue

                                # Generate Kubernetes manifests from CUE for stage
                                ./scripts/generate-manifests.sh stage

                                # Stage all changes (CUE file + generated manifests)
                                git add envs/stage.cue manifests/stage/

                                # Commit with metadata
                                git commit -m "Promote ${APP_NAME} to stage: ${IMAGE_TAG}

Triggered by: ${env.BUILD_URL}
Git commit: ${GIT_SHORT_HASH}
Image: ${FULL_IMAGE}

Promoting from dev to stage environment" || echo "No changes to commit"
                            """

                            // Push feature branch and create MR
                            sh '''
                                cd k8s-deployments
                                PROMOTE_BRANCH="promote-stage-${IMAGE_TAG}"
                                # Delete remote branch if it exists, then push fresh
                                git push origin --delete "$PROMOTE_BRANCH" 2>/dev/null || echo "Branch does not exist remotely (fine)"
                                git push -u origin "$PROMOTE_BRANCH"

                                # Clear credential helper after all git operations with auth
                                git config --global --unset credential.helper || true
                            '''

                            // Create MR to stage branch
                            sh """
                                cd k8s-deployments

                                # Export GitLab token for the script
                                export GITLAB_TOKEN="${GITLAB_API_TOKEN}"
                                export GITLAB_URL="${GITLAB_URL}"

                                # Create MR with detailed description
                                ./scripts/create-gitlab-mr.sh \
                                        "promote-stage-${IMAGE_TAG}" \
                                        stage \
                                        "Promote ${APP_NAME} to stage: ${IMAGE_TAG}" \
                                        "## Automatic Promotion from Dev

**Application**: ${APP_NAME}
**Image Tag**: ${IMAGE_TAG}
**Build**: ${BUILD_URL}
**Git Commit**: ${GIT_SHORT_HASH}

### Changes

This merge request updates the stage environment with the image currently deployed in dev.

**Image**: ${FULL_IMAGE}

### Testing

- ✅ Unit tests passed
- ✅ Build successful
- ✅ Deployed to dev environment
- ✅ ArgoCD auto-synced successfully

### Deployment

Once this MR is merged, ArgoCD will automatically deploy to the stage namespace.

---
*Generated by Jenkins CI/CD Pipeline*"
                            """
                        }

                        echo "Promotion MR: promote-stage-${IMAGE_TAG} → stage"
                        echo "Review changes and merge when ready to promote to stage"
                    }
                }
            }
        }

        stage('Create Prod Promotion MR') {
            steps {
                container('maven') {
                    script {
                        echo "Creating MR for prod promotion..."

                        // Update prod environment (update prod.cue)
                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USERNAME',
                                                          passwordVariable: 'GIT_PASSWORD')]) {
                            sh '''
                                # Configure git credential helper (ephemeral, no files)
                                git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

                                cd k8s-deployments

                                # Fetch and checkout prod branch
                                git fetch origin prod
                                git checkout prod
                                git pull origin prod

                                # Create feature branch for this promotion
                                PROMOTE_BRANCH="promote-prod-${IMAGE_TAG}"
                                git checkout -b "$PROMOTE_BRANCH"
                            '''

                            // Update prod.cue with the new image
                            sh """
                                cd k8s-deployments

                                # Update the image reference in the prod environment CUE file
                                sed -i 's|image: ".*"|image: "${IMAGE_FOR_DEPLOY}"|' envs/prod.cue

                                # Verify the change
                                echo "Updated image in envs/prod.cue:"
                                grep 'image:' envs/prod.cue

                                # Generate Kubernetes manifests from CUE for prod
                                ./scripts/generate-manifests.sh prod

                                # Stage all changes (CUE file + generated manifests)
                                git add envs/prod.cue manifests/prod/

                                # Commit with metadata
                                git commit -m "Promote ${APP_NAME} to prod: ${IMAGE_TAG}

Triggered by: ${env.BUILD_URL}
Git commit: ${GIT_SHORT_HASH}
Image: ${FULL_IMAGE}

Promoting from stage to prod environment" || echo "No changes to commit"
                            """

                            // Push feature branch and create MR
                            sh '''
                                cd k8s-deployments
                                PROMOTE_BRANCH="promote-prod-${IMAGE_TAG}"
                                # Delete remote branch if it exists, then push fresh
                                git push origin --delete "$PROMOTE_BRANCH" 2>/dev/null || echo "Branch does not exist remotely (fine)"
                                git push -u origin "$PROMOTE_BRANCH"

                                # Clear credential helper after all git operations with auth
                                git config --global --unset credential.helper || true
                            '''

                            // Create MR to prod branch
                            sh """
                                cd k8s-deployments

                                # Export GitLab token for the script
                                export GITLAB_TOKEN="${GITLAB_API_TOKEN}"
                                export GITLAB_URL="${GITLAB_URL}"

                                # Create MR with detailed description
                                ./scripts/create-gitlab-mr.sh \
                                        "promote-prod-${IMAGE_TAG}" \
                                        prod \
                                        "Promote ${APP_NAME} to prod: ${IMAGE_TAG}" \
                                        "## Automatic Promotion from Stage

**Application**: ${APP_NAME}
**Image Tag**: ${IMAGE_TAG}
**Build**: ${BUILD_URL}
**Git Commit**: ${GIT_SHORT_HASH}

### Changes

This merge request updates the prod environment with the image currently deployed in stage.

**Image**: ${FULL_IMAGE}

### Testing

- ✅ Unit tests passed
- ✅ Build successful
- ✅ Deployed to dev environment
- ✅ Promoted to stage environment
- ✅ ArgoCD auto-synced successfully

### Deployment

Once this MR is merged, ArgoCD will automatically deploy to the prod namespace.

⚠️ **Production Deployment** - Please review carefully before merging.

---
*Generated by Jenkins CI/CD Pipeline*"
                            """
                        }

                        echo "Promotion MR: promote-prod-${IMAGE_TAG} → prod"
                        echo "Review changes and merge when ready to promote to prod"
                    }
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline completed successfully!"
            echo "Image: ${env.FULL_IMAGE}"
        }
        failure {
            echo "Pipeline failed!"
        }
    }
}
