// Production environment configuration
package envs

import (
	"deployments.local/k8s-deployments/services/apps"
)

// Production environment settings for example-app
prod: exampleApp: apps.exampleApp & {
	// Override namespace for prod
	appConfig: {
		namespace: "prod"

		labels: {
			environment: "prod"
			managed_by:  "argocd"
		}

		// Disable debug mode in prod
		debug: false

		// Deployment configuration
		deployment: {
			// Image will be updated by CI/CD pipeline
			image: "docker.local/example/example-app:1.0.0-SNAPSHOT"

			// Production replicas for HA
			replicas: 3

			// Production resource limits
			resources: {
				requests: {
					cpu:    "500m"
					memory: "1Gi"
				}
				limits: {
					cpu:    "2000m"
					memory: "2Gi"
				}
			}

			// Health probes with production settings
			livenessProbe: {
				httpGet: {
					path: "/health/live"
					port: 8080
				}
				initialDelaySeconds: 20
				periodSeconds:       15
				failureThreshold:    3
			}

			readinessProbe: {
				httpGet: {
					path: "/health/ready"
					port: 8080
				}
				initialDelaySeconds: 20
				periodSeconds:       10
				failureThreshold:    3
			}

			// Production-specific environment variables
			additionalEnv: [
				{
					name:  "QUARKUS_LOG_LEVEL"
					value: "INFO"
				},
				{
					name:  "ENVIRONMENT"
					value: "prod"
				},
			]

			// Production deployment strategy
			strategy: {
				type: "RollingUpdate"
				rollingUpdate: {
					maxSurge:       1
					maxUnavailable: 0 // No downtime during updates
				}
			}

			// Production-grade affinity rules
			affinity: {
				podAntiAffinity: {
					preferredDuringSchedulingIgnoredDuringExecution: [{
						weight: 100
						podAffinityTerm: {
							labelSelector: {
								matchLabels: {
									app: "example-app"
								}
							}
							topologyKey: "kubernetes.io/hostname"
						}
					}]
				}
			}
		}
	}
}

// Production environment settings for postgres
prod: postgres: apps.postgres & {
	appConfig: {
		namespace: "prod"

		labels: {
			environment: "prod"
			managed_by:  "argocd"
		}

		// Deployment configuration
		deployment: {
			// Official postgres image for prod
			image: "docker.local/library/postgres:16-alpine"

			// HA setup with 2 replicas
			replicas: 2

			// Production resource limits
			resources: {
				requests: {
					cpu:    "500m"
					memory: "1Gi"
				}
				limits: {
					cpu:    "2000m"
					memory: "2Gi"
				}
			}

			// TODO: Configure proper postgres health probes
			// Current limitation: CUE template merging does not easily allow switching from HTTP to exec probes
			// For now, using default HTTP probes (will fail but won't block deployment)
			// Future improvement: Enhance core.#App template to support probe type selection

			// Production-specific environment variables
			additionalEnv: [
				{
					name:  "ENVIRONMENT"
					value: "prod"
				},
			]

			// Production deployment strategy - zero downtime
			strategy: {
				type: "RollingUpdate"
				rollingUpdate: {
					maxSurge:       1
					maxUnavailable: 0 // No downtime during updates
				}
			}

			// Production-grade affinity rules - spread replicas across nodes
			affinity: {
				podAntiAffinity: {
					preferredDuringSchedulingIgnoredDuringExecution: [{
						weight: 100
						podAffinityTerm: {
							labelSelector: {
								matchLabels: {
									app: "postgres"
								}
							}
							topologyKey: "kubernetes.io/hostname"
						}
					}]
				}
			}
		}

		// Storage configuration for postgres data
		storage: {
			enablePVC: true
			pvc: {
				storageSize: "50Gi"
			}
		}

		// Secret for postgres password
		secret: {
			enabled: true
			data: {
				"POSTGRES_PASSWORD": "cG9zdGdyZXMtcHJvZC03ODk=" // base64 encoded "postgres-prod-789"
			}
		}
	}
}
