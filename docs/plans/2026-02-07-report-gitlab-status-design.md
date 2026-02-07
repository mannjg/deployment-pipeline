# JENKINS-02: Add reportGitLabStatus Helper

## Summary

Extract repeated GitLab commit status curl blocks into a `reportGitLabStatus(state, context, commitSha, projectPath)` helper. Duplicated in both Jenkinsfiles (matches existing pattern for `withGitCredentials` and `validateRequiredEnvVars`).

## Helper

```groovy
def reportGitLabStatus(String state, String context, String commitSha, String projectPath) {
    def descriptions = [
        'pending': 'Pipeline running',
        'success': 'Pipeline passed',
        'failed' : 'Pipeline failed',
    ]
    def description = descriptions[state] ?: state
    def encodedProject = projectPath.replace('/', '%2F')

    withCredentials([string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN')]) {
        sh """
            curl -s -X POST \
                -H "PRIVATE-TOKEN: \${GITLAB_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{"state": "${state}", "description": "${description}", "context": "${context}"}' \
                "${env.GITLAB_URL}/api/v4/projects/${encodedProject}/statuses/${commitSha}" \
                || echo "Could not update commit status (non-fatal)"
        """
    }
}
```

- `withCredentials` handled internally
- URL-encoding of `/` in project path handled by helper
- `|| echo` preserves non-fatal behavior
- Description derived from static map (no 5th parameter needed)

## Call Sites

### example-app/Jenkinsfile (3 instances)

| Location | State | commitSha | projectPath |
|----------|-------|-----------|-------------|
| Checkout & Setup | `pending` | `env.GIT_COMMIT_SHA` | `"${env.GITLAB_GROUP ?: 'p2c'}/example-app"` |
| post.success | `success` | `env.GIT_COMMIT_SHA` | `"${env.GITLAB_GROUP ?: 'p2c'}/example-app"` |
| post.failure | `failed` | `env.GIT_COMMIT_SHA` | `"${env.GITLAB_GROUP ?: 'p2c'}/example-app"` |

### k8s-deployments/Jenkinsfile (2 instances)

| Location | State | commitSha | projectPath |
|----------|-------|-----------|-------------|
| post.success | `success` | `env.FINAL_COMMIT_SHA ?: env.ORIGINAL_COMMIT_SHA` | `"${env.GITLAB_GROUP ?: 'p2c'}/k8s-deployments"` |
| post.failure | `failed` | `env.FINAL_COMMIT_SHA ?: env.ORIGINAL_COMMIT_SHA` | `"${env.GITLAB_GROUP ?: 'p2c'}/k8s-deployments"` |

Note: k8s-deployments moves the `FINAL_COMMIT_SHA ?: ORIGINAL_COMMIT_SHA` ternary from shell-level to Groovy-level at the call site.

## No Behavioral Change

- Same curl command, same headers, same error handling
- Same credential ID (`gitlab-api-token-secret`)
- Same project path construction (just URL-encoded inside helper)
