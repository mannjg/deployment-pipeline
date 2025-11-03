// Package services provides shared application templates and patterns
// This file defines the ConfigMap resource template
package resources

import (
	"deployments.local/k8s-deployments/k8s"
	base "deployments.local/k8s-deployments/services/base"
)

// #ConfigMapTemplate generates a Kubernetes ConfigMap when configMap is provided.
// This template creates an app-specific ConfigMap that can be mounted into the deployment.
#ConfigMapTemplate: {
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

	// The ConfigMap resource (only created if configMap is provided)
	if appConfig.configMap != _|_ {
		configmap: k8s.#ConfigMap & {
			metadata: {
				name:      "\(appName)-config"
				namespace: appConfig.namespace
				labels:    _labels
			}

			data: appConfig.configMap.data
		}
	}
}
