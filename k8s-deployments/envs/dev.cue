// Development environment configuration
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
	"deployments.local/k8s-deployments/argocd"
)

// Development environment settings for example-app
dev: exampleApp: apps.exampleApp & {
	// Override namespace for dev
	appConfig: {
		namespace: "dev"

		labels: {
			environment: "dev"
			managed_by: "argocd"
		}

		// Enable debug mode in dev
		debug: true

		// Deployment configuration
		deployment: {
			// Image will be updated by CI/CD pipeline
			image: "docker.local/example/example-app:1.0.0-SNAPSHOT-b4b8889"

			// Lower replicas in dev
			replicas: 1

			// Resource limits for dev
			resources: {
				requests: {
					cpu: "100m"
					memory: "256Mi"
				}
				limits: {
					cpu: "500m"
					memory: "512Mi"
				}
			}

			// Health probes
			livenessProbe: {
				httpGet: {
					path: "/health/live"
					port: 8080
				}
				initialDelaySeconds: 10
				periodSeconds: 10
			}

			readinessProbe: {
				httpGet: {
					path: "/health/ready"
					port: 8080
				}
				initialDelaySeconds: 10
				periodSeconds: 10
			}

			// Dev-specific environment variables
			additionalEnv: [
				{
					name: "QUARKUS_LOG_LEVEL"
					value: "DEBUG"
				},
				{
					name: "ENVIRONMENT"
					value: "dev"
				},
			]
		}

		// ConfigMap data for development environment
		configMap: {
			data: {
				"redis-url": "redis://redis.dev.svc.cluster.local:6379"
				"log-level": "debug"
				"feature-flags": "experimental-features=true"
			}
		}
	}
}

// ArgoCD Application configuration for dev environment
dev: argoApp: argocd.#ArgoApplication & {
	argoConfig: {
		app:         "example-app"
		environment: "dev"
		namespace:   "dev"

		// Git source configuration
		repoURL:        "\(argocd.#DefaultGitLabRepoBase)/example/k8s-deployments.git"
		targetRevision: "dev"
		path:           "manifests/dev"

		// Use default sync policy and ignore differences
		syncPolicy:        argocd.#DefaultSyncPolicy
		ignoreDifferences: argocd.#DefaultIgnoreDifferences
	}
}
