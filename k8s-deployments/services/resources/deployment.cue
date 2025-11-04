// Package services provides shared application templates and patterns
// This file defines the Deployment resource template
package resources

import (
	"list"

	"deployments.local/k8s-deployments/k8s"
	base "deployments.local/k8s-deployments/services/base"
)

// _projectedSecretsVolumeBuilder builds a projected secrets volume with configurable items.
// This local helper consolidates the complex logic for building projected volumes that combine
// secrets, configmaps, cluster CA, and downward API into a single volume.
_projectedSecretsVolumeBuilder: {
	// Configuration inputs with defaults
	enabled:            bool | *true
	secretItems:        [...{key: string, path: string}] | *base.#DefaultProjectedSecretItems
	configMapItems:     [...{key: string, path: string}] | *base.#DefaultProjectedConfigMapItems
	clusterCAItems:     [...{key: string, path: string}] | *base.#DefaultProjectedClusterCAItems
	includeDownwardAPI: bool | *true

	// Volume source names (must be provided by caller with their own defaults)
	configMapName:      string
	secretName:         string
	clusterCAConfigMap: string

	// Output volume (conditional on enabled)
	volume: [
		if enabled {
			name: "projected-secrets"
			projected: {
				defaultMode: base.#DefaultProjectedVolumeMode
				sources: [
					if len(secretItems) > 0 {
						secret: {
							name:  secretName
							items: secretItems
						}
					},
					if len(configMapItems) > 0 {
						configMap: {
							name:  configMapName
							items: configMapItems
						}
					},
					if len(clusterCAItems) > 0 {
						configMap: {
							name:  clusterCAConfigMap
							items: clusterCAItems
						}
					},
					if includeDownwardAPI {
						downwardAPI: {
							items: base.#DefaultDownwardAPIItems
						}
					},
				]
			}
		},
	]
}

