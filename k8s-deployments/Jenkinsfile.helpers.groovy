/**
 * Configures git credentials and identity, executes body, then cleans up.
 * Uses local git config when repoDir is provided (preferred), falls back to --global.
 * @param repoDir Optional directory for local git config scope. If null/empty, uses --global.
 * @param body Closure to execute with credentials configured
 */
def withGitCredentials(String repoDir = null, Closure body) {
    def gitCmd = 'git config --global'
    if (repoDir?.trim()) {
        if (!fileExists(repoDir)) {
            error "withGitCredentials: repoDir '${repoDir}' does not exist"
        }
        gitCmd = "git -C ${repoDir} config"
    }
    try {
        sh """
            ${gitCmd} user.name 'Jenkins CI'
            ${gitCmd} user.email 'jenkins@local'
            ${gitCmd} credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "\${GIT_USERNAME}" "\${GIT_PASSWORD}"; }; f'
        """
        body()
    } finally {
        // No cleanup needed: Jenkins agents are ephemeral Kubernetes pods
        // destroyed after each build. Credentials die with the pod.
    }
}

/**
 * Validates that all listed environment variables are set.
 * Fails the build with a clear message listing all missing variables.
 * @param vars List of environment variable names to check
 */
def validateRequiredEnvVars(List<String> vars) {
    def missing = vars.findAll { !env."${it}" }
    if (missing) {
        error "Missing required pipeline environment variables: ${missing.join(', ')}. Check pipeline-config ConfigMap in Jenkins namespace."
    }
}

/**
 * Reports commit status to GitLab. Non-fatal on failure.
 * @param state GitLab commit status state (pending, success, failed)
 * @param context Status context name (e.g., "jenkins/k8s-deployments")
 * @param commitSha Full git commit SHA to report status for
 * @param projectPath GitLab project path (e.g., "p2c/k8s-deployments")
 */
def reportGitLabStatus(String state, String context, String commitSha, String projectPath) {
    def descriptions = [
        'pending': 'Pipeline running',
        'success': 'Pipeline passed',
        'failed' : 'Pipeline failed',
    ]
    def description = descriptions[state] ?: state
    def encodedProject = projectPath.replace('/', '%2F')
    def payload = groovy.json.JsonOutput.toJson([
        state: state,
        description: description,
        context: context
    ])

    withCredentials([string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN')]) {
        try {
            gitlabApiRequest('POST',
                "${env.GITLAB_URL}/api/v4/projects/${encodedProject}/statuses/${commitSha}",
                payload
            )
        } catch (Exception e) {
            echo "Could not update commit status (non-fatal)"
        }
    }
}

/**
 * Reads agent image from system environment at parse time and fails if missing.
 * @param envVarName Name of env var to read
 * @return Agent image string
 */
def getAgentImageOrFail(String envVarName = 'JENKINS_AGENT_IMAGE') {
    def agentImage = System.getenv(envVarName)
    if (!agentImage) {
        error "${envVarName} not set - check pipeline-config ConfigMap"
    }
    return agentImage
}

/**
 * Returns the Kubernetes pod template YAML for the pipeline agent.
 * Keeping this centralized avoids drift across Jenkinsfiles.
 */
def podTemplateYaml(String agentImage) {
    return """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: pipeline
    image: ${agentImage}
    command:
    - cat
    tty: true
    env:
    - name: DOCKER_HOST
      value: tcp://localhost:2375
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
  - name: dind
    image: docker:dind
    securityContext:
      privileged: true
    env:
    - name: DOCKER_TLS_CERTDIR
      value: ""
    args:
    - --insecure-registry=${env.CONTAINER_REGISTRY_EXTERNAL?.replaceAll('^https?://', '')}
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "2Gi"
        cpu: "1000m"
"""
}

/**
 * Returns a workspace-scoped temp file path using the build number.
 */
def tempFilePath(String baseName, String suffix = '') {
    return "${env.WORKSPACE}/.${baseName}-${env.BUILD_NUMBER}${suffix}"
}

/**
 * Cleans up workspace-scoped temp files by glob.
 */
def cleanupWorkspaceFiles(List<String> globs) {
    if (!globs || globs.isEmpty()) {
        return
    }
    def patterns = globs.collect { "${env.WORKSPACE}/${it}" }.join(' ')
    sh """
        rm -f ${patterns} || true
    """
}

/**
 * Performs a GitLab API request with standard headers.
 * @param method HTTP method (GET, POST, PUT, DELETE)
 * @param url Full GitLab API URL
 * @param jsonPayload Optional JSON payload (string)
 * @return Response body (trimmed)
 */
def gitlabApiRequest(String method, String url, String jsonPayload = null) {
    def payloadFile = null
    def dataArg = ''
    if (jsonPayload) {
        payloadFile = tempFilePath('gitlab-payload', '.json')
        writeFile file: payloadFile, text: jsonPayload
        dataArg = "-H \"Content-Type: application/json\" -d @${payloadFile}"
    }

    def response = sh(
        script: "curl -sf -X ${method} -H \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\" ${dataArg} \"${url}\"",
        returnStdout: true
    ).trim()

    if (payloadFile) {
        sh "rm -f \"${payloadFile}\" || true"
    }

    return response
}

return this
