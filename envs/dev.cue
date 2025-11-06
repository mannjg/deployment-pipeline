// Development environment configuration
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
)

// Development environment settings for example-app
dev: exampleApp: apps.exampleApp & {
	// Override namespace for dev
	appConfig: {
		namespace: "dev"

		labels: {
			environment: "dev"
			managed_by:  "argocd"
		}

		// Enable debug mode in dev
		debug: true

		// Deployment configuration
		deployment: {
			// Image will be updated by CI/CD pipeline
			image: "docker.local/example/example-app:1.2.0-e2e-20251106102442-7c0c9f2"

			// Lower replicas in dev
			replicas: 1

			// Resource limits for dev
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

			// Dev-specific environment variables
			additionalEnv: [
				{
					name:  "QUARKUS_LOG_LEVEL"
					value: "DEBUG"
				},
				{
					name:  "ENVIRONMENT"
					value: "dev"
				},
			]
		}

		// ConfigMap data for development environment
		configMap: {
			data: {
				"redis-url":     "redis://redis.dev.svc.cluster.local:6379"
				"log-level":     "debug"
				"feature-flags": "experimental-features=true"
			}
		}
	}
}

// Development environment settings for postgres
dev: postgres: apps.postgres & {
	appConfig: {
		namespace: "dev"

		labels: {
			environment: "dev"
			managed_by:  "argocd"
		}

		// Deployment configuration
		deployment: {
			// Official postgres image from Docker Hub (until we push to local registry)
			image: "postgres:16-alpine"

			// Single replica for dev
			replicas: 1

			// Resource limits for dev
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

			// TODO: Configure proper postgres health probes
			// Current limitation: CUE template merging does not easily allow switching from HTTP to exec probes
			// For now, using default HTTP probes (will fail but won't block deployment)
			// Future improvement: Enhance core.#App template to support probe type selection

			// Dev-specific environment variables
			additionalEnv: [
				{
					name:  "ENVIRONMENT"
					value: "dev"
				},
			]
		}

		// Storage configuration for postgres data
		storage: {
			enablePVC: true
			pvc: {
				storageSize: "5Gi"
			}
		}
	}
}
