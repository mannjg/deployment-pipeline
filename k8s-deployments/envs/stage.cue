// Staging environment configuration
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
	"deployments.local/k8s-deployments/argocd"
)

// Staging environment settings for example-app
stage: exampleApp: apps.exampleApp & {
	// Override namespace for stage
	appConfig: {
		namespace: "stage"

		labels: {
			environment: "stage"
			managed_by: "argocd"
		}

		// Enable debug mode in stage (for troubleshooting)
		debug: true

		// Deployment configuration
		deployment: {
			// Image will be updated by CI/CD pipeline
			image: "docker.local/example/example-app:1.0.0-SNAPSHOT"

			// More replicas in stage
			replicas: 2

			// Higher resource limits for stage
			resources: {
				requests: {
					cpu: "200m"
					memory: "512Mi"
				}
				limits: {
					cpu: "1000m"
					memory: "1Gi"
				}
			}

			// Health probes
			livenessProbe: {
				httpGet: {
					path: "/health/live"
					port: 8080
				}
				initialDelaySeconds: 15
				periodSeconds: 10
			}

			readinessProbe: {
				httpGet: {
					path: "/health/ready"
					port: 8080
				}
				initialDelaySeconds: 15
				periodSeconds: 10
			}

			// Stage-specific environment variables
			additionalEnv: [
				{
					name: "QUARKUS_LOG_LEVEL"
					value: "INFO"
				},
				{
					name: "ENVIRONMENT"
					value: "stage"
				},
			]
		}
	}
}

// ArgoCD Application configuration for stage environment
stage: argoApp: argocd.#ArgoApplication & {
	argoConfig: {
		app:         "example-app"
		environment: "stage"
		namespace:   "stage"

		// Git source configuration
		repoURL:        "\(argocd.#DefaultGitLabRepoBase)/example/k8s-deployments.git"
		targetRevision: "stage"
		path:           "manifests/stage"

		// Use default sync policy and ignore differences
		syncPolicy:        argocd.#DefaultSyncPolicy
		ignoreDifferences: argocd.#DefaultIgnoreDifferences
	}
}
