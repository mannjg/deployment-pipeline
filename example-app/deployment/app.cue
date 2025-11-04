// Package deployment defines application-specific configuration for example-app
// This file will be merged into the k8s-deployments repository by the CI/CD pipeline
package deployment

// example-app application configuration
// This defines app-specific settings that apply across all environments
exampleApp: {
	// Application metadata
	appName: "example-app"

	// App-level environment variables (applied to all instances across all environments)
	appEnvVars: [
		{
			name: "QUARKUS_HTTP_PORT"
			value: "8080"
		},
		{
			name: "QUARKUS_LOG_CONSOLE_ENABLE"
			value: "true"
		},
	]

	// Application-level configuration defaults
	// These can be overridden by environment-specific configs
	appConfig: {
		// Health check configuration
		healthCheck: {
			path: "/health/ready"
			port: 8080
			initialDelaySeconds: 10
			periodSeconds: 10
		}

		// Service configuration
		service: {
			type: "ClusterIP"
			port: 80
			targetPort: 8080
		}

		// Deployment strategy
		strategy: {
			type: "RollingUpdate"
			maxSurge: 1
			maxUnavailable: 0
		}
	}
}

// Renderer for generating environment-specific configuration
// Environments will use this to transform their inputs into appConfig
#ExampleAppRenderer: {
	// Inputs that environments must provide
	inputs: {
		// Image reference (registry/group/name:tag)
		image: string

		// Number of replicas
		replicas: int & >=1 & <=10

		// Resource configuration
		resources: {
			requests: {
				cpu: string
				memory: string
			}
			limits: {
				cpu: string
				memory: string
			}
		}

		// Environment-specific labels
		labels: [string]: string

		// Environment-specific annotations
		annotations: [string]: string

		// Environment-specific appConfig to merge with generated config
		appConfig: {...}
	}

	// Generated deployment configuration
	_generated: {
		deployment: {
			image: inputs.image
			replicas: inputs.replicas
			resources: inputs.resources
			labels: inputs.labels
			annotations: inputs.annotations

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
		}

		// Service configuration
		service: {
			type: "ClusterIP"
			ports: [{
				name: "http"
				port: 80
				targetPort: 8080
				protocol: "TCP"
			}]
			selector: {
				app: "example-app"
			}
		}
	}

	// Final rendered config: merge environment-provided appConfig with generated config
	renderedConfig: inputs.appConfig & _generated
}
