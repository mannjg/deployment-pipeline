// Package apps defines the application-specific configuration for postgres
// This is a standard postgres database deployment
package apps

import (
	core "deployments.local/k8s-deployments/templates/core"
)

// postgres application configuration
postgres: core.#App & {
	// Set the application name
	appName: "postgres"

	// App-level environment variables (applied to all instances across all environments)
	appEnvVars: [
		{
			name:  "POSTGRES_USER"
			value: "postgres"
		},
		{
			name:  "POSTGRES_PASSWORD"
			value: "postgres123" // Hardcoded for example/test purposes
		},
		{
			name:  "POSTGRES_DB"
			value: "exampledb"
		},
		{
			name:  "PGDATA"
			value: "/var/lib/postgresql/data/pgdata"
		},
	]

	// Application-level configuration
	// Environment-specific values will be merged with this
	appConfig: {
		// Service configuration for postgres port
		service: {
			additionalPorts: [
				{
					name:       "postgresql"
					port:       5432
					targetPort: 5432
					protocol:   "TCP"
				},
			]
		}
	}
}
