// Package argocd provides schemas for ArgoCD Application resources
// This file defines the configuration schema for ArgoCD applications
package argocd

// #ArgoAppConfig defines the schema for ArgoCD Application configuration.
// This schema allows environments to specify how ArgoCD should deploy applications.
#ArgoAppConfig: {
	// ===== Application Identity =====

	// Application name (e.g., "example-app")
	app: string

	// Environment name (e.g., "dev", "stage", "prod")
	environment: string

	// ===== Git Source Configuration =====

	// Git repository URL where manifests are stored
	repoURL: string

	// Target revision (branch, tag, or commit)
	// Typically matches environment name (e.g., "dev", "stage", "prod")
	targetRevision: string

	// Path within the repository to the manifests
	// Typically "manifests/{environment}"
	path: string

	// ===== Destination Configuration =====

	// Target namespace for the application
	namespace: string

	// Target cluster server URL
	// Defaults to in-cluster deployment
	server: string | *"https://kubernetes.default.svc"

	// ===== ArgoCD Project =====

	// ArgoCD project name
	project: string | *"default"

	// ===== Sync Policy =====

	syncPolicy: {
		// Enable automated sync
		automated?: {
			// Automatically prune resources that are no longer defined in Git
			prune: bool | *true

			// Automatically sync when the live cluster state deviates from Git
			selfHeal: bool | *true

			// Allow sync when the repo is empty
			allowEmpty: bool | *false
		}

		// Sync options
		syncOptions?: [...string]

		// Retry policy for failed syncs
		retry?: {
			limit: int | *5
			backoff?: {
				duration:    string | *"5s"
				factor:      int | *2
				maxDuration: string | *"3m"
			}
		}
	}

	// ===== Ignore Differences =====

	// Differences to ignore during sync comparison
	// Useful for fields managed by controllers (e.g., HPA managing replicas)
	ignoreDifferences?: [...{
		group:         string
		kind:          string
		jsonPointers?: [...string]
		...
	}]

	// ===== Labels and Annotations =====

	// Labels to apply to the Application resource
	labels?: [string]: string

	// Annotations to apply to the Application resource
	annotations?: [string]: string
}
