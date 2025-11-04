package base

// Port Definitions
//
// This file contains default port configurations for containers and services.
// These are fixed defaults meant to be used as-is or completely replaced.

// Container Ports

#DefaultHttpContainerPort: {
	name:          "http"
	containerPort: 8080
	protocol:      "TCP"
}

#DefaultHttpsContainerPort: {
	name:          "https"
	containerPort: 8443
	protocol:      "TCP"
}

#DefaultDebugContainerPort: {
	name:          "debug"
	containerPort: 5005
	protocol:      "TCP"
}

// Service Ports

#DefaultHttpServicePort: {
	name:       "http"
	protocol:   "TCP"
	port:       80
	targetPort: 8080
}

#DefaultHttpsServicePort: {
	name:       "https"
	protocol:   "TCP"
	port:       443
	targetPort: 8443
}

#DefaultDebugServicePort: {
	name:       "debug"
	protocol:   "TCP"
	port:       5005
	targetPort: 5005
}

// Security Context Definitions
//
// This file contains default security context configurations for containers and pods.
// These are fixed security best practices meant to be used as-is to ensure consistent
// security posture across all deployments.
//
// NOTE: Security contexts are currently disabled to allow container images to use
// their built-in conventions (e.g., UBI images use UID 185 for jboss user).
// If you need to enforce specific security contexts, uncomment and customize below.

// Container Security Context - DISABLED to use image defaults

#DefaultContainerSecurityContext: {
	// runAsNonRoot:             true
	// runAsUser:                1000
	// runAsGroup:               1000
	// readOnlyRootFilesystem:   false
	// allowPrivilegeEscalation: false
	// capabilities: drop: ["ALL"]
}

// Pod Security Context - DISABLED to use image defaults

#DefaultPodSecurityContext: {
	// runAsNonRoot: true
	// runAsUser:    1000
	// runAsGroup:   1000
	// fsGroup:      1000
}

// Health Check Probe Definitions
//
// This file contains baseline health check probe configurations.
// These are designed to be merged with application-specific probe settings.
// The defaults provide sensible values for typical applications but can be
// partially overridden using CUE's merge operator (&).

// Liveness Probe
//
// Default liveness probe with conservative timing to avoid killing healthy
// pods during startup or temporary slow responses.

#DefaultLivenessProbe: {
	httpGet: {
		path:   "/health/live"
		port:   8080
		scheme: "HTTP"
	}
	initialDelaySeconds: 30
	periodSeconds:       10
	timeoutSeconds:      5
	failureThreshold:    3
}

#DefaultHttpsLivenessProbe: {
	httpGet: {
		path:   "/health/live"
		port:   8443
		scheme: "HTTPS"
	}
	initialDelaySeconds: 30
	periodSeconds:       10
	timeoutSeconds:      5
	failureThreshold:    3
}

// Readiness Probe
//
// Default readiness probe with more aggressive timing to quickly detect
// when pods are ready to serve traffic.

#DefaultReadinessProbe: {
	httpGet: {
		path:   "/health/ready"
		port:   8080
		scheme: "HTTP"
	}
	initialDelaySeconds: 10
	periodSeconds:       5
	timeoutSeconds:      3
	failureThreshold:    3
}

#DefaultHttpsReadinessProbe: {
	httpGet: {
		path:   "/health/ready"
		port:   8443
		scheme: "HTTPS"
	}
	initialDelaySeconds: 10
	periodSeconds:       5
	timeoutSeconds:      3
	failureThreshold:    3
}

// Volume Mount and Configuration Definitions
//
// This file contains default volume mount paths and volume configurations.
// Volume mounts are fixed defaults for consistent filesystem organization.
// Volume configurations provide baseline settings that can be overridden per-app or per-environment.

// Volume Mounts

#DefaultDataVolumeMount: {
	name:      "data"
	mountPath: "/var/lib/myapp/data"
	readOnly:  false
}

#DefaultConfigVolumeMount: {
	name:      "config"
	mountPath: "/etc/myapp/config"
	readOnly:  true
}

#DefaultCacheVolumeMount: {
	name:      "cache"
	mountPath: "/var/cache/myapp"
	readOnly:  false
}

#DefaultProjectedSecretsVolumeMount: {
	name:      "projected-secrets"
	mountPath: "/var/secrets"
	readOnly:  true
}

// Projected Volume Items
//
// These provide baseline configurations for projected volumes.
// Applications can override these to project different secrets, configmaps, or cluster resources.

#DefaultProjectedSecretItems: [
	{key: "db-user", path:     "database/username"},
	{key: "db-password", path: "database/password"},
]

