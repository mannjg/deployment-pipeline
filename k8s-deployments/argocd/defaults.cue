// Package argocd provides default values for ArgoCD Application resources
package argocd

// Default ArgoCD namespace
#DefaultArgoNamespace: "argocd"

// Default cluster server
#DefaultClusterServer: "https://kubernetes.default.svc"

// Default project
#DefaultProject: "default"

// Default sync policy with automation enabled
#DefaultSyncPolicy: {
	automated: {
		prune:      true
		selfHeal:   true
		allowEmpty: false
	}
	syncOptions: [
		"CreateNamespace=true",
		"PruneLast=true",
	]
	retry: {
		limit: 5
		backoff: {
			duration:    "5s"
			factor:      2
			maxDuration: "3m"
		}
	}
}

// Default ignore differences for Deployment replicas
// HPA or manual scaling may modify replicas
#DefaultIgnoreDifferences: [
	{
		group: "apps"
		kind:  "Deployment"
		jsonPointers: ["/spec/replicas"]
	},
]

// Default labels for ArgoCD Application resources
#DefaultArgoAppLabels: {
	app:         string // Must be provided
	environment: string // Must be provided
}

// Default GitLab repository URL template
// Use with string interpolation: "\(#DefaultGitLabRepoBase)/\(repoPath)"
#DefaultGitLabRepoBase: "http://gitlab.gitlab.svc.cluster.local"
