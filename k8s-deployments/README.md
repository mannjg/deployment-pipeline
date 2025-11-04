# Kubernetes Deployments Repository

This repository contains CUE-based Kubernetes deployment configurations for all applications in the CI/CD pipeline.

## Status

**CUE Integration**: ✅ Complete (Build #32 verified)
- Dynamic manifest generation from CUE configuration
- No Python dependencies (pure CUE + bash)
- Integrated with Jenkins CI/CD pipeline
- Auto-deployment via ArgoCD

## Structure

```
k8s-deployments/
├── cue.mod/               # CUE module definition
│   └── module.cue         # Module: deployments.local/k8s-deployments
├── k8s/                   # Kubernetes resource schemas (imported from upstream)
│   ├── deployment.cue
│   ├── service.cue
│   └── configmap.cue
├── services/
│   ├── base/              # Base schemas and defaults
│   │   ├── schema.cue     # #AppConfig schema
│   │   └── defaults.cue   # Default values for resources
│   ├── resources/         # Resource templates (NEW)
│   │   ├── deployment.cue # #DeploymentTemplate
│   │   ├── service.cue    # #ServiceTemplate, #DebugServiceTemplate
│   │   └── configmap.cue  # #ConfigMapTemplate
│   ├── core/              # Core application templates
│   │   └── app.cue        # #App template with resources_list
│   └── apps/              # Application-specific configurations
│       └── example-app.cue
├── envs/                  # Environment-specific configurations
│   ├── dev.cue            # Development environment
│   ├── stage.cue          # Staging environment
│   └── prod.cue           # Production environment
├── manifests/             # Generated Kubernetes YAML manifests
│   ├── dev/
│   │   └── example-app.yaml
│   ├── stage/
│   └── prod/
├── scripts/
│   └── generate-manifests.sh  # Manifest generation using resources_list
└── README.md

```

## Git Branch Strategy

This repository uses a **branch-per-environment** strategy:

- `dev` branch → dev namespace → Auto-synced by ArgoCD
- `stage` branch → stage namespace → Auto-synced by ArgoCD
- `prod` branch → prod namespace → Auto-synced by ArgoCD

## Workflow

### 1. Automatic Updates (CI/CD) - **NOW ACTIVE**

When code is merged to main in an application repository:

1. **Jenkins builds and publishes Docker image**
   - Builds application with Maven/Quarkus
   - Publishes to Nexus Docker registry (nexus.local:5000)
   - Publishes Maven artifact to Nexus

2. **Jenkins updates CUE configuration**
   - Clones k8s-deployments repository (dev branch)
   - Updates `envs/dev.cue` with new image tag
   - Runs `./scripts/generate-manifests.sh dev`
   - Commits and pushes to dev branch

3. **Manifest generation** (scripts/generate-manifests.sh)
   - Queries `resources_list` from CUE to discover resources
   - Exports individual resources: `-e dev.exampleApp.resources.<resource>`
   - CUE automatically formats with `---` separators
   - Generates `manifests/dev/example-app.yaml`

4. **ArgoCD auto-sync**
   - Detects changes in dev branch
   - Syncs to dev namespace
   - Application updated automatically

5. **Promotion MR creation** (placeholder)
   - Jenkins creates draft MR: dev → stage
   - Ready for manual review and promotion

### 2. Manual Promotion (Future)

To promote from dev to stage (or stage to prod):

1. Review the MR showing the complete diff
2. Undraft and merge the MR
3. ArgoCD automatically syncs to target environment
4. (Optional) Jenkins creates next promotion MR

## CUE Configuration

The configuration is split into layers for maximum reusability:

### 1. Resource Templates (`services/resources/`)

Reusable templates for Kubernetes resources:

- **deployment.cue**: `#DeploymentTemplate` - Generates Deployment resources
- **service.cue**: `#ServiceTemplate`, `#DebugServiceTemplate` - Generates Services
- **configmap.cue**: `#ConfigMapTemplate` - Generates ConfigMaps

### 2. Core Application Template (`services/core/app.cue`)

The `#App` template:
- Imports resource templates
- Generates resources based on configuration
- Defines `resources_list` for dynamic discovery
- Example: `resources_list: ["configmap", "debugService", "deployment", "service"]`

### 3. Application Configuration (`services/apps/example-app.cue`)

Defines application-level settings that apply across all environments:
- Application name
- App-level environment variables
- Default configuration
- Example: Quarkus-specific env vars

### 4. Environment Configuration (`envs/*.cue`)

Defines environment-specific overrides:
- Namespace
- Docker image tag (updated by Jenkins)
- Replica count
- Resource limits
- Environment-specific variables
- Debug mode settings

## Generating Manifests

### How Manifest Generation Works

The `generate-manifests.sh` script uses CUE's `resources_list` field for dynamic resource discovery:

1. **Query resources_list**: `cue export ./envs/dev.cue -e "dev.exampleApp.resources_list" --out json`
   - Returns: `["debugService", "deployment", "service"]`

2. **Build export flags**: `-e dev.exampleApp.resources.debugService -e dev.exampleApp.resources.deployment -e dev.exampleApp.resources.service`

3. **CUE exports resources**: `cue export ./envs/dev.cue <flags> --out yaml`
   - CUE automatically adds `---` separators between resources
   - No Python post-processing needed!

4. **Output**: Valid Kubernetes YAML ready for ArgoCD

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

# Show specific resource
cue export ./envs/dev.cue -e dev.exampleApp.resources.deployment

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
