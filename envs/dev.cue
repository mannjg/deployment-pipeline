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
			managed_by: "argocd"
		}

		// Enable debug mode in dev
		debug: true

		// Deployment configuration
		deployment: {
			// Image will be updated by CI/CD pipeline
			image: "nexus.nexus.svc.cluster.local:5000/example/example-app:1.0.0-SNAPSHOT-ff49645"

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
	}
}
