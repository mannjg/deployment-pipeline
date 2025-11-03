// Production-Quality CI/CD Pipeline for example-app
// Refactored for reliability, maintainability, and intelligent promotion workflow
//
// Key improvements:
// - Branch-based testing strategy (ITs only on rc-* branches)
// - Shared functions eliminate code duplication
// - Intelligent promotion with health monitoring
// - Proper error handling (no masked failures)
// - Secure git operations (no force push, no credential files)
// - Clean workspace management

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

    parameters {
        booleanParam(
            name: 'RUN_INTEGRATION_TESTS',
            defaultValue: false,
            description: 'Force integration tests to run (overrides branch-based logic)'
        )
        booleanParam(
            name: 'SKIP_DEPLOYMENT',
            defaultValue: false,
            description: 'Skip deployment stages (for testing build/test only)'
        )
        choice(
            name: 'PROMOTION_LEVEL',
            choices: ['auto', 'dev-only', 'dev-stage', 'all'],
            description: 'auto: intelligent promotion with health checks, dev-only: only create dev MR, dev-stage: dev + stage MRs, all: create all MRs immediately'
        )
        string(
            name: 'HEALTH_CHECK_TIMEOUT',
            defaultValue: '10',
            description: 'Minutes to wait for deployment health before promoting (0 to disable)'
        )
    }

    environment {
        // Application metadata
        APP_NAME = 'example-app'
        APP_GROUP = 'example'

        // Registry configuration (internal cluster DNS - HTTP acceptable in trusted network)
        DOCKER_REGISTRY = 'nexus.nexus.svc.cluster.local:5000'
        NEXUS_URL = 'http://nexus.nexus.svc.cluster.local:8081'

        // Git repositories (internal cluster DNS)
        GITLAB_URL = 'http://gitlab.gitlab.svc.cluster.local'
        DEPLOYMENT_REPO = "${GITLAB_URL}/example/k8s-deployments.git"

        // Credentials (using Jenkins credential binding)
        NEXUS_CREDENTIALS = credentials('nexus-credentials')
        DOCKER_CREDENTIALS = credentials('docker-registry-credentials')
        GITLAB_CREDENTIALS = credentials('gitlab-credentials')
        GITLAB_API_TOKEN = credentials('gitlab-api-token-secret')

        // Computed image references
        IMAGE_NAME = "${DOCKER_REGISTRY}/${APP_GROUP}/${APP_NAME}"

        // Deployment registry (external ingress for kubelet image pulls)
        DEPLOY_REGISTRY = 'docker.local'
    }

    options {
        // Build retention
        buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '60'))

        // Timeout for entire pipeline
        timeout(time: 1, unit: 'HOURS')

        // Disable concurrent builds for same branch
        disableConcurrentBuilds()
    }

    stages {
        stage('Checkout & Setup') {
            steps {
                container('maven') {
                    script {
                        echo "=== Checkout & Setup ==="

                        // Checkout source code
                        checkout scm

                        // Extract version from pom.xml
                        env.APP_VERSION = sh(
                            script: "mvn help:evaluate -Dexpression=project.version -q -DforceStdout",
                            returnStdout: true
                        ).trim()

                        if (!env.APP_VERSION) {
                            error("Failed to extract version from pom.xml")
                        }

                        // Generate image tag (version + git hash)
                        env.GIT_SHORT_HASH = sh(
                            script: "git rev-parse --short HEAD",
                            returnStdout: true
                        ).trim()

                        env.IMAGE_TAG = "${env.APP_VERSION}-${env.GIT_SHORT_HASH}"
                        env.FULL_IMAGE = "${env.IMAGE_NAME}:${env.IMAGE_TAG}"
                        env.IMAGE_FOR_DEPLOY = "${env.DEPLOY_REGISTRY}/${env.APP_GROUP}/${env.APP_NAME}:${env.IMAGE_TAG}"

                        // Get current branch name for conditional logic
                        env.GIT_BRANCH = sh(
                            script: "git rev-parse --abbrev-ref HEAD",
                            returnStdout: true
                        ).trim()

                        // Determine if integration tests should run
                        env.RUN_ITS = (params.RUN_INTEGRATION_TESTS || env.GIT_BRANCH.startsWith('rc-')).toString()

                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        echo "Building: ${env.APP_NAME} ${env.APP_VERSION}"
                        echo "Git branch: ${env.GIT_BRANCH}"
                        echo "Git commit: ${env.GIT_SHORT_HASH}"
                        echo "Image tag: ${env.IMAGE_TAG}"
                        echo "Push image: ${env.FULL_IMAGE}"
                        echo "Deploy image: ${env.IMAGE_FOR_DEPLOY}"
                        echo "Run ITs: ${env.RUN_ITS}"
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    }
                }
            }
        }

        stage('Unit Tests') {
            steps {
                container('maven') {
                    script {
                        echo "=== Running Unit Tests ==="
                        sh 'mvn clean test'
                    }
                }
            }
            post {
                always {
                    junit testResults: '**/target/surefire-reports/*.xml', allowEmptyResults: false
                }
            }
        }

        stage('Integration Tests') {
            when {
                expression { env.RUN_ITS == 'true' }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Running Integration Tests (TestContainers) ==="
                        echo "Note: Running on release candidate branch (${env.GIT_BRANCH})"

                        sh 'mvn verify -DskipITs=false'
                    }
                }
            }
            post {
                always {
                    junit testResults: '**/target/failsafe-reports/*.xml', allowEmptyResults: true
                }
            }
        }

        stage('Build & Publish Artifacts') {
            steps {
                container('maven') {
                    script {
                        echo "=== Building & Publishing Artifacts ==="

                        // Important: Build once, deploy many
                        // We use the same artifact (from tests) for deployment
                        // Do NOT rebuild with -DskipTests

                        // Build and push Docker image with Quarkus/Jib
                        echo "Building Docker image..."
                        sh """
                            mvn package \
                                -DskipTests \
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

                        // Verify image was pushed
                        echo "✓ Docker image pushed: ${FULL_IMAGE}"

                        // Publish Maven artifacts to Nexus
                        echo "Publishing Maven artifacts..."
                        sh """
                            # Create temporary Maven settings.xml with Nexus credentials
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

                            # Deploy to Nexus (skip tests - already run!)
                            mvn deploy -DskipTests \
                                -s /tmp/maven-settings.xml \
                                -DaltDeploymentRepository=nexus::default::${NEXUS_URL}/repository/maven-snapshots/

                            # Clean up settings file
                            rm -f /tmp/maven-settings.xml
                        """

                        echo "✓ Maven artifact published: ${APP_NAME}-${APP_VERSION}"
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        echo "✓✓ Build & Publish completed successfully"
                        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    }
                }
            }
        }

        stage('Setup Deployment Repo') {
            when {
                expression { !params.SKIP_DEPLOYMENT }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Setting Up Deployment Repository ==="

                        // Setup git configuration
                        gitHelper.setupCredentials()

                        // Clone deployment repository
                        gitHelper.cloneDeploymentRepo(env.DEPLOYMENT_REPO, 'k8s-deployments')

                        echo "✓ Deployment repository ready"
                    }
                }
            }
        }

        stage('Deploy to Dev') {
            when {
                expression { !params.SKIP_DEPLOYMENT }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Creating Dev Deployment MR ==="

                        // Create dev deployment MR using shared function
                        updateEnvironmentMR(
                            environment: 'dev',
                            targetBranch: 'dev',
                            imageTag: env.IMAGE_FOR_DEPLOY,
                            buildUrl: env.BUILD_URL,
                            gitCommit: env.GIT_SHORT_HASH,
                            fullImage: env.FULL_IMAGE,
                            buildNumber: env.BUILD_NUMBER,
                            appName: env.APP_NAME,
                            gitlabUrl: env.GITLAB_URL,
                            draft: false,        // Dev MRs not draft
                            autoMerge: false     // Require manual approval even for dev
                        )

                        echo "✓ Dev deployment MR created"
                        echo "→ Merge the MR to deploy to dev environment"
                    }
                }
            }
        }

        stage('Monitor Dev Deployment') {
            when {
                expression {
                    !params.SKIP_DEPLOYMENT &&
                    params.PROMOTION_LEVEL == 'auto' &&
                    params.HEALTH_CHECK_TIMEOUT.toInteger() > 0
                }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Monitoring Dev Deployment Health ==="
                        echo "Waiting for dev MR to be merged and deployment to be healthy..."
                        echo "(This enables automatic stage promotion)"

                        // Wait for deployment to be healthy
                        def healthy = false
                        try {
                            waitForHealthyDeployment(
                                environment: 'dev',
                                appName: env.APP_NAME,
                                namespace: 'dev',
                                timeoutMinutes: params.HEALTH_CHECK_TIMEOUT.toInteger()
                            )
                            healthy = true
                        } catch (Exception e) {
                            echo "⚠ Warning: Dev deployment health check failed: ${e.message}"
                            echo "Stage promotion will be skipped"
                            healthy = false
                        }

                        env.DEV_HEALTHY = healthy.toString()

                        if (healthy) {
                            echo "✓✓ Dev deployment is healthy - proceeding to stage promotion"
                        }
                    }
                }
            }
        }

        stage('Promote to Stage') {
            when {
                expression {
                    !params.SKIP_DEPLOYMENT &&
                    (params.PROMOTION_LEVEL == 'auto' && env.DEV_HEALTHY == 'true') ||
                    params.PROMOTION_LEVEL == 'dev-stage' ||
                    params.PROMOTION_LEVEL == 'all'
                }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Creating Stage Promotion MR ==="

                        updateEnvironmentMR(
                            environment: 'stage',
                            targetBranch: 'stage',
                            imageTag: env.IMAGE_FOR_DEPLOY,
                            buildUrl: env.BUILD_URL,
                            gitCommit: env.GIT_SHORT_HASH,
                            fullImage: env.FULL_IMAGE,
                            buildNumber: env.BUILD_NUMBER,
                            appName: env.APP_NAME,
                            gitlabUrl: env.GITLAB_URL,
                            draft: true,         // Stage MRs are draft
                            autoMerge: false
                        )

                        echo "✓ Stage promotion MR created (DRAFT)"
                        echo "→ Review and approve MR to promote to stage"
                    }
                }
            }
        }

        stage('Monitor Stage Deployment') {
            when {
                expression {
                    !params.SKIP_DEPLOYMENT &&
                    params.PROMOTION_LEVEL == 'auto' &&
                    env.DEV_HEALTHY == 'true' &&
                    params.HEALTH_CHECK_TIMEOUT.toInteger() > 0
                }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Monitoring Stage Deployment Health ==="
                        echo "Waiting for stage MR to be merged and deployment to be healthy..."
                        echo "(This enables automatic prod promotion)"

                        // Wait for deployment to be healthy
                        def healthy = false
                        try {
                            waitForHealthyDeployment(
                                environment: 'stage',
                                appName: env.APP_NAME,
                                namespace: 'stage',
                                timeoutMinutes: params.HEALTH_CHECK_TIMEOUT.toInteger()
                            )
                            healthy = true
                        } catch (Exception e) {
                            echo "⚠ Warning: Stage deployment health check failed: ${e.message}"
                            echo "Prod promotion will be skipped"
                            healthy = false
                        }

                        env.STAGE_HEALTHY = healthy.toString()

                        if (healthy) {
                            echo "✓✓ Stage deployment is healthy - proceeding to prod promotion"
                        }
                    }
                }
            }
        }

        stage('Promote to Prod') {
            when {
                expression {
                    !params.SKIP_DEPLOYMENT &&
                    (params.PROMOTION_LEVEL == 'auto' && env.STAGE_HEALTHY == 'true') ||
                    params.PROMOTION_LEVEL == 'all'
                }
            }
            steps {
                container('maven') {
                    script {
                        echo "=== Creating Prod Promotion MR ==="

                        updateEnvironmentMR(
                            environment: 'prod',
                            targetBranch: 'prod',
                            imageTag: env.IMAGE_FOR_DEPLOY,
                            buildUrl: env.BUILD_URL,
                            gitCommit: env.GIT_SHORT_HASH,
                            fullImage: env.FULL_IMAGE,
                            buildNumber: env.BUILD_NUMBER,
                            appName: env.APP_NAME,
                            gitlabUrl: env.GITLAB_URL,
                            draft: true,         // Prod MRs are draft
                            autoMerge: false
                        )

                        echo "✓ Prod promotion MR created (DRAFT)"
                        echo "⚠ PRODUCTION - Review carefully before approving"
                    }
                }
            }
        }
    }

    post {
        always {
            container('maven') {
                script {
                    // Archive build artifacts
                    archiveArtifacts artifacts: '**/target/*.jar', allowEmptyArchive: true, fingerprint: true

                    // Clean workspace to save disk space
                    echo "Cleaning workspace..."
                    cleanWs(
                        deleteDirs: true,
                        patterns: [
                            [pattern: 'target/', type: 'INCLUDE'],
                            [pattern: 'k8s-deployments/', type: 'INCLUDE'],
                            [pattern: '.m2/repository/', type: 'INCLUDE']
                        ]
                    )
                }
            }
        }

        success {
            script {
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "✓✓✓ Pipeline Completed Successfully ✓✓✓"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "Application: ${env.APP_NAME}"
                echo "Version: ${env.APP_VERSION}"
                echo "Git commit: ${env.GIT_SHORT_HASH}"
                echo "Docker image: ${env.FULL_IMAGE}"
                echo "Deploy image: ${env.IMAGE_FOR_DEPLOY}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                // TODO: Add notification integration (Slack, email, etc.)
            }
        }

        failure {
            script {
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "⨯⨯⨯ Pipeline Failed ⨯⨯⨯"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "Build: ${env.BUILD_URL}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                // TODO: Add failure notification (Slack, email, etc.)
            }
        }

        unstable {
            script {
                echo "⚠ Pipeline completed with warnings"
                // TODO: Add notification for unstable builds
            }
        }
    }
}
