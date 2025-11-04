#!/usr/bin/env groovy
// Shared library function for updating environment configuration and creating MR
// This eliminates code duplication across dev/stage/prod deployment stages

def call(Map config) {
    /*
     * Update environment CUE configuration and create GitLab Merge Request
     *
     * Parameters:
     *   environment: 'dev', 'stage', or 'prod'
     *   targetBranch: Git branch to merge into (usually same as environment)
     *   imageTag: Full image reference to deploy (e.g., docker.local/example/example-app:1.0.0-abc123)
     *   buildUrl: Jenkins build URL for tracking
     *   gitCommit: Short git commit hash
     *   fullImage: Full image name for documentation
     *   draft: (optional) Create as draft MR (default: false)
     *   autoMerge: (optional) Auto-merge the MR (default: false, only for dev)
     *   buildNumber: Jenkins build number for unique branch names
     */

    def env = config.environment
    def targetBranch = config.targetBranch
    def imageTag = config.imageTag
    def buildUrl = config.buildUrl
    def gitCommit = config.gitCommit
    def fullImage = config.fullImage
    def draft = config.draft ?: false
    def autoMerge = config.autoMerge ?: false
    def buildNumber = config.buildNumber
    def appName = config.appName

    echo "=== Updating ${env} environment ==="
    echo "Target branch: ${targetBranch}"
    echo "Image: ${imageTag}"
    echo "Draft MR: ${draft}"
    echo "Auto-merge: ${autoMerge}"

    // Use unique branch names to avoid conflicts
    def featureBranch = "${env == 'dev' ? 'update' : 'promote'}-${env}-${buildNumber}"

    withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                      usernameVariable: 'GIT_USERNAME',
                                      passwordVariable: 'GIT_PASSWORD')]) {

        // Fetch and checkout target branch
        sh """
            cd k8s-deployments

            # Clean up any existing branch with same name
            git push origin --delete ${featureBranch} || echo "Branch ${featureBranch} does not exist remotely"
            git branch -D ${featureBranch} || echo "Branch ${featureBranch} does not exist locally"

            # Fetch and checkout target branch
            git fetch origin ${targetBranch}
            git checkout ${targetBranch}
            git pull origin ${targetBranch}

            # Create feature branch from target branch
            git checkout -b ${featureBranch}
        """

        // Update CUE file and generate manifests
        sh """
            cd k8s-deployments

            # Update the image reference in the environment CUE file
            sed -i 's|image: ".*"|image: "${imageTag}"|' envs/${env}.cue

            # Verify the change
            echo "Updated image in envs/${env}.cue:"
            grep 'image:' envs/${env}.cue || (echo "ERROR: Failed to update image in CUE file" && exit 1)

            # Generate Kubernetes manifests from CUE
            if [ ! -f scripts/generate-manifests.sh ]; then
                echo "ERROR: scripts/generate-manifests.sh not found"
                exit 1
            fi

            bash scripts/generate-manifests.sh ${env}

            # Verify manifests were generated
            if [ ! -d manifests/${env} ] || [ -z "\$(ls -A manifests/${env})" ]; then
                echo "ERROR: Manifest generation failed - no manifests found in manifests/${env}/"
                exit 1
            fi

            echo "✓ Manifests generated successfully"
            ls -lh manifests/${env}/
        """

        // Commit changes
        def commitMsg = env == 'dev' ? "Update ${appName} to ${gitCommit}" : "Promote ${appName} to ${env}: ${gitCommit}"
        sh """
            cd k8s-deployments

            # Stage all changes (CUE file + generated manifests)
            git add envs/${env}.cue manifests/${env}/

            # Check if there are changes to commit
            if git diff --cached --quiet; then
                echo "⚠ No changes to commit - image may already be at this version"
                exit 0
            fi

            # Commit with detailed metadata
            git commit -m "${commitMsg}

Triggered by: ${buildUrl}
Git commit: ${gitCommit}
Image: ${fullImage}
Environment: ${env}

Generated manifests from CUE configuration"
        """

        // Push feature branch (no force push!)
        sh """
            cd k8s-deployments

            # Push feature branch
            git push -u origin ${featureBranch}

            echo "✓ Pushed branch: ${featureBranch}"
        """

        // Create GitLab MR
        withCredentials([string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN')]) {
            def mrTitle = env == 'dev' ?
                "Deploy ${appName} to ${env}: ${gitCommit}" :
                "Promote ${appName} to ${env}: ${gitCommit}"

            def mrDescription = generateMRDescription(env, appName, gitCommit, buildUrl, fullImage, imageTag)

            sh """
                cd k8s-deployments

                # Export variables for MR creation script
                export GITLAB_TOKEN="${GITLAB_TOKEN}"
                export GITLAB_URL="${config.gitlabUrl}"
                export MR_DRAFT="${draft}"
                export AUTO_MERGE="${autoMerge}"

                # Create MR using script or inline API call
                if [ -f scripts/create-gitlab-mr.sh ]; then
                    bash scripts/create-gitlab-mr.sh \\
                        "${featureBranch}" \\
                        "${targetBranch}" \\
                        "${mrTitle}" \\
                        "${mrDescription}"
                else
                    # Inline GitLab API call as fallback
                    echo "Creating MR via GitLab API..."
                    PROJECT_ID="example%2Fk8s-deployments"

                    MR_DATA=\$(cat <<JSON_DATA
{
  "source_branch": "${featureBranch}",
  "target_branch": "${targetBranch}",
  "title": "${mrTitle}",
  "description": "${mrDescription}",
  "remove_source_branch": true
}
JSON_DATA
)

                    if [ "${draft}" = "true" ]; then
                        MR_DATA=\$(echo "\$MR_DATA" | sed 's/}/, "draft": true}/')
                    fi

                    curl -X POST \\
                        -H "PRIVATE-TOKEN: \${GITLAB_TOKEN}" \\
                        -H "Content-Type: application/json" \\
                        -d "\${MR_DATA}" \\
                        "\${GITLAB_URL}/api/v4/projects/\${PROJECT_ID}/merge_requests" \\
                        || (echo "ERROR: Failed to create MR" && exit 1)
                fi

                echo "✓ Created MR: ${featureBranch} → ${targetBranch}"
            """
        }
    }

    echo "✓ Successfully created ${env} environment MR"
    return featureBranch
}

// Generate MR description based on environment
def generateMRDescription(String env, String appName, String gitCommit, String buildUrl, String fullImage, String imageTag) {
    def action = env == 'dev' ? 'Deployment' : 'Promotion'
    def fromEnv = env == 'stage' ? 'dev' : (env == 'prod' ? 'stage' : '')

    def description = """## Automatic ${action} to ${env.capitalize()}

**Application**: ${appName}
**Image Tag**: ${imageTag}
**Build**: ${buildUrl}
**Git Commit**: ${gitCommit}

### Changes

This merge request updates the ${env} environment${fromEnv ? " with the image currently deployed in ${fromEnv}" : " with the latest build"}.

**Image**: ${fullImage}

### Review Checklist

- [ ] Image tag is correct
- [ ] CUE configuration updated
- [ ] Manifests regenerated successfully
- [ ] Ready to deploy to ${env}

### Deployment

Once merged, ArgoCD will automatically deploy to the ${env} namespace.
"""

    if (env == 'prod') {
        description += "\n⚠️ **Production Deployment** - Please review carefully before merging.\n"
    }

    description += "\n---\n*Generated by Jenkins CI/CD Pipeline*"

    return description
}
