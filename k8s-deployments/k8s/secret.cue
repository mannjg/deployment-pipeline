// Package k8s provides Kubernetes resource type definitions
// This file defines the Secret resource type
package k8s

// #Secret defines a Kubernetes Secret resource
#Secret: {
	apiVersion: "v1"
	kind:       "Secret"

	metadata: {
		name:      string
		namespace: string
		labels?: [string]:    string
		annotations?: [string]: string
	}

	type?: string | *"Opaque"

	data?: [string]: string

	stringData?: [string]: string
}
