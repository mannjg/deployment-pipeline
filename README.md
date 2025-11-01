# Kubernetes Deployments Repository

This repository contains CUE-based Kubernetes deployment configurations for all applications in the CI/CD pipeline.

## Structure

```
k8s-deployments/
├── cue.mod/               # CUE module definition
│   └── module.cue
├── k8s/                   # Kubernetes resource schemas
│   ├── deployment.cue
│   ├── service.cue
│   └── configmap.cue
├── services/
│   ├── base/              # Base schemas and defaults
│   │   ├── schema.cue
│   │   └── defaults.cue
│   ├── core/              # Core application templates
│   │   └── app.cue
│   └── apps/              # Application-specific configurations
│       └── example-app.cue
├── envs/                  # Environment-specific configurations
│   ├── dev.cue            # Development environment
│   ├── stage.cue          # Staging environment
│   └── prod.cue           # Production environment
├── manifests/             # Generated Kubernetes YAML manifests
│   ├── dev/
│   ├── stage/
│   └── prod/
├── scripts/
│   └── generate-manifests.sh  # Manifest generation script
└── README.md

```

## Git Branch Strategy

This repository uses a **branch-per-environment** strategy:

- `dev` branch → dev namespace → Auto-synced by ArgoCD
- `stage` branch → stage namespace → Auto-synced by ArgoCD
- `prod` branch → prod namespace → Auto-synced by ArgoCD

## Workflow

### 1. Automatic Updates (CI/CD)

When code is merged to main in an application repository:

1. Jenkins builds and publishes the Docker image
2. Jenkins updates the `dev` branch with new image reference
3. ArgoCD detects the change and syncs to dev namespace
4. Jenkins creates a draft MR: dev → stage

### 2. Manual Promotion

To promote from dev to stage (or stage to prod):

1. Review the MR showing the complete diff
2. Undraft and merge the MR
3. ArgoCD automatically syncs to target environment
4. (Optional) Jenkins creates next promotion MR

## CUE Configuration

### Application Configuration (`services/apps/example-app.cue`)

Defines application-level settings that apply across all environments:
- Application name
- App-level environment variables
- Default configuration

### Environment Configuration (`envs/*.cue`)

Defines environment-specific overrides:
- Namespace
- Replica count
- Resource limits
- Environment-specific variables
- Debug mode settings

## Generating Manifests

### Manually Generate Manifests

```bash
# Generate for dev
./scripts/generate-manifests.sh dev

# Generate for stage
./scripts/generate-manifests.sh stage

# Generate for prod
./scripts/generate-manifests.sh prod
```

### Validate CUE Configuration

```bash
# Validate all configurations
cue vet ./...

# Export dev configuration
cue export ./envs/dev.cue --path dev

# Show diff between environments
diff <(cue export ./envs/dev.cue --path dev) <(cue export ./envs/stage.cue --path stage)
```

## ArgoCD Applications

Each environment has its own ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example-app-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://gitlab.local/root/k8s-deployments.git
    targetRevision: dev
    path: manifests/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Adding a New Application

1. **Create application CUE file**: `services/apps/<app-name>.cue`

```cue
package apps

import (
	core "deployments.local/k8s-deployments/services/core"
)

myApp: core.#App & {
	appName: "my-app"
	appEnvVars: [...]
	appConfig: {...}
}
```

2. **Add to environment files**: Update `envs/dev.cue`, `envs/stage.cue`, `envs/prod.cue`

```cue
dev: myApp: apps.myApp & {
	appConfig: {
		namespace: "dev"
		deployment: {
			image: "nexus.local:5000/my-app:latest"
			replicas: 1
			...
		}
	}
}
```

3. **Generate manifests**:

```bash
./scripts/generate-manifests.sh dev
```

4. **Commit and push**:

```bash
git add .
git commit -m "Add my-app configuration"
git push origin dev
```

5. **Create ArgoCD Application** (see docs)

## Troubleshooting

### CUE Validation Errors

```bash
# Check for errors
cue vet ./...

# Format CUE files
cue fmt ./...
```

### Manifest Generation Fails

```bash
# Verbose CUE export
cue export -v ./envs/dev.cue --path dev

# Check specific app
cue export ./services/apps/example-app.cue
```

### ArgoCD Sync Issues

```bash
# Check ArgoCD status
argocd app get example-app-dev

# Manual sync
argocd app sync example-app-dev

# View diff
argocd app diff example-app-dev
```

## Resources

- [CUE Language Documentation](https://cuelang.org/docs/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

## License

Example deployment repository for CI/CD pipeline demonstration.
