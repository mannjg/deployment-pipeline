// Package apps defines the application-specific configuration for example-app
// This file is OWNED by the application team and lives in the app repository
// It is automatically synced to k8s-deployments during CI/CD
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
		{
			name: "REDIS_URL"
			value: "redis://redis.cache.svc.cluster.local:6379"
		},
		{
			name: "REDIS_TIMEOUT_SECONDS"
			value: "5"
		},
		// Database connection configuration
		{
			name:  "QUARKUS_DATASOURCE_DB_KIND"
			value: "postgresql"
		},
		{
			name:  "QUARKUS_DATASOURCE_JDBC_URL"
			value: "jdbc:postgresql://postgres:5432/exampledb"
		},
		{
			name:  "QUARKUS_DATASOURCE_USERNAME"
			value: "postgres"
		},
		{
			name:  "QUARKUS_DATASOURCE_PASSWORD"
			value: "postgres123"
		},
	]

	// Application-level configuration
	// Environment-specific values will be merged with this
	appConfig: {
		// Service configuration uses default HTTP port (80 -> 8080)
		// No additional ports needed - the default HTTP port is provided by the base template
	}
}
