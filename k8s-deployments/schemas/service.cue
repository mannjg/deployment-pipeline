// Package k8s provides base Kubernetes resource schemas
// This file contains Service-related schema definitions
package k8s

// #Service defines the schema for a Kubernetes Service resource
// apiVersion and kind are fixed invariants that cannot be overridden
#Service: {
	apiVersion: "v1"
	kind:       "Service"
	metadata:   #Metadata
	spec:       #ServiceSpec
}

// #ServiceSpec defines the specification for a Service
#ServiceSpec: {
	type: *"ClusterIP" | "NodePort" | "LoadBalancer" | "ExternalName"
	selector?: [string]: string
	ports: [...#ServicePort] & [_, ...]  // At least one port required
	clusterIP?: string
	loadBalancerIP?: string
	sessionAffinity?: "ClientIP" | "None"
	externalTrafficPolicy?: "Cluster" | "Local"
}

// #ServicePort defines a port exposed by a Service
#ServicePort: {
	name?:       string
	protocol:    *"TCP" | "UDP" | "SCTP"
	port:        int & >0 & <65536
	targetPort?: int | string
	nodePort?:   int & >=30000 & <32768
}
