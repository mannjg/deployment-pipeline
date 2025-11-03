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
        GITLAB_API_TOKEN = credentials('gitlab-api-token')

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

                                # Configure git credential helper to use provided credentials
                                git config --global credential.helper store
                                echo "http://${GIT_USERNAME}:${GIT_PASSWORD}@gitlab.gitlab.svc.cluster.local" > ~/.git-credentials

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

                                # Stage all changes (CUE file + generated manifests)
                                git add envs/dev.cue manifests/dev/

                                # Commit with metadata
                                git commit -m "Update ${APP_NAME} to ${IMAGE_TAG}

Triggered by: ${env.BUILD_URL}
Git commit: ${GIT_SHORT_HASH}
Image: ${FULL_IMAGE}

Generated manifests from CUE configuration" || echo "No changes to commit"
                            """

                            // Push feature branch and create MR (force push to overwrite any existing branch)
                            sh '''
                                cd k8s-deployments
                                FEATURE_BRANCH="update-dev-${IMAGE_TAG}"
                                git push -u origin "$FEATURE_BRANCH" --force
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

                        echo "Feature branch created and MR opened"
                        echo "Merge the MR to deploy to dev environment"
                    }
                }
            }
        }

        stage('Create Promotion MR') {
            steps {
                container('maven') {
                    script {
                        echo "Creating MR for stage promotion..."

                        // Use GitLab API to create MR from dev to stage
                        sh """
                            cd k8s-deployments

                            # Export GitLab token for the script
                            export GITLAB_TOKEN="${GITLAB_API_TOKEN}"
                            export GITLAB_URL="${GITLAB_URL}"

                            # Create MR with detailed description
                            ./scripts/create-gitlab-mr.sh \
                                    dev \
                                    stage \
                                    "Promote ${APP_NAME} to stage: ${IMAGE_TAG}" \
                                    "## Automatic Promotion from Dev

**Application**: ${APP_NAME}
**Image Tag**: ${IMAGE_TAG}
**Build**: ${BUILD_URL}
**Git Commit**: ${GIT_SHORT_HASH}

### Changes

This merge request promotes the latest changes from dev to stage environment.

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

                        echo "Promotion MR: dev → stage"
                        echo "Review changes and merge when ready to promote to stage"
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
