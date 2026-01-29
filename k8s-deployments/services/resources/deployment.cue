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
	enabled: bool | *true
	secretItems: [...{key: string, path: string}] | *base.#DefaultProjectedSecretItems
	configMapItems: [...{key: string, path: string}] | *base.#DefaultProjectedConfigMapItems
	clusterCAItems: [...{key: string, path: string}] | *base.#DefaultProjectedClusterCAItems
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

	// Default pod annotations (provided by app.cue)
	// Merged with appConfig.deployment.podAnnotations
	defaultPodAnnotations: [string]: string

	// Selector labels - only immutable identifying labels
	// These MUST NOT change after deployment creation (K8s selector is immutable)
	_selectorLabels: {
		app:        appName
		deployment: appName
	}

	// Default labels (can be extended via appConfig.labels)
	_defaultLabels: _selectorLabels

	// Computed labels - merge defaults with config
	// Used for metadata and pod template labels (can include additional labels)
	_labels: _defaultLabels & appConfig.labels

	// Computed pod annotations - merge platform defaults with app-specific
	// Note: Must use conditional check since optional fields with disjunction don't work as expected
	_podAnnotations: defaultPodAnnotations & {
		if appConfig.deployment.podAnnotations != _|_ {
			appConfig.deployment.podAnnotations
		}
	}

	// Computed env - merge by name: app-level defaults + environment-specific
	// Note: appEnvVars includes system defaults (like DEBUG) computed in app.cue
	// additionalEnv overrides appEnvVars for matching names (last wins)
	_env: (base.#MergeEnvVars & {
		app:        appEnvVars
		additional: appConfig.deployment.additionalEnv
	}).out

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

	// Check if app config specifies non-HTTP probe handlers (exec or tcpSocket)
	// These are mutually exclusive with httpGet, so base httpGet must be excluded
	_livenessHasNonHttpHandler:  (appConfig.deployment.livenessProbe.exec != _|_) || (appConfig.deployment.livenessProbe.tcpSocket != _|_)
	_readinessHasNonHttpHandler: (appConfig.deployment.readinessProbe.exec != _|_) || (appConfig.deployment.readinessProbe.tcpSocket != _|_)

	// Select default httpGet handlers based on HTTPS setting
	_defaultLivenessHttpGet: {
		if appConfig.enableHttps {
			base.#DefaultHttpsLivenessHttpGet
		}
		if !appConfig.enableHttps {
			base.#DefaultLivenessHttpGet
		}
	}
	_defaultReadinessHttpGet: {
		if appConfig.enableHttps {
			base.#DefaultHttpsReadinessHttpGet
		}
		if !appConfig.enableHttps {
			base.#DefaultReadinessHttpGet
		}
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

			selector: matchLabels: _selectorLabels

			// Deployment strategy with defaults
			if appConfig.deployment.strategy != _|_ {
				strategy: appConfig.deployment.strategy
			}
			if appConfig.deployment.strategy == _|_ {
				strategy: base.#DefaultDeploymentStrategy
			}

			template: {
				metadata: {
					labels:      _labels
					annotations: _podAnnotations
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

						// Liveness probe - uses conditional pattern (like strategy) to avoid
						// CUE default conflicts. Each field: use appConfig if defined, else base.
						livenessProbe: {
							// Handler: use appConfig's handler if specified, else default httpGet
							if _livenessHasNonHttpHandler && appConfig.deployment.livenessProbe.exec != _|_ {
								exec: appConfig.deployment.livenessProbe.exec
							}
							if _livenessHasNonHttpHandler && appConfig.deployment.livenessProbe.tcpSocket != _|_ {
								tcpSocket: appConfig.deployment.livenessProbe.tcpSocket
							}
							if !_livenessHasNonHttpHandler {
								// Use appConfig httpGet fields if specified, else defaults
								httpGet: {
									if appConfig.deployment.livenessProbe.httpGet.path != _|_ {
										path: appConfig.deployment.livenessProbe.httpGet.path
									}
									if appConfig.deployment.livenessProbe.httpGet.path == _|_ {
										path: _defaultLivenessHttpGet.path
									}
									if appConfig.deployment.livenessProbe.httpGet.port != _|_ {
										port: appConfig.deployment.livenessProbe.httpGet.port
									}
									if appConfig.deployment.livenessProbe.httpGet.port == _|_ {
										port: _defaultLivenessHttpGet.port
									}
									if appConfig.deployment.livenessProbe.httpGet.scheme != _|_ {
										scheme: appConfig.deployment.livenessProbe.httpGet.scheme
									}
									if appConfig.deployment.livenessProbe.httpGet.scheme == _|_ {
										scheme: _defaultLivenessHttpGet.scheme
									}
								}
							}

							// Timing fields: use appConfig if defined, else base default
							if appConfig.deployment.livenessProbe.initialDelaySeconds != _|_ {
								initialDelaySeconds: appConfig.deployment.livenessProbe.initialDelaySeconds
							}
							if appConfig.deployment.livenessProbe.initialDelaySeconds == _|_ {
								initialDelaySeconds: base.#DefaultLivenessProbeTimings.initialDelaySeconds
							}
							if appConfig.deployment.livenessProbe.periodSeconds != _|_ {
								periodSeconds: appConfig.deployment.livenessProbe.periodSeconds
							}
							if appConfig.deployment.livenessProbe.periodSeconds == _|_ {
								periodSeconds: base.#DefaultLivenessProbeTimings.periodSeconds
							}
							if appConfig.deployment.livenessProbe.timeoutSeconds != _|_ {
								timeoutSeconds: appConfig.deployment.livenessProbe.timeoutSeconds
							}
							if appConfig.deployment.livenessProbe.timeoutSeconds == _|_ {
								timeoutSeconds: base.#DefaultLivenessProbeTimings.timeoutSeconds
							}
							if appConfig.deployment.livenessProbe.failureThreshold != _|_ {
								failureThreshold: appConfig.deployment.livenessProbe.failureThreshold
							}
							if appConfig.deployment.livenessProbe.failureThreshold == _|_ {
								failureThreshold: base.#DefaultLivenessProbeTimings.failureThreshold
							}
						}

						// Readiness probe - same conditional pattern as liveness
						readinessProbe: {
							// Handler: use appConfig's handler if specified, else default httpGet
							if _readinessHasNonHttpHandler && appConfig.deployment.readinessProbe.exec != _|_ {
								exec: appConfig.deployment.readinessProbe.exec
							}
							if _readinessHasNonHttpHandler && appConfig.deployment.readinessProbe.tcpSocket != _|_ {
								tcpSocket: appConfig.deployment.readinessProbe.tcpSocket
							}
							if !_readinessHasNonHttpHandler {
								// Use appConfig httpGet fields if specified, else defaults
								httpGet: {
									if appConfig.deployment.readinessProbe.httpGet.path != _|_ {
										path: appConfig.deployment.readinessProbe.httpGet.path
									}
									if appConfig.deployment.readinessProbe.httpGet.path == _|_ {
										path: _defaultReadinessHttpGet.path
									}
									if appConfig.deployment.readinessProbe.httpGet.port != _|_ {
										port: appConfig.deployment.readinessProbe.httpGet.port
									}
									if appConfig.deployment.readinessProbe.httpGet.port == _|_ {
										port: _defaultReadinessHttpGet.port
									}
									if appConfig.deployment.readinessProbe.httpGet.scheme != _|_ {
										scheme: appConfig.deployment.readinessProbe.httpGet.scheme
									}
									if appConfig.deployment.readinessProbe.httpGet.scheme == _|_ {
										scheme: _defaultReadinessHttpGet.scheme
									}
								}
							}

							// Timing fields: use appConfig if defined, else base default
							if appConfig.deployment.readinessProbe.initialDelaySeconds != _|_ {
								initialDelaySeconds: appConfig.deployment.readinessProbe.initialDelaySeconds
							}
							if appConfig.deployment.readinessProbe.initialDelaySeconds == _|_ {
								initialDelaySeconds: base.#DefaultReadinessProbeTimings.initialDelaySeconds
							}
							if appConfig.deployment.readinessProbe.periodSeconds != _|_ {
								periodSeconds: appConfig.deployment.readinessProbe.periodSeconds
							}
							if appConfig.deployment.readinessProbe.periodSeconds == _|_ {
								periodSeconds: base.#DefaultReadinessProbeTimings.periodSeconds
							}
							if appConfig.deployment.readinessProbe.timeoutSeconds != _|_ {
								timeoutSeconds: appConfig.deployment.readinessProbe.timeoutSeconds
							}
							if appConfig.deployment.readinessProbe.timeoutSeconds == _|_ {
								timeoutSeconds: base.#DefaultReadinessProbeTimings.timeoutSeconds
							}
							if appConfig.deployment.readinessProbe.failureThreshold != _|_ {
								failureThreshold: appConfig.deployment.readinessProbe.failureThreshold
							}
							if appConfig.deployment.readinessProbe.failureThreshold == _|_ {
								failureThreshold: base.#DefaultReadinessProbeTimings.failureThreshold
							}
						}

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
