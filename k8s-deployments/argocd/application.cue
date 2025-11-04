// Package argocd provides templates for ArgoCD Application resources
// This file defines the main #ArgoApplication template
package argocd

// #ArgoApplication is the template for generating ArgoCD Application manifests.
// It takes argoConfig as input and produces a Kubernetes Application resource.
//
// Usage in environment files (e.g., dev.cue):
//   dev: argoApp: {
//       app: "example-app"
//       environment: "dev"
//       repoURL: "http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git"
//       targetRevision: "dev"
//       path: "manifests/dev"
//       namespace: "dev"
//       ...
//   }
#ArgoApplication: {
	// ===== Required Input =====
	// argoConfig must be provided and satisfy #ArgoAppConfig schema
	argoConfig: #ArgoAppConfig

	// ===== Computed Values =====
	_appName:    argoConfig.app
	_envName:    argoConfig.environment
	_fullName:   "\(_appName)-\(_envName)"
	_namespace:  argoConfig.namespace
	_project:    argoConfig.project
	_repoURL:    argoConfig.repoURL
	_revision:   argoConfig.targetRevision
	_path:       argoConfig.path
	_server:     argoConfig.server

	// Merge user labels with defaults
	_labels: (#DefaultArgoAppLabels & {
		app:         _appName
		environment: _envName
	}) & (argoConfig.labels | {})

	// Use user-provided ignoreDifferences or fall back to defaults
	_ignoreDifferences: argoConfig.ignoreDifferences | #DefaultIgnoreDifferences

	// Use user-provided syncPolicy or fall back to defaults
	_syncPolicy: argoConfig.syncPolicy | #DefaultSyncPolicy

	// ===== ArgoCD Application Resource =====
	application: {
		apiVersion: "argoproj.io/v1alpha1"
		kind:       "Application"
		metadata: {
			name:      _fullName
			namespace: #DefaultArgoNamespace
			labels:    _labels
			if argoConfig.annotations != _|_ {
				annotations: argoConfig.annotations
			}
		}
		spec: {
			project: _project
			source: {
				repoURL:        _repoURL
				targetRevision: _revision
				path:           _path
			}
			destination: {
				server:    _server
				namespace: _namespace
			}
			syncPolicy: _syncPolicy
			if len(_ignoreDifferences) > 0 {
				ignoreDifferences: _ignoreDifferences
			}
		}
	}
}
