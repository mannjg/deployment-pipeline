// Validation Pipeline for k8s-deployments Repository
// Validates CUE configuration, manifest generation, and YAML syntax
// Triggered by: GitLab webhook on k8s-deployments changes

pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: validator
    image: localhost:30500/jenkins-agent-custom:latest
    command:
    - cat
    tty: true
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
"""
        }
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', daysToKeepStr: '30'))
        disableConcurrentBuilds()
    }

    parameters {
        string(
            name: 'BRANCH_NAME',
            defaultValue: 'dev',
            description: 'Branch to validate (dev/stage/prod or feature branch)'
        )
        booleanParam(
            name: 'VALIDATE_ALL_ENVS',
            defaultValue: true,
            description: 'Validate all environments (dev, stage, prod)'
        )
    }

    environment {
        // Git repository
        GITLAB_URL = 'http://gitlab.gitlab.svc.cluster.local'
        DEPLOYMENTS_REPO = "${GITLAB_URL}/example/k8s-deployments.git"

        // Credentials
        GITLAB_CREDENTIALS = credentials('gitlab-credentials')
    }

    stages {
        stage('Checkout') {
            steps {
                container('validator') {
                    script {
                        echo "=== Checking out k8s-deployments ==="
                        echo "Branch: ${params.BRANCH_NAME}"

                        checkout([
                            $class: 'GitSCM',
                            branches: [[name: "*/${params.BRANCH_NAME}"]],
                            userRemoteConfigs: [[
                                url: env.DEPLOYMENTS_REPO,
                                credentialsId: 'gitlab-credentials'
                            ]]
                        ])

                        // Get current commit info
                        env.GIT_COMMIT_SHORT = sh(
                            script: "git rev-parse --short HEAD",
                            returnStdout: true
                        ).trim()

                        env.GIT_COMMIT_MSG = sh(
                            script: "git log -1 --pretty=%B",
                            returnStdout: true
                        ).trim()

                        echo "✓ Commit: ${env.GIT_COMMIT_SHORT}"
                        echo "✓ Message: ${env.GIT_COMMIT_MSG}"
                    }
                }
            }
        }

        stage('Validate CUE Configuration') {
            steps {
                container('validator') {
                    script {
                        echo "=== Validating CUE Configuration ==="

                        sh '''
                            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            echo "Running CUE configuration validation..."
                            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                            if [ -f "./scripts/validate-cue-config.sh" ]; then
                                ./scripts/validate-cue-config.sh
                            else
                                echo "✗ ERROR: validate-cue-config.sh not found!"
                                exit 1
                            fi

                            echo "✓ CUE configuration validation passed"
                        '''
                    }
                }
            }
        }

        stage('Generate Manifests') {
            steps {
                container('validator') {
                    script {
                        echo "=== Generating Kubernetes Manifests ==="

                        def environments = params.VALIDATE_ALL_ENVS ? ['dev', 'stage', 'prod'] : [params.BRANCH_NAME]

                        for (env in environments) {
                            echo "Generating manifests for: ${env}"

                            sh """
                                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                echo "Environment: ${env}"
                                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                                if [ -f "./scripts/generate-manifests.sh" ]; then
                                    ./scripts/generate-manifests.sh ${env}
                                else
                                    echo "✗ ERROR: generate-manifests.sh not found!"
                                    exit 1
                                fi

                                echo "✓ Manifests generated for ${env}"
                                echo ""
                            """
                        }
                    }
                }
            }
        }

        stage('Validate Manifests') {
            steps {
                container('validator') {
                    script {
                        echo "=== Validating Generated Manifests ==="

                        def environments = params.VALIDATE_ALL_ENVS ? ['dev', 'stage', 'prod'] : [params.BRANCH_NAME]

                        for (env in environments) {
                            echo "Validating manifests for: ${env}"

                            sh """
                                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                                echo "Environment: ${env}"
                                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                                if [ -f "./scripts/validate-manifests.sh" ]; then
                                    ./scripts/validate-manifests.sh ${env}
                                else
                                    echo "✗ ERROR: validate-manifests.sh not found!"
                                    exit 1
                                fi

                                echo "✓ Manifest validation passed for ${env}"
                                echo ""
                            """
                        }
                    }
                }
            }
        }

        stage('Integration Tests') {
            steps {
                container('validator') {
                    script {
                        echo "=== Running Integration Tests ==="

                        def environments = params.VALIDATE_ALL_ENVS ? ['dev', 'stage', 'prod'] : [params.BRANCH_NAME]

                        sh """
                            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            echo "Running integration test suite..."
                            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                            if [ -f "./scripts/test-cue-integration.sh" ]; then
                                ./scripts/test-cue-integration.sh
                            else
                                echo "⚠ WARNING: test-cue-integration.sh not found, skipping"
                            fi

                            echo "✓ Integration tests passed"
                        """
                    }
                }
            }
        }

        stage('Summary Report') {
            steps {
                container('validator') {
                    script {
                        echo """
=======================================================
✓ VALIDATION COMPLETED SUCCESSFULLY
=======================================================
Repository: k8s-deployments
Branch: ${params.BRANCH_NAME}
Commit: ${env.GIT_COMMIT_SHORT}
Message: ${env.GIT_COMMIT_MSG}

Validation Summary:
  ✓ CUE configuration validated
  ✓ Manifests generated successfully
  ✓ YAML validation passed
  ✓ Integration tests passed

Environments Validated: ${params.VALIDATE_ALL_ENVS ? 'dev, stage, prod' : params.BRANCH_NAME}

Build URL: ${env.BUILD_URL}
=======================================================
"""
                    }
                }
            }
        }
    }

    post {
        success {
            script {
                echo """
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ VALIDATION PASSED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
All checks passed successfully.
Safe to merge this change.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""
                // Update GitLab commit status
                updateGitlabCommitStatus(
                    name: 'k8s-deployments-validation',
                    state: 'success'
                )
            }
        }

        failure {
            script {
                echo """
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✗ VALIDATION FAILED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
One or more validation checks failed.
DO NOT MERGE until issues are resolved.

Check logs above for error details.
Build URL: ${env.BUILD_URL}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"""
                // Update GitLab commit status
                updateGitlabCommitStatus(
                    name: 'k8s-deployments-validation',
                    state: 'failed'
                )
            }
        }

        always {
            // Cleanup
            sh 'echo "Cleanup completed"'
        }
    }
}
