// Package k8s provides Kubernetes resource type definitions
// This file defines the PersistentVolumeClaim resource type
package k8s

// #PersistentVolumeClaim defines a Kubernetes PersistentVolumeClaim resource
#PersistentVolumeClaim: {
	apiVersion: "v1"
	kind:       "PersistentVolumeClaim"

	metadata: {
		name:      string
		namespace: string
		labels?: [string]:    string
		annotations?: [string]: string
	}

	spec: {
		accessModes: [...string]
		resources: {
			requests: {
				storage: string
			}
		}
		storageClassName?: string
		volumeMode?:       string
		selector?: {
			matchLabels?: [string]: string
			matchExpressions?: [...{
				key:      string
				operator: string
				values?: [...string]
			}]
		}
	}

	status?: {...}
}
