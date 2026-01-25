// Stage environment baseline configuration
//
// This is the canonical baseline for stage environment.
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

// Stage: Staging environment settings for example-app
stage: exampleApp: apps.exampleApp & {
	appConfig: {
		namespace: "stage"

		labels: {
			environment: "stage"
			managed_by:  "argocd"
		}

		debug: true

		deployment: {
			// Image managed by CI/CD pipeline
			image: "{{EXAMPLE_APP_IMAGE}}"

			replicas: 2

			resources: {
				requests: {
					cpu:    "500m"
					memory: "512Mi"
				}
				limits: {
					cpu:    "1000m"
					memory: "1Gi"
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
					value: "INFO"
				},
				{
					name:  "ENVIRONMENT"
					value: "stage"
				},
			]
		}

		configMap: {
			data: {
				"redis-url":     "redis://redis.stage.svc.cluster.local:6379"
				"log-level":     "info"
				"feature-flags": "experimental-features=true"
			}
		}
	}
}

// Stage: Staging environment settings for postgres
stage: postgres: apps.postgres & {
	appConfig: {
		namespace: "stage"

		labels: {
			environment: "stage"
			managed_by:  "argocd"
		}

		deployment: {
			image: "{{POSTGRES_IMAGE}}"

			replicas: 2

			resources: {
				requests: {
					cpu:    "500m"
					memory: "512Mi"
				}
				limits: {
					cpu:    "1000m"
					memory: "1Gi"
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
					value: "stage"
				},
			]
		}

		storage: {
			enablePVC: true
			pvc: {
				storageSize: "20Gi"
			}
		}
	}
}
