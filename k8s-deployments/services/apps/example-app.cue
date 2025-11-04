// Package apps defines the application-specific configuration for example-app
package apps

import (
	core "deployments.local/k8s-deployments/services/core"
)

// example-app application configuration
exampleApp: core.#App & {
	// Set the application name
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

	// Application-level configuration
	// Environment-specific values will be merged with this
	appConfig: {
		// Service configuration uses default HTTP port (80 -> 8080)
		// No additional ports needed - the default HTTP port is provided by the base template
	}
}
