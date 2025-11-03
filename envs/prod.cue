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
			managed_by: "argocd"
		}

		// Disable debug mode in prod
		debug: false

		// Deployment configuration
		deployment: {
			// Image will be updated by CI/CD pipeline
			image: "nexus.local:5000/example/example-app:1.0.0-SNAPSHOT"

			// Production replicas for HA
			replicas: 3

			// Production resource limits
			resources: {
				requests: {
					cpu: "500m"
					memory: "1Gi"
				}
				limits: {
					cpu: "2000m"
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
				periodSeconds: 15
				failureThreshold: 3
			}

			readinessProbe: {
				httpGet: {
					path: "/health/ready"
					port: 8080
				}
				initialDelaySeconds: 20
				periodSeconds: 10
				failureThreshold: 3
			}

			// Production-specific environment variables
			additionalEnv: [
				{
					name: "QUARKUS_LOG_LEVEL"
					value: "INFO"
				},
				{
					name: "ENVIRONMENT"
					value: "prod"
				},
			]

			// Production deployment strategy
			strategy: {
				type: "RollingUpdate"
				rollingUpdate: {
					maxSurge: 1
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
