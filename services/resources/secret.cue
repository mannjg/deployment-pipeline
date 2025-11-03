// Package services provides shared application templates and patterns
// This file defines the Secret resource template
package resources

import (
	"deployments.local/k8s-deployments/k8s"
	base "deployments.local/k8s-deployments/services/base"
)

// #SecretTemplate generates a Kubernetes Secret from app configuration.
#SecretTemplate: {
	// Required inputs
	appName:   string
	appConfig: base.#AppConfig

	// Default labels (can be extended via appConfig.labels)
	_defaultLabels: {
		app:        appName
		deployment: appName
	}

	// Computed labels - merge defaults with config
	_labels: _defaultLabels & appConfig.labels

	// Secret data from configuration
	_secretData: appConfig.secret.data | *{
		"db-user":     "YXBwdXNlcg==" // base64: appuser
		"db-password": "Y2hhbmdlbWU=" // base64: changeme
	}

	// The actual Secret resource (only created if secret is configured or enabled)
	if (appConfig.secret.enabled | *true) {
		secret: k8s.#Secret & {
			metadata: {
				name:      "\(appName)-secrets"
				namespace: appConfig.namespace
				labels:    _labels
			}

			type: "Opaque"

			data: _secretData
		}
	}
}
