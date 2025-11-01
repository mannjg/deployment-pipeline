// Package services provides shared application templates and patterns
// This file defines the main #App template that applications instantiate
package core

import (
	"list"

	base "example.com/cue-example/services/base"
	resources "example.com/cue-example/services/resources"
)

// Hidden package-level references to ensure imports are recognized as used
#_DeploymentTemplate:     resources.#DeploymentTemplate
#_ServiceTemplate:         resources.#ServiceTemplate
#_DebugServiceTemplate:    resources.#DebugServiceTemplate
#_ConfigMapTemplate:       resources.#ConfigMapTemplate

// #App is the main application template that apps instantiate.
// Apps provide their appName, and environments provide appConfig values.
// This template orchestrates the deployment and service creation.
//
// Usage in app files (e.g., foo.cue):
//   foo: #App & {
//       appName: "foo"
//   }
//
// Usage in environment files (e.g., dev.cue):
//   foo: appConfig: {
//       image: "foo:dev-latest"
//       replicas: 1
//       resources: {...}
//       ...
//   }
#App: {
	// ===== Required Fields =====
	// appName must be provided by the app definition file
	appName: string

	// ===== Optional App-Level Fields =====
	// App-level environment variables (optional, defaults to empty list)
	// These are applied to all instances of this app across all environments
	// Separate from environment-specific additionalEnv to avoid unification conflicts
	appEnvVars: [...] | *[]

	// Environment-level environment variables (optional, defaults to empty list)
	// These are provided by the environment file and applied to all apps in that environment
	// Example: ENVIRONMENT=dev, ENVIRONMENT=staging, ENVIRONMENT=production
	envEnvVars: [...] | *[]

	// App-level envFrom sources (optional, defaults to empty list)
	// These are applied to all instances of this app across all environments
	// Used for app-level ConfigMap or Secret references
	appEnvFrom: [...] | *[]

	// Environment-level envFrom sources (optional, defaults to empty list)
	// These are provided by the environment file and applied to all apps in that environment
	// Example: shared-production-config ConfigMap
	envEnvFrom: [...] | *[]

	// ===== Default Values =====
	// App-level default namespace
	// Can be overridden by environment files via appConfig.namespace
	appNamespace: string | *"\(appName)-namespace"

	// Default labels applied to all resources
	// Merged with any labels provided via appConfig.labels
	defaultLabels: {
		app:        appName
		deployment: appName
	}

	// ===== Configuration Schema =====
	// appConfig must be satisfied by environment files
	// This is where all environment-specific configuration is provided
	appConfig: base.#AppConfig & {
		// Provide sensible defaults for optional fields
		namespace: string | *appNamespace
		labels: defaultLabels & {
			// Allow environments to add or override labels
			...
		}
	}

	// ===== Internal Computed Values =====
	// Baseline environment variables for all apps (based on debug flag, etc.)
	_baseAppEnvs: [
		if appConfig.debug {
			{name: "DEBUG", value: "yes"}
		},
	]

	// Concatenate all env var layers: base + app-level + environment-level
	// This combined list is passed to the deployment template
	// Final order: DEBUG (if debug) → app vars (e.g., FOO_SPECIAL) → env vars (e.g., ENVIRONMENT=dev)
	_computedAppEnvVars: list.Concat([_baseAppEnvs, appEnvVars, envEnvVars])

	// Concatenate all envFrom layers: app-level + environment-level
	// This combined list is passed to the deployment template
	// Final order: app envFrom (e.g., app-specific secrets) → env envFrom (e.g., shared-production-config)
	_computedAppEnvFrom: list.Concat([appEnvFrom, envEnvFrom])

	// ===== Kubernetes Resources =====
	// All Kubernetes resources are nested under the resources struct
	// This enables dynamic list generation and clean resource organization
	resources: {
		// Always-present resources
		deployment: (#_DeploymentTemplate & {
			"appName":    appName
			"appConfig":  appConfig
			"appEnvVars": _computedAppEnvVars
			"appEnvFrom": _computedAppEnvFrom
		}).deployment

		service: (#_ServiceTemplate & {
			"appName":   appName
			"appConfig": appConfig
		}).service

		// Conditionally include debugService when debug mode is enabled
		if appConfig.debug {
			debugService: (#_DebugServiceTemplate & {
				"appName":   appName
				"appConfig": appConfig
			}).debugService
		}

		// Conditionally include configmap when configMap is provided
		if appConfig.configMap != _|_ {
			configmap: (#_ConfigMapTemplate & {
				"appName":   appName
				"appConfig": appConfig
			}).configmap
		}

		// Allow environments to extend individual resources
		...
	}

	// ===== Resources List Management =====
	// resources_list dynamically reflects what resources actually exist
	// Uses alphabetical ordering via list.Sort for consistency and predictability
	// This ensures the list is always accurate and self-documenting
	// Apps can still override by providing an explicit resources_list
	resources_list: [...string] | *list.Sort([for k, _ in resources {k}], list.Ascending)

	// ===== Extensibility =====
	// Allow apps to add additional fields (e.g., configmap for bar)
	// This is how apps can define additional Kubernetes resources
	...
}
