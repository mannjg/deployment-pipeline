// Production environment baseline configuration
//
// This is the canonical baseline for prod environment.
// Used by reset-demo-state.sh to restore clean demo state.
//
// Placeholders:
//   {{EXAMPLE_APP_IMAGE}} - Extracted from live env.cue before reset
//   {{POSTGRES_IMAGE}}    - Extracted from live env.cue before reset
//
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
)

// Prod: Production environment settings for example-app
prod: exampleApp: apps.exampleApp & {
	appConfig: {
		namespace: "prod"

		labels: {
			environment: "prod"
			managed_by:  "argocd"
		}

		debug: false

		deployment: {
			// Image managed by CI/CD pipeline
			image: "{{EXAMPLE_APP_IMAGE}}"

			replicas: 3

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

			additionalEnv: [
				{
					name:  "QUARKUS_LOG_LEVEL"
					value: "WARN"
				},
				{
					name:  "ENVIRONMENT"
					value: "prod"
				},
			]
		}

		configMap: {
			data: {
				"redis-url":     "redis://redis.prod.svc.cluster.local:6379"
				"log-level":     "warn"
				"feature-flags": "experimental-features=false"
			}
		}
	}
}

// Prod: Production environment settings for postgres
prod: postgres: apps.postgres & {
	appConfig: {
		namespace: "prod"

		labels: {
			environment: "prod"
			managed_by:  "argocd"
		}

		deployment: {
			image: "{{POSTGRES_IMAGE}}"

			replicas: 2

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
					value: "prod"
				},
			]
		}

		storage: {
			enablePVC: true
			pvc: {
				storageSize: "50Gi"
			}
		}
	}
}