// #DeploymentTemplate generates a Kubernetes Deployment from app configuration.
// This is a pure template that takes appName and appConfig and produces a Deployment.
#DeploymentTemplate: {
	// Required inputs
	appName:   string
	appConfig: base.#AppConfig

	// Optional: app-level environment variables (provided by app.cue)
	appEnvVars: [...k8s.#EnvVar] | *[]

	// Optional: app-level envFrom sources (provided by app.cue)
	appEnvFrom: [...k8s.#EnvFromSource] | *[]

	// Default labels (can be extended via appConfig.labels)
	_defaultLabels: {
		app:        appName
		deployment: appName
	}

	// Computed labels - merge defaults with config
	_labels: _defaultLabels & appConfig.labels

	// Computed env - concatenate: app-level defaults + environment-specific
	// Note: appEnvVars includes system defaults (like DEBUG) computed in app.cue
	_env: list.Concat([appEnvVars, appConfig.deployment.additionalEnv])

	// Computed envFrom - concatenate: app-level + environment-specific
	// Note: appEnvFrom includes app-level and environment-level envFrom computed in app.cue
	_envFrom: list.Concat([appEnvFrom, appConfig.deployment.additionalEnvFrom])

	// Container ports - always include base ports, plus debug when enabled, plus additional
	_containerPorts: [
		if appConfig.enableHttps {base.#DefaultHttpsContainerPort},
		if !appConfig.enableHttps {base.#DefaultHttpContainerPort},
		if appConfig.debug {base.#DefaultDebugContainerPort},
		for port in appConfig.deployment.additionalPorts {port},
	]

	// Volume configuration with smart defaults
	_volumeConfig: appConfig.deployment.volumes | *{}

	// Build volumes list based on configuration
	_volumes: list.Concat([
		_dataVolumes,
		_configVolumes,
		_cacheVolumes,
		_projectedSecretsVolumes,
		_additionalVolumes,
	])

	_dataVolumes: [
		if (_volumeConfig.enableDataVolume | *false) {
			name: "data"
			persistentVolumeClaim: {
				claimName: _volumeConfig.dataVolumePVCName | *"\(appName)-data"
			}
		},
	]

	_configVolumes: [
		// Config volume is enabled if:
		// 1. Explicitly enabled via volumeConfig.enableConfigVolume, OR
		// 2. configMap is provided (which auto-creates the ConfigMap)
		if (_volumeConfig.enableConfigVolume | *false) || (appConfig.configMap != _|_) {
			name: "config"
			configMap: {
				name: _volumeConfig.configVolumeConfigMapName | *"\(appName)-config"
				// If configMap provides specific items to mount, use those
				if appConfig.configMap != _|_ && appConfig.configMap.mount != _|_ && appConfig.configMap.mount.items != _|_ {
					items: appConfig.configMap.mount.items
				}
			}
		},
	]

	_cacheVolumes: [
		if (_volumeConfig.enableCacheVolume | *false) {
			let cacheSettings = _volumeConfig.cacheVolumeSettings | *base.#DefaultCacheVolumeSettings
			{
				name: "cache"
				emptyDir: {
					medium:    cacheSettings.medium
					sizeLimit: cacheSettings.sizeLimit
				}
			}
		},
	]

	// Build projected secrets volume using helper
	_projectedSecretsHelper: _projectedSecretsVolumeBuilder & {
		let projConfig = _volumeConfig.projectedSecretsConfig | *{}

		enabled:            _volumeConfig.enableProjectedSecretsVolume | *false
		secretItems:        projConfig.secretItems | *base.#DefaultProjectedSecretItems
		configMapItems:     projConfig.configMapItems | *base.#DefaultProjectedConfigMapItems
		clusterCAItems:     projConfig.clusterCAItems | *base.#DefaultProjectedClusterCAItems
		includeDownwardAPI: projConfig.includeDownwardAPI | *true

		// Provide volume source names with defaults based on appName
		configMapName:      appConfig.deployment.volumeSourceNames.configMapName | *"\(appName)-config"
		secretName:         appConfig.deployment.volumeSourceNames.secretName | *"\(appName)-secrets"
		clusterCAConfigMap: appConfig.deployment.clusterCAConfigMap | *"\(appName)-cluster-ca"
	}

	_projectedSecretsVolumes: _projectedSecretsHelper.volume

	_additionalVolumes: _volumeConfig.additionalVolumes | *[]

	// Build volume mounts list
	_volumeMounts: list.Concat([
		_dataVolumeMounts,
		_configVolumeMounts,
		_cacheVolumeMounts,
		_projectedSecretsVolumeMounts,
		_additionalVolumeMounts,
	])

	_dataVolumeMounts: [
		if (_volumeConfig.enableDataVolume | *false) {
			base.#DefaultDataVolumeMount
		},
	]

	_configVolumeMounts: [
		// Config volume mount is enabled if:
		// 1. Explicitly enabled via volumeConfig.enableConfigVolume, OR
		// 2. configMap is provided (which auto-creates the ConfigMap)
		if (_volumeConfig.enableConfigVolume | *false) || (appConfig.configMap != _|_) {
			base.#DefaultConfigVolumeMount & {
				if appConfig.configMap != _|_ && appConfig.configMap.mount != _|_ {
					let mountConfig = appConfig.configMap.mount
					{
						mountPath: mountConfig.path
						readOnly:  mountConfig.readOnly
						if mountConfig.subPath != _|_ {
							subPath: mountConfig.subPath
						}
					}
				}
			}
		},
	]

	_cacheVolumeMounts: [
		if (_volumeConfig.enableCacheVolume | *false) {
			base.#DefaultCacheVolumeMount
		},
	]

	_projectedSecretsVolumeMounts: [
		if (_volumeConfig.enableProjectedSecretsVolume | *false) {
			base.#DefaultProjectedSecretsVolumeMount
		},
	]

	_additionalVolumeMounts: _volumeConfig.additionalVolumeMounts | *[]

	// Helper to select base probes based on HTTPS setting
	_baseProbes: {
		liveness: [
			if appConfig.enableHttps {base.#DefaultHttpsLivenessProbe},
			if !appConfig.enableHttps {base.#DefaultLivenessProbe},
		][0]
		readiness: [
			if appConfig.enableHttps {base.#DefaultHttpsReadinessProbe},
			if !appConfig.enableHttps {base.#DefaultReadinessProbe},
		][0]
	}

	// The actual Deployment resource
	deployment: k8s.#Deployment & {
		metadata: {
			name:      appName
			namespace: appConfig.namespace
			labels:    _labels
			if appConfig.deployment.annotations != _|_ {
				annotations: appConfig.deployment.annotations
			}
		}

		spec: {
			replicas: appConfig.deployment.replicas

			selector: matchLabels: _labels

			// Deployment strategy with defaults
			if appConfig.deployment.strategy != _|_ {
				strategy: appConfig.deployment.strategy
			}
			if appConfig.deployment.strategy == _|_ {
				strategy: base.#DefaultDeploymentStrategy
			}

			template: {
				metadata: {
					labels: _labels
					if appConfig.deployment.podAnnotations != _|_ {
						annotations: appConfig.deployment.podAnnotations
					}
				}

				spec: {
					containers: [{
						name:            appName
						image:           appConfig.deployment.image
						imagePullPolicy: "Always"

						if len(_env) > 0 {
							env: _env
						}

						envFrom: _envFrom

						ports: _containerPorts

						volumeMounts: _volumeMounts

						// Only include resources if defined (avoids rendering empty resources: {})
						if appConfig.deployment.resources != _|_ {
							resources: appConfig.deployment.resources
						}

						// Liveness probe with smart defaults - merges user settings with defaults
						livenessProbe: _baseProbes.liveness & (appConfig.deployment.livenessProbe | {})

						// Readiness probe with smart defaults - merges user settings with defaults
						readinessProbe: _baseProbes.readiness & (appConfig.deployment.readinessProbe | {})

						securityContext: base.#DefaultContainerSecurityContext
					}]

					volumes: _volumes

					if appConfig.deployment.nodeSelector != _|_ {
						nodeSelector: appConfig.deployment.nodeSelector
					}

					if appConfig.deployment.priorityClassName != _|_ {
						priorityClassName: appConfig.deployment.priorityClassName
					}

					if appConfig.deployment.affinity != _|_ {
						affinity: appConfig.deployment.affinity
					}

					securityContext: base.#DefaultPodSecurityContext

					// ServiceAccount is optional - only set if explicitly configured
					if appConfig.deployment.serviceAccountName != _|_ {
						serviceAccountName: appConfig.deployment.serviceAccountName
					}
				}
			}
		}
	}
}
