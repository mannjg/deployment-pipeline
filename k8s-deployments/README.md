# Kubernetes Deployments Repository

CUE-based Kubernetes deployment configurations for all applications in the CI/CD pipeline.

## Configuration

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for required environment variables, Jenkins ConfigMap setup, and local development.

## Structure

```
k8s-deployments/
├── cue.mod/               # CUE module definition
├── schemas/               # Base Kubernetes resource type definitions
│   ├── configmap.cue
│   ├── deployment.cue
│   ├── pvc.cue
│   ├── secret.cue
│   └── service.cue
├── templates/
│   ├── base/              # Platform defaults and schema
│   │   ├── schema.cue     # #AppConfig schema
│   │   ├── defaults.cue   # Platform-wide defaults
│   │   └── helpers.cue    # CUE helper functions
│   ├── resources/         # Resource templates
│   │   ├── deployment.cue # #DeploymentTemplate
│   │   ├── service.cue    # #ServiceTemplate, #DebugServiceTemplate
│   │   ├── configmap.cue  # #ConfigMapTemplate
│   │   ├── pvc.cue        # #PVCTemplate
│   │   └── secret.cue     # #SecretTemplate
│   ├── core/              # Core application templates
│   │   └── app.cue        # #App template with resources_list
│   └── apps/              # Application-specific configurations
│       ├── example-app.cue
│       └── postgres.cue
├── scripts/               # Deployment and validation scripts
├── jenkins/               # Jenkins pipeline definitions and helpers
├── seed-env.cue           # Seed template (bootstrap only, not used at runtime)
├── Jenkinsfile
└── README.md
```

**Note:** `env.cue`, `envs/`, and `manifests/` directories exist only on environment branches in GitLab (dev/stage/prod), not on main.

## Git Branch Strategy

This repository uses a **branch-per-environment** strategy:

- `main` branch → Platform schemas, app definitions, seed template
- `dev` branch → dev namespace → Auto-synced by ArgoCD
- `stage` branch → stage namespace → Auto-synced by ArgoCD
- `prod` branch → prod namespace → Auto-synced by ArgoCD

## Workflow

### Automatic Updates (CI/CD)

When code is merged to main in an application repository:

1. **Jenkins builds and publishes Docker image**
   - Builds application with Maven/Quarkus
   - Publishes to container registry

2. **Jenkins updates CUE configuration**
   - Clones k8s-deployments repository (dev branch)
   - Updates image tag in `env.cue`
   - Runs `./scripts/generate-manifests.sh dev`
   - Commits and pushes to dev branch

3. **Manifest generation** (scripts/generate-manifests.sh)
   - Queries `resources_list` from CUE to discover resources dynamically
   - Exports each resource to YAML
   - Generates `manifests/<env>/<app>.yaml`

4. **ArgoCD auto-sync**
   - Detects changes on environment branch
   - Syncs to target namespace

5. **Promotion MR creation**
   - Jenkins creates MR: dev → stage (or stage → prod)
   - Merge triggers the same generate/sync cycle for the next environment

### Promotion

To promote from dev to stage (or stage to prod):

1. Review the MR showing the complete diff
2. Merge the MR
3. Jenkins regenerates manifests on the target branch
4. ArgoCD automatically syncs to target environment
5. Jenkins creates the next promotion MR

## CUE Configuration Layers

The configuration hierarchy (lower layers override higher):

### 1. Platform (`templates/base/`, `templates/core/`)
Platform-wide defaults: security contexts, deployment strategies, resource templates.

### 2. Resource Templates (`templates/resources/`)
Reusable templates that generate Kubernetes resources from `#AppConfig`.

### 3. Application (`templates/apps/`)
Application-level settings that apply across all environments.

### 4. Environment (`env.cue` on each branch)
Environment-specific overrides: namespace, image tag, replicas, resource limits.

## Generating Manifests

```bash
# Generate for an environment
./scripts/generate-manifests.sh dev

# Validate CUE configuration
cue vet ./...
```

## Adding a New Application

1. **Create application CUE file**: `templates/apps/<app-name>.cue`

```cue
package apps

import (
	core "deployments.local/k8s-deployments/templates/core"
)

myApp: core.#App & {
	appName: "my-app"
	appEnvVars: [...]
	appConfig: {...}
}
```

2. **Add to environment `env.cue`** on each branch with environment-specific overrides.

3. **Generate manifests**: `./scripts/generate-manifests.sh <env>`

4. **Create ArgoCD Application** for the new app in each environment.

## Troubleshooting

```bash
# Validate CUE
cue vet ./...

# Format CUE files
cue fmt ./...

# Verbose export for debugging
cue export -v ./... --out yaml
```

## Resources

- [CUE Language Documentation](https://cuelang.org/docs/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
