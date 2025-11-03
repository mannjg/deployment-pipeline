#!/usr/bin/env groovy
// Git operations helper - provides clean, secure git operations without force pushes

def setupCredentials() {
    /*
     * Configure git for Jenkins CI operations
     * Uses credential helper instead of storing credentials in files
     */
    sh '''
        git config --global user.name "Jenkins CI"
        git config --global user.email "jenkins@local"
    '''
}

def cloneDeploymentRepo(String repoUrl, String targetDir = 'k8s-deployments') {
    /*
     * Clone deployment repository using Jenkins credentials
     * Uses git credential helper from withCredentials block
     */
    withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                      usernameVariable: 'GIT_USERNAME',
                                      passwordVariable: 'GIT_PASSWORD')]) {
        sh """
            # Remove existing directory if present
            rm -rf ${targetDir}

            # Use git credential helper (more secure than writing to file)
            git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

            # Clone repository
            git clone ${repoUrl} ${targetDir}

            # Clear credential helper after use
            git config --global --unset credential.helper
        """
    }
}

def deleteBranchIfExists(String branchName, String workDir = '.') {
    /*
     * Safely delete a branch both locally and remotely if it exists
     * No errors if branch doesn't exist
     */
    withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                      usernameVariable: 'GIT_USERNAME',
                                      passwordVariable: 'GIT_PASSWORD')]) {
        sh """
            cd ${workDir}

            # Setup credential helper temporarily
            git config --local credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

            # Delete remote branch if exists
            git push origin --delete ${branchName} 2>/dev/null || echo "Remote branch ${branchName} does not exist (this is fine)"

            # Delete local branch if exists
            git branch -D ${branchName} 2>/dev/null || echo "Local branch ${branchName} does not exist (this is fine)"

            # Clean up credential helper
            git config --local --unset credential.helper || true
        """
    }
}

def pushBranch(String branchName, String workDir = '.') {
    /*
     * Push branch to remote (NO force push!)
     * Fails if there are conflicts - this is intentional for safety
     */
    withCredentials([usernamePassword(credentialsId: 'gitlab-credentials',
                                      usernameVariable: 'GIT_USERNAME',
                                      passwordVariable: 'GIT_PASSWORD')]) {
        sh """
            cd ${workDir}

            # Setup credential helper temporarily
            git config --local credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'

            # Push branch (will fail on conflicts - this is good!)
            git push -u origin ${branchName}

            # Clean up credential helper
            git config --local --unset credential.helper || true

            echo "✓ Successfully pushed ${branchName}"
        """
    }
}

def checkoutAndUpdate(String branchName, String workDir = '.') {
    /*
     * Fetch, checkout, and update a branch to latest
     */
    sh """
        cd ${workDir}

        # Fetch latest changes
        git fetch origin ${branchName}

        # Checkout branch
        git checkout ${branchName}

        # Pull latest changes
        git pull origin ${branchName}

        echo "✓ Checked out and updated ${branchName}"
    """
}
