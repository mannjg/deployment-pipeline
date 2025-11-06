// Staging environment configuration
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
)

// Staging environment settings for example-app
stage: exampleApp: apps.exampleApp & {
	// Override namespace for stage
	appConfig: {
		namespace: "stage"

		labels: {
			environment: "stage"
			managed_by:  "argocd"
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
					cpu:    "200m"
					memory: "512Mi"
				}
				limits: {
					cpu:    "1000m"
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
				periodSeconds:       10
			}

			readinessProbe: {
				httpGet: {
					path: "/health/ready"
					port: 8080
				}
				initialDelaySeconds: 15
				periodSeconds:       10
			}

			// Stage-specific environment variables
			additionalEnv: [
				{
					name:  "QUARKUS_LOG_LEVEL"
					value: "INFO"
				},
				{
					name:  "ENVIRONMENT"
					value: "stage"
				},
			]
		}
	}
}

// Staging environment settings for postgres
stage: postgres: apps.postgres & {
	appConfig: {
		namespace: "stage"

		labels: {
			environment: "stage"
			managed_by:  "argocd"
		}

		// Deployment configuration
		deployment: {
			// Official postgres image for stage
			image: "docker.local/library/postgres:16-alpine"

			// Single replica for stage (could be 2 for HA testing)
			replicas: 1

			// Higher resource limits for stage
			resources: {
				requests: {
					cpu:    "200m"
					memory: "512Mi"
				}
				limits: {
					cpu:    "1000m"
					memory: "1Gi"
				}
			}

			// Postgres-specific health probes using pg_isready
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

		// Stage-specific environment variables
			additionalEnv: [
				{
					name:  "ENVIRONMENT"
					value: "stage"
				},
			]
		}

		// Storage configuration for postgres data
		storage: {
			enablePVC: true
			pvc: {
				storageSize: "10Gi"
			}
		}
	}
}
