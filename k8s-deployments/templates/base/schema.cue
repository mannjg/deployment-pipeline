// Package services provides shared application templates and patterns
// This file defines the configuration schema for applications
package base

import "deployments.local/k8s-deployments/schemas:k8s"

// #AppConfig defines the complete schema for application configuration.
// All configuration should flow through this interface - environments provide
// these values, and they are used to render Kubernetes resources.
// This eliminates the need for deep merging of deployment/service structures.
//
// The schema is organized by resource type:
// - Top-level: cross-resource configuration (namespace, labels, enableHttps, debug)
// - deployment.*: Deployment-specific configuration
// - service.*: Service-specific configuration
// - configMap: ConfigMap creation and configuration
#AppConfig: {
	// ===== High-Level (Cross-Resource) Configuration =====
	// These options affect multiple resources or have system-wide impact

	// Namespace for all resources
	// Defaults to appNamespace if not specified
	namespace: string

	// Labels applied to all resources
	// Merged with defaultLabels from the app
	labels: [string]: string

	// Enable HTTPS mode - switches from HTTP (port 8080) to HTTPS (port 8443)
	// When enabled:
	// - Container port changes from 8080 (http) to 8443 (https)
	// - Service port changes from 80->8080 to 443->8443
	// - Health probes use port 8443 with HTTPS scheme
	// Affects: Deployment, Service, Health Probes
	enableHttps: bool | *false

	// Enable debug mode - adds debug port to deployment and creates debug service
	// Typically enabled in dev/stage environments for troubleshooting
	// Affects: Deployment (adds debug port + DEBUG env), Creates DebugService
	debug: bool | *false

	// ===== Deployment Configuration =====
	// All options specific to the Deployment resource

	deployment: {
		// ----- Core Container Configuration -----

		// Container image with tag (e.g., "myapp:v1.2.3")
		image: string

		// Resource requests and limits (optional - if not provided, no limits are set)
		resources?: k8s.#Resources

		// ----- Scaling -----

		// Number of pod replicas
		replicas: int & >=1 & <=10

		// ----- Metadata -----

		// Deployment-level annotations (applied to Deployment metadata)
		annotations?: [string]: string

		// Pod-level annotations (applied to Pod template metadata)
		podAnnotations?: [string]: string

		// ----- Deployment Strategy -----

		// Deployment strategy configuration
		// Controls how rolling updates are performed
		strategy?: {
			type: *"RollingUpdate" | "Recreate"
			if type == "RollingUpdate" {
				rollingUpdate?: {
					maxSurge:       int | string | *1
					maxUnavailable: int | string | *1
				}
			}
		}

		// ----- Scheduling and Placement -----

		// Priority class name for pod scheduling
		// Higher priority pods are scheduled before lower priority ones
		priorityClassName?: string

		// Affinity rules for advanced pod scheduling
		// Can specify pod affinity, anti-affinity, and node affinity
		affinity?: k8s.#Affinity

		// Node selector for pod placement
		nodeSelector?: [string]: string

		// ----- Health Probes -----

		// Liveness probe configuration
		// If not specified, uses default HTTP probe on /health/live:8080
		livenessProbe?: k8s.#Probe

		// Readiness probe configuration
		// If not specified, uses default HTTP probe on /health/ready:8080
		readinessProbe?: k8s.#Probe

		// ----- Environment Variables (Additive) -----

		// Additional envFrom sources to append to defaults
		// Environments specify additional sources here, not the complete list
		additionalEnvFrom: [...k8s.#EnvFromSource] | *[]

		// Additional individual env vars to append to defaults
		// Apps or environments specify additional vars here, not the complete list
		additionalEnv: [...k8s.#EnvVar] | *[]

		// ----- Ports (Additive) -----

		// Additional container ports to append to base ports
		// Base ports always include http:8080 (or https:8443), plus debug:5005 when debug=true
		// Use this to add custom ports without replacing the defaults
		additionalPorts: [...k8s.#ContainerPort] | *[]

		// ----- Volumes Configuration -----

		// Volume configuration - defines which volumes the app needs
		// If not specified, uses default volumes (data, config, cache, projected-secrets)
		volumes?: #VolumesConfig

		// Volume source names - can be overridden per environment
		volumeSourceNames?: {
			configMapName?: string
			secretName?:    string
		}

		// Cluster CA ConfigMap name - can be set at environment level
		// Used in projected volumes for TLS certificate authority configuration
		clusterCAConfigMap?: string
	}

	// ===== Service Configuration =====
	// All options specific to the Service resource

	service: {
		// Service annotations (applied to Service metadata)
		annotations?: [string]: string

		// Additional service ports to append to base service ports
		// Base service ports always include http:80->8080 (or https:443->8443)
		// Use this to add custom service ports without replacing the defaults
		additionalPorts: [...k8s.#ServicePort] | *[]
	}

	// ===== ConfigMap Configuration =====
	// High-level capability that creates a ConfigMap and wires it into the deployment

	// ConfigMap data - if provided, creates a ConfigMap resource and mounts it
	// This is a high-level capability that wires together:
	// - ConfigMap resource creation
	// - Volume definition in deployment
	// - VolumeMount in container
	configMap?: {
		// The actual key-value data for the ConfigMap
		data: [string]: string

		// Optional mount configuration
		mount?: {
			// Mount path in the container (defaults to #DefaultConfigVolumeMount.mountPath)
			path?: string

			// Whether the mount should be read-only (defaults to #DefaultConfigVolumeMount.readOnly)
			readOnly?: bool

			// Optional subPath for mounting a specific key
			subPath?: string

			// Optional specific items to mount (instead of all keys)
			items?: [...{
				key:   string
				path:  string
				mode?: int
			}]
		}
	}

	// ===== Storage Configuration =====
	// Configuration for persistent storage resources

	storage?: {
		// Enable PVC creation (disabled by default for stateless apps)
		enablePVC: bool | *false

		// PVC configuration
		pvc?: {
			storageSize:      string | *"1Gi"
			storageClassName: string | *"microk8s-hostpath"
			accessModes: [...string] | *["ReadWriteOnce"]
		}
	}

	// ===== Secret Configuration =====
	// Configuration for application secrets

	secret?: {
		// Enable secret creation (disabled by default)
		enabled: bool | *false

		// Secret data (base64 encoded values)
		data?: [string]: string
	}
}

// #VolumesConfig defines the volume configuration for an application.
// This makes volumes configurable instead of hardcoded.
// Volumes are disabled by default for stateless applications.
#VolumesConfig: {
	// Enable standard data volume (PVC) - disabled by default
	enableDataVolume: bool | *false

	// Data volume PVC name (if enableDataVolume is true)
	dataVolumePVCName?: string

	// Enable standard config volume (ConfigMap) - disabled by default
	enableConfigVolume: bool | *false

	// Config volume ConfigMap name (if enableConfigVolume is true)
	configVolumeConfigMapName?: string

	// Enable standard cache volume (EmptyDir) - disabled by default
	enableCacheVolume: bool | *false

	// Cache volume settings
	cacheVolumeSettings?: {
		medium:    string | *#DefaultCacheVolumeSettings.medium
		sizeLimit: string | *#DefaultCacheVolumeSettings.sizeLimit
	}

	// Enable projected secrets volume - disabled by default
	enableProjectedSecretsVolume: bool | *false

	// Projected secrets configuration (if enableProjectedSecretsVolume is true)
	projectedSecretsConfig?: {
		// Secret items to project
		secretItems: [...{
			key:  string
			path: string
		}] | *#DefaultProjectedSecretItems

		// ConfigMap items to project
		configMapItems: [...{
			key:  string
			path: string
		}] | *#DefaultProjectedConfigMapItems

		// Cluster CA ConfigMap items to project
		clusterCAItems: [...{
			key:  string
			path: string
		}] | *#DefaultProjectedClusterCAItems

		// Include downward API
		includeDownwardAPI: bool | *true
	}

	// Additional custom volumes
	// Apps can specify additional volumes beyond the standard ones
	additionalVolumes?: [...k8s.#Volume]

	// Additional volume mounts
	// Apps can specify additional volume mounts beyond the standard ones
	additionalVolumeMounts?: [...k8s.#VolumeMount]
}
