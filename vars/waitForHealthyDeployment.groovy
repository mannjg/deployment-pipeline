#!/usr/bin/env groovy
// Wait for ArgoCD application to sync and Kubernetes deployment to be healthy
// This enables intelligent promotion workflow

def call(Map config) {
    /*
     * Monitor deployment health across ArgoCD and Kubernetes
     *
     * Parameters:
     *   environment: 'dev', 'stage', or 'prod'
     *   appName: Application name (e.g., 'example-app')
     *   namespace: Kubernetes namespace (usually same as environment)
     *   timeoutMinutes: Maximum time to wait (default: 10)
     *   argocdUrl: ArgoCD server URL (optional, uses port-forward if not provided)
     *   pollIntervalSeconds: How often to check status (default: 15)
     */

    def env = config.environment
    def appName = config.appName
    def namespace = config.namespace ?: env
    def timeoutMinutes = config.timeoutMinutes ?: 10
    def argocdUrl = config.argocdUrl ?: null
    def pollInterval = config.pollIntervalSeconds ?: 15

    echo "=== Monitoring ${env} deployment health ==="
    echo "Application: ${appName}"
    echo "Namespace: ${namespace}"
    echo "Timeout: ${timeoutMinutes} minutes"

    def startTime = System.currentTimeMillis()
    def timeoutMs = timeoutMinutes * 60 * 1000
    def argoAppName = "${appName}-${env}"

    while (true) {
        def elapsed = System.currentTimeMillis() - startTime
        if (elapsed > timeoutMs) {
            error("⨯ Deployment health check timed out after ${timeoutMinutes} minutes")
        }

        echo "Checking deployment status (${elapsed/1000}s elapsed)..."

        try {
            // Step 1: Check ArgoCD sync status
            def argoSynced = checkArgocdSync(argoAppName, argocdUrl)

            if (!argoSynced) {
                echo "⧗ Waiting for ArgoCD to sync ${argoAppName}..."
                sleep(pollInterval)
                continue
            }

            echo "✓ ArgoCD application ${argoAppName} is synced"

            // Step 2: Check Kubernetes deployment health
            def k8sHealthy = checkKubernetesHealth(appName, namespace)

            if (!k8sHealthy) {
                echo "⧗ Waiting for Kubernetes deployment to be healthy..."
                sleep(pollInterval)
                continue
            }

            echo "✓ Kubernetes deployment ${appName} is healthy in ${namespace}"

            // Step 3: Verify pods are actually running
            def podsReady = checkPodsReady(appName, namespace)

            if (!podsReady) {
                echo "⧗ Waiting for pods to be ready..."
                sleep(pollInterval)
                continue
            }

            echo "✓ All pods are ready and running"

            // All checks passed!
            echo "✓✓✓ Deployment is fully healthy in ${env} environment"
            return true

        } catch (Exception e) {
            echo "⚠ Health check error: ${e.message}"
            echo "Retrying in ${pollInterval} seconds..."
            sleep(pollInterval)
        }
    }
}

// Check if ArgoCD application is synced
def checkArgocdSync(String appName, String argocdUrl) {
    try {
        def result
        if (argocdUrl) {
            // Use ArgoCD API if URL provided
            result = sh(
                script: """
                    argocd app get ${appName} --output json | jq -r '.status.sync.status' || echo "Unknown"
                """,
                returnStdout: true
            ).trim()
        } else {
            // Use kubectl to check ArgoCD application resource
            result = sh(
                script: """
                    kubectl get application ${appName} -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown"
                """,
                returnStdout: true
            ).trim()
        }

        echo "ArgoCD sync status: ${result}"
        return result == "Synced"

    } catch (Exception e) {
        echo "Warning: Could not check ArgoCD status: ${e.message}"
        // If ArgoCD check fails, fall back to K8s-only check
        return true
    }
}

// Check if Kubernetes deployment is healthy
def checkKubernetesHealth(String appName, String namespace) {
    try {
        // Check deployment status
        def result = sh(
            script: """
                kubectl get deployment ${appName} -n ${namespace} -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown"
            """,
            returnStdout: true
        ).trim()

        echo "Deployment Available status: ${result}"

        if (result != "True") {
            return false
        }

        // Check if desired replicas match ready replicas
        def replicas = sh(
            script: """
                kubectl get deployment ${appName} -n ${namespace} -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0"
            """,
            returnStdout: true
        ).trim()

        def readyReplicas = sh(
            script: """
                kubectl get deployment ${appName} -n ${namespace} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"
            """,
            returnStdout: true
        ).trim()

        echo "Replicas: ${readyReplicas}/${replicas}"

        return replicas == readyReplicas && replicas != "0"

    } catch (Exception e) {
        echo "Warning: Could not check deployment status: ${e.message}"
        return false
    }
}

// Check if pods are ready
def checkPodsReady(String appName, String namespace) {
    try {
        // Get pod status - all should be Running
        def runningPods = sh(
            script: """
                kubectl get pods -n ${namespace} -l app=${appName} --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l
            """,
            returnStdout: true
        ).trim().toInteger()

        def totalPods = sh(
            script: """
                kubectl get pods -n ${namespace} -l app=${appName} --no-headers 2>/dev/null | wc -l
            """,
            returnStdout: true
        ).trim().toInteger()

        echo "Running pods: ${runningPods}/${totalPods}"

        if (totalPods == 0) {
            echo "Warning: No pods found for ${appName}"
            return false
        }

        if (runningPods != totalPods) {
            return false
        }

        // Check readiness probes
        def readyContainers = sh(
            script: """
                kubectl get pods -n ${namespace} -l app=${appName} -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "false"
            """,
            returnStdout: true
        ).trim()

        echo "Container ready statuses: ${readyContainers}"

        // All containers should be ready (no "false" in the output)
        return !readyContainers.contains("false")

    } catch (Exception e) {
        echo "Warning: Could not check pod status: ${e.message}"
        return false
    }
}
