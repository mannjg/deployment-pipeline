// Package services provides shared application templates and patterns
// This file defines the PersistentVolumeClaim resource template
package resources

import (
	"deployments.local/k8s-deployments/schemas:k8s"
	base "deployments.local/k8s-deployments/templates/base"
)

// #PVCTemplate generates a Kubernetes PersistentVolumeClaim from app configuration.
#PVCTemplate: {
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

	// PVC configuration with defaults
	_pvcConfig: appConfig.storage.pvc | *{
		storageSize:      "1Gi"
		storageClassName: "microk8s-hostpath"
		accessModes: ["ReadWriteOnce"]
	}

	// The actual PVC resource (only created if storage.enablePVC is true)
	if (appConfig.storage.enablePVC | *true) {
		pvc: k8s.#PersistentVolumeClaim & {
			metadata: {
				name:      "\(appName)-data"
				namespace: appConfig.namespace
				labels:    _labels
			}

			spec: {
				accessModes:      _pvcConfig.accessModes
				storageClassName: _pvcConfig.storageClassName
				resources: {
					requests: {
						storage: _pvcConfig.storageSize
					}
				}
			}
		}
	}
}