#DefaultProjectedConfigMapItems: [
	{key: "redis-url", path: "config/redis-url"},
]

#DefaultProjectedClusterCAItems: [
	// Empty by default - environments can provide cluster CA if needed
	// Example: {key: "ca.crt", path: "config/cluster-ca.crt"}
]

// Volume Settings

#DefaultCacheVolumeSettings: {
	medium:    "Memory"
	sizeLimit: "256Mi"
}

#DefaultProjectedVolumeMode: 0o400

// Downward API Items
//
// Default pod metadata to expose to containers via downward API.

#DefaultDownwardAPIItems: [
	{path: "pod/name", fieldRef: fieldPath:      "metadata.name"},
	{path: "pod/namespace", fieldRef: fieldPath: "metadata.namespace"},
]

// Resource Limit Definitions
//
// This file contains default resource allocation configurations by environment tier.
// These provide baseline resource requests and limits appropriate for each environment.
// Applications with different resource needs can override these values.

// Development Environment Resources
//
// Minimal resource allocation for development environments.

#DefaultDevResources: {
	requests: {
		cpu:    "100m"
		memory: "128Mi"
	}
	limits: {
		cpu:    "200m"
		memory: "256Mi"
	}
}

// Staging Environment Resources
//
// Medium resource allocation for staging environments.

#DefaultStageResources: {
	requests: {
		cpu:    "250m"
		memory: "512Mi"
	}
	limits: {
		cpu:    "500m"
		memory: "1Gi"
	}
}

// Production Environment Resources
//
// Full resource allocation for production environments.

#DefaultProductionResources: {
	requests: {
		cpu:    "500m"
		memory: "1Gi"
	}
	limits: {
		cpu:    "1000m"
		memory: "2Gi"
	}
}

// Metadata Definitions
//
// This file contains default label configurations.
// Labels are used for resource organization and selection.

// Default App Labels
//
// Base labels for application resources.
// Usage: (#DefaultAppLabels & {app: appName, deployment: appName})
// The ... makes this an open struct that allows additional fields.

#DefaultAppLabels: {
	app:        string // Application name (must be provided)
	deployment: string // Deployment identifier (typically same as app)
	... // Allow additional label fields
}

// Default Production Labels
//
// Additional labels for production environment resources.
// These can be merged with app labels for production deployments.
// The ... makes this an open struct that allows additional fields.

#DefaultProductionLabels: {
	environment: "production"
	tier:        "critical"
	... // Allow additional label fields
}

// Deployment Strategy Definitions
//
// This section contains default deployment strategy configurations.
// These provide baseline rollout behaviors that balance update speed with availability.

// Default Deployment Strategy
//
// Balanced rolling update strategy allowing both surge and unavailability.
// Suitable for development and staging environments.

#DefaultDeploymentStrategy: {
	type: "RollingUpdate"
	rollingUpdate: {
		maxSurge:       1
		maxUnavailable: 1
	}
}

// Production Deployment Strategy
//
// Zero-downtime rolling update strategy.
// Ensures at least one pod is always available during deployments.

#DefaultProductionDeploymentStrategy: {
	type: "RollingUpdate"
	rollingUpdate: {
		maxSurge:       1
		maxUnavailable: 0 // Zero downtime deployments
	}
}

// Service Configuration Definitions
//
// This section contains default service configurations.
// These are fixed defaults for consistent service behavior across all applications.

// Default Service Type

#DefaultServiceType: "ClusterIP"

// Default Session Affinity

#DefaultSessionAffinity: "None"

// Default Service Selector
//
// Returns a selector for backend component pods.
// Usage: (#DefaultServiceSelector & {app: appName})
// The ... makes this an open struct that allows additional fields.

#DefaultServiceSelector: {
	app:       string // Must be provided by caller
	component: "backend"
	... // Allow additional selector fields
}

// Application Defaults
//
// This section contains default values for application configuration.

// Default Namespace Suffix
//
// Standard suffix for application namespaces.
// Usage: appNamespace: string | *"\(appName)-namespace"
// This is a pattern, not a component, since it's parameterized by appName.

#DefaultNamespaceSuffix: "-namespace"

// Default Base Resources List
//
// The standard set of Kubernetes resources for a basic application.
// Apps can extend this list with additional resources.

#DefaultBaseResourcesList: ["deployment", "service"]

// Default Resources List with ConfigMap
//
// Extended resources list for apps that need ConfigMaps.

#DefaultResourcesListWithConfigMap: ["deployment", "service", "configmap"]

// ConfigMap Data Defaults
//
// Common default values for ConfigMap data fields.

#DefaultRedisURL: "redis://redis.cache.svc.cluster.local:6379"

#DefaultLogLevel: "info"
