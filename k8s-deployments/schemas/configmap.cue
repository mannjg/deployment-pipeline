// Package k8s provides base Kubernetes resource schemas
package k8s

// #ConfigMap defines the schema for a Kubernetes ConfigMap resource
#ConfigMap: {
	apiVersion: "v1"
	kind:       "ConfigMap"
	metadata:   #Metadata
	data?: [string]: string
	binaryData?: [string]: string
}
