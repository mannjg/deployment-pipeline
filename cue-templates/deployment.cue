// Package k8s provides base Kubernetes resource schemas
// These definitions enforce type constraints and provide structure
// but allow flexibility through defaults and optional fields
package k8s

// #Deployment defines the schema for a Kubernetes Deployment resource
// apiVersion and kind are fixed invariants that cannot be overridden
#Deployment: {
	apiVersion: "apps/v1"
	kind:       "Deployment"
	metadata:   #Metadata
	spec:       #DeploymentSpec
}

// #Metadata defines common Kubernetes metadata
#Metadata: {
	name:      string
	namespace: string  // No default - apps provide their own defaults
	labels?: [string]:      string
	annotations?: [string]: string
}

// #DeploymentSpec defines the specification for a Deployment
#DeploymentSpec: {
	replicas: int & >=0 | *1
	selector: #LabelSelector
	template: #PodTemplateSpec
	strategy?: #DeploymentStrategy
}

// #LabelSelector defines how to select pods
#LabelSelector: {
	matchLabels: [string]: string
}

// #PodTemplateSpec defines the pod template
#PodTemplateSpec: {
	metadata: {
		labels: [string]: string
		annotations?: [string]: string
	}
	spec: #PodSpec
}

// #PodSpec defines the specification for a pod
#PodSpec: {
	containers: [...#Container] & [_, ...]  // At least one container required
	volumes?: [...#Volume]
	nodeSelector?: [string]: string
	affinity?:              #Affinity
	tolerations?: [...#Toleration]
	serviceAccountName?: string
	securityContext?:    #PodSecurityContext
}

// #Container defines a container within a pod
#Container: {
	name:  string
	image: string
	ports?: [...#ContainerPort]
	env?: [...#EnvVar]
	envFrom?: [...#EnvFromSource]
	volumeMounts?: [...#VolumeMount]
	resources?:         #Resources
	livenessProbe?:     #Probe
	readinessProbe?:    #Probe
	imagePullPolicy?:   "Always" | "IfNotPresent" | "Never"
	securityContext?:   #SecurityContext
	command?: [...string]
	args?: [...string]
}

// #ContainerPort defines a port on a container
#ContainerPort: {
	name?:          string
	containerPort:  int & >0 & <65536
	protocol:       *"TCP" | "UDP" | "SCTP"
	hostPort?:      int & >0 & <65536
}

// #EnvVar defines an environment variable
#EnvVar: {
	name: string
	// Either value or valueFrom must be specified, but not both
	value?: string
	valueFrom?: #EnvVarSource
}

// #EnvVarSource defines a source for an environment variable value
#EnvVarSource: {
	configMapKeyRef?: {
		name: string
		key:  string
	}
	secretKeyRef?: {
		name: string
		key:  string
	}
	fieldRef?: {
		fieldPath: string
	}
}

// #EnvFromSource defines a source to populate environment variables from
#EnvFromSource: {
	// Optional prefix to prepend to variable names
	prefix?: string

	// Reference to a ConfigMap
	configMapRef?: {
		name:      string
		optional?: bool
	}

	// Reference to a Secret
	secretRef?: {
		name:      string
		optional?: bool
	}
}

// #VolumeMount defines how to mount a volume into a container
#VolumeMount: {
	name:      string
	mountPath: string
	subPath?:  string
	readOnly:  bool | *false
}

// #Volume defines a volume that can be mounted
#Volume: {
	name: string
	// Only one of these should be specified
	persistentVolumeClaim?: {
		claimName: string
	}
	configMap?: {
		name: string
		items?: [...{
			key:  string
			path: string
		}]
	}
	secret?: {
		secretName: string
		items?: [...{
			key:  string
			path: string
		}]
	}
	emptyDir?: {
		medium?:    string
		sizeLimit?: string
	}
	projected?: {
		sources: [...#ProjectedVolumeSource]
		defaultMode?: int
	}
}

// #ProjectedVolumeSource defines a source for a projected volume
#ProjectedVolumeSource: {
	// Only one of these should be specified
	secret?: {
		name: string
		items?: [...{
			key:  string
			path: string
			mode?: int
		}]
		optional?: bool
	}
	configMap?: {
		name: string
		items?: [...{
			key:  string
			path: string
			mode?: int
		}]
		optional?: bool
	}
	downwardAPI?: {
		items: [...{
			path: string
			fieldRef?: {
				fieldPath:  string
				apiVersion?: string
			}
			resourceFieldRef?: {
				containerName: string
				resource:      string
				divisor?:      string
			}
			mode?: int
		}]
	}
	serviceAccountToken?: {
		path:              string
		expirationSeconds?: int
		audience?:         string
	}
}

// #Resources defines resource requests and limits
#Resources: {
	requests?: {
		cpu?:    string
		memory?: string
	}
	limits?: {
		cpu?:    string
		memory?: string
	}
}

// #Probe defines a health check probe
#Probe: {
	httpGet?: {
		path:   string
		port:   int | string
		scheme: *"HTTP" | "HTTPS"
	}
	tcpSocket?: {
		port: int | string
	}
	exec?: {
		command: [...string]
	}
	initialDelaySeconds?: int
	periodSeconds?:       int
	timeoutSeconds?:      int
	successThreshold?:    int
	failureThreshold?:    int
}

// #DeploymentStrategy defines how updates are performed
#DeploymentStrategy: {
	type: *"RollingUpdate" | "Recreate"
	rollingUpdate?: {
		maxSurge:       int | string | *1
		maxUnavailable: int | string | *0
	}
}

// #Affinity defines pod affinity rules
#Affinity: {
	nodeAffinity?: {
		requiredDuringSchedulingIgnoredDuringExecution?: {
			nodeSelectorTerms: [...{
				matchExpressions?: [...{
					key:      string
					operator: "In" | "NotIn" | "Exists" | "DoesNotExist" | "Gt" | "Lt"
					values?: [...string]
				}]
			}]
		}
	}
	podAffinity?: {...}
	podAntiAffinity?: {...}
}

// #Toleration defines pod tolerations
#Toleration: {
	key?:      string
	operator?: "Exists" | "Equal"
	value?:    string
	effect?:   "NoSchedule" | "PreferNoSchedule" | "NoExecute"
}

// #SecurityContext defines container security context
#SecurityContext: {
	runAsUser?:              int
	runAsGroup?:             int
	runAsNonRoot?:           bool
	readOnlyRootFilesystem?: bool
	allowPrivilegeEscalation?: bool
	capabilities?: {
		add?: [...string]
		drop?: [...string]
	}
}

// #PodSecurityContext defines pod-level security context
#PodSecurityContext: {
	runAsUser?:    int
	runAsGroup?:   int
	runAsNonRoot?: bool
	fsGroup?:      int
}
