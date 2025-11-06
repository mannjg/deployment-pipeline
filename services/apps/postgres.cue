// Package apps defines the application-specific configuration for postgres
// This is a standard postgres database deployment
package apps

import (
	core "deployments.local/k8s-deployments/services/core"
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
			name:  "POSTGRES_DB"
			value: "exampledb"
		},
		{
			name:  "PGDATA"
			value: "/var/lib/postgresql/data/pgdata"
		},
	]

	// App-level envFrom configuration to reference secret
	appEnvFrom: [
		{
			secretRef: {
				name: "postgres-secret"
			}
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
