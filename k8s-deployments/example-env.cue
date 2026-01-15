// Example environment configuration
//
// Copy this file to env.cue in your environment branch and customize:
// 1. Replace <ENV> with your environment name (dev, stage, prod)
// 2. Adjust resource limits, replicas, and settings for your environment
// 3. Update the image tag (CI/CD will manage this after initial setup)
//
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
)

// Example: Development environment settings for example-app
// Change "dev" to your environment name (dev, stage, prod)
dev: exampleApp: apps.exampleApp & {
	appConfig: {
		// Namespace matches environment name
		namespace: "dev"

		labels: {
			environment: "dev"
			managed_by:  "argocd"
		}

		// Enable debug mode in non-prod environments
		debug: true

		deployment: {
			// Image will be updated by CI/CD pipeline
			// Initial value should be a valid image tag
			image: "REGISTRY_URL_NOT_SET/example/example-app:IMAGE_TAG_NOT_SET"

			// Adjust replicas per environment:
			// - dev: 1
			// - stage: 2
			// - prod: 3+
			replicas: 1

			// Resource limits - scale up for prod
			resources: {
				requests: {
					cpu:    "100m"
					memory: "256Mi"
				}
				limits: {
					cpu:    "500m"
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
				periodSeconds:       10
			}

			readinessProbe: {
				httpGet: {
					path: "/health/ready"
					port: 8080
				}
				initialDelaySeconds: 10
				periodSeconds:       10
			}

			// Environment-specific variables
			additionalEnv: [
				{
					name:  "QUARKUS_LOG_LEVEL"
					value: "DEBUG" // Use INFO for prod
				},
				{
					name:  "ENVIRONMENT"
					value: "dev"
				},
			]
		}

		// ConfigMap data
		configMap: {
			data: {
				"redis-url":     "redis://redis.dev.svc.cluster.local:6379"
				"log-level":     "debug"
				"feature-flags": "experimental-features=true"
			}
		}
	}
}

// Example: Development environment settings for postgres
dev: postgres: apps.postgres & {
	appConfig: {
		namespace: "dev"

		labels: {
			environment: "dev"
			managed_by:  "argocd"
		}

		deployment: {
			image: "postgres:16-alpine"

			replicas: 1

			resources: {
				requests: {
					cpu:    "100m"
					memory: "256Mi"
				}
				limits: {
					cpu:    "500m"
					memory: "512Mi"
				}
			}

			livenessProbe: {
				exec: {
					command: ["pg_isready", "-U", "postgres"]
				}
				initialDelaySeconds: 30
				periodSeconds:       10
				timeoutSeconds:      5
				failureThreshold:    3
			}

			readinessProbe: {
				exec: {
					command: ["pg_isready", "-U", "postgres"]
				}
				initialDelaySeconds: 10
				periodSeconds:       5
				timeoutSeconds:      3
				failureThreshold:    3
			}

			additionalEnv: [
				{
					name:  "ENVIRONMENT"
					value: "dev"
				},
			]
		}

		storage: {
			enablePVC: true
			pvc: {
				// Scale storage per environment:
				// - dev: 5Gi
				// - stage: 20Gi
				// - prod: 50Gi+
				storageSize: "5Gi"
			}
		}
	}
}
