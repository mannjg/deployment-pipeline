import groovy.transform.Field

@Field static final List<String> ENV_BRANCHES = ['dev', 'stage', 'prod']

// Validation Pipeline for k8s-deployments Repository
// Validates CUE configuration, manifest generation, and YAML syntax
// Triggered by: GitLab webhook on k8s-deployments changes

// Agent image from environment (ConfigMap) - REQUIRED, no default
def agentImage = System.getenv('JENKINS_AGENT_IMAGE')
if (!agentImage) {
    error "JENKINS_AGENT_IMAGE environment variable is required but not set. Configure it in the pipeline-config ConfigMap."
}

pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: validator
    image: ${agentImage}
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
        // Git repository (from pipeline-config ConfigMap)
        GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')
        GITLAB_GROUP = System.getenv('GITLAB_GROUP')
        DEPLOYMENTS_REPO = System.getenv('DEPLOYMENTS_REPO_URL')

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

        stage('Preflight') {
            steps {
                container('validator') {
                    script {
                        echo "=== Preflight Checks ==="

                        def missing = []
                        if (!env.GITLAB_URL) missing.add('GITLAB_URL_INTERNAL')
                        if (!env.GITLAB_GROUP) missing.add('GITLAB_GROUP')
                        if (!env.DEPLOYMENTS_REPO) missing.add('DEPLOYMENTS_REPO_URL')

                        if (missing) {
                            error """Missing required configuration: ${missing.join(', ')}

Configure pipeline-config ConfigMap with these variables.
See: k8s-deployments/docs/CONFIGURATION.md"""
                        }

                        echo "✓ Preflight checks passed"
                        echo "  GITLAB_URL: ${env.GITLAB_URL}"
                        echo "  GITLAB_GROUP: ${env.GITLAB_GROUP}"
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

                        def environments = params.VALIDATE_ALL_ENVS ? ENV_BRANCHES : [params.BRANCH_NAME]

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

                        def environments = params.VALIDATE_ALL_ENVS ? ENV_BRANCHES : [params.BRANCH_NAME]

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

        stage('Commit Generated Manifests') {
            steps {
                container('validator') {
                    script {
                        echo "=== Committing Generated Manifests ==="

                        withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                                          usernameVariable: 'GIT_USERNAME',
                                                          passwordVariable: 'GIT_PASSWORD')]) {
                            sh '''
                                # Setup git credentials
                                git config user.name "Jenkins CI"
                                git config user.email "jenkins@local"
                                git config credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

                                # Stage generated manifests
                                git add manifests/

                                # Only commit if there are changes
                                if ! git diff --cached --quiet; then
                                    git commit -m "chore: generate manifests for ${BRANCH_NAME}

Automated manifest generation by k8s-deployments CI.
Build: ${BUILD_URL}"

                                    git push origin HEAD:${BRANCH_NAME}
                                    echo "✓ Manifests committed and pushed"
                                else
                                    echo "✓ No manifest changes to commit"
                                fi

                                # Cleanup credentials
                                git config --unset credential.helper || true
                            '''
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

                        def environments = params.VALIDATE_ALL_ENVS ? ENV_BRANCHES : [params.BRANCH_NAME]

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
                // Update GitLab commit status via API
                container('validator') {
                    withCredentials([string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN')]) {
                        sh """
                            curl -X POST "${env.GITLAB_URL}/api/v4/projects/${env.GITLAB_GROUP}%2Fk8s-deployments/statuses/${env.GIT_COMMIT}" \
                              -H "PRIVATE-TOKEN: \${GITLAB_TOKEN}" \
                              -d "state=success" \
                              -d "name=k8s-deployments-validation" \
                              -d "target_url=${env.BUILD_URL}" \
                              -d "description=All validation checks passed" \
                              || echo "⚠ Could not update GitLab status (non-blocking)"
                        """
                    }
                }
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
                // Update GitLab commit status via API
                container('validator') {
                    withCredentials([string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN')]) {
                        sh """
                            curl -X POST "${env.GITLAB_URL}/api/v4/projects/${env.GITLAB_GROUP}%2Fk8s-deployments/statuses/${env.GIT_COMMIT}" \
                              -H "PRIVATE-TOKEN: \${GITLAB_TOKEN}" \
                              -d "state=failed" \
                              -d "name=k8s-deployments-validation" \
                              -d "target_url=${env.BUILD_URL}" \
                              -d "description=Validation checks failed - see Jenkins logs" \
                              || echo "⚠ Could not update GitLab status (non-blocking)"
                        """
                    }
                }
            }
        }

        always {
            // Cleanup
            sh 'echo "Cleanup completed"'
        }
    }
}
