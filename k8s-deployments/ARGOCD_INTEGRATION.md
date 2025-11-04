# ArgoCD Application Integration

This document describes the ArgoCD Application integration that brings GitOps best practices to the deployment pipeline.

## Overview

ArgoCD Application resources are now fully integrated into the CUE-based deployment system. All Application definitions are:
- ✅ Version-controlled in Git
- ✅ Generated from CUE configuration
- ✅ Managed using the App-of-Apps pattern
- ✅ Automatically synced by ArgoCD

## Architecture

### Directory Structure

```
k8s-deployments/
├── argocd/                         # ArgoCD CUE schemas and templates
│   ├── schema.cue                  # #ArgoAppConfig schema
│   ├── defaults.cue                # Default values and constants
│   └── application.cue             # #ArgoApplication template
│
├── argocd-bootstrap/               # Bootstrap configuration
│   ├── bootstrap-app.yaml          # Root Application (App of Apps)
│   ├── apply-bootstrap.sh          # Helper script to apply bootstrap
│   └── README.md                   # Bootstrap documentation
│
├── envs/                           # Environment configurations
│   ├── dev.cue                     # Dev config (app + argocd app)
│   ├── stage.cue                   # Stage config (app + argocd app)
│   └── prod.cue                    # Prod config (app + argocd app)
│
├── manifests/
│   ├── dev/                        # Generated K8s resources for dev
│   ├── stage/                      # Generated K8s resources for stage
│   ├── prod/                       # Generated K8s resources for prod
│   └── argocd/                     # Generated ArgoCD Applications
│       ├── example-app-dev.yaml
│       ├── example-app-stage.yaml
│       └── example-app-prod.yaml
│
└── scripts/
    └── generate-manifests.sh       # Generates K8s + ArgoCD manifests
```

### How It Works

1. **CUE Configuration**: Define ArgoCD applications in environment configs
2. **Generation**: Run `generate-manifests.sh` to create YAML manifests
3. **Git Commit**: Commit generated manifests to Git
4. **Bootstrap Sync**: Bootstrap Application watches `manifests/argocd/`
5. **Application Creation**: ArgoCD creates/updates Application resources
6. **Application Sync**: Each Application deploys its resources

```
┌─────────────────┐
│  Environment    │
│  Config (CUE)   │
│                 │
│  dev.cue        │
│  - exampleApp   │
│  - argoApp      │
└────────┬────────┘
         │
         │ generate-manifests.sh
         ▼
┌─────────────────────────────────┐
│  Generated Manifests            │
│                                 │
│  manifests/dev/                 │
│  - Deployment, Service, etc.    │
│                                 │
│  manifests/argocd/              │
│  - example-app-dev.yaml         │
└────────┬────────────────────────┘
         │
         │ git commit & push
         ▼
┌─────────────────────────────────┐
│  Git Repository                 │
│  (Single Source of Truth)       │
└────────┬────────────────────────┘
         │
         │ ArgoCD watches
         ▼
┌─────────────────────────────────┐
│  Bootstrap Application          │
│  (App of Apps)                  │
│                                 │
│  Manages all Applications       │
└────────┬────────────────────────┘
         │
         │ Creates/Updates
         ▼
┌─────────────────────────────────┐
│  ArgoCD Applications            │
│                                 │
│  - example-app-dev              │
│  - example-app-stage            │
│  - example-app-prod             │
└────────┬────────────────────────┘
         │
         │ Deploys
         ▼
┌─────────────────────────────────┐
│  Kubernetes Resources           │
│                                 │
│  dev, stage, prod namespaces    │
└─────────────────────────────────┘
```

## CUE Schema

### ArgoAppConfig Schema

Located in `argocd/schema.cue`:

```cue
#ArgoAppConfig: {
    // Identity
    app:         string
    environment: string

    // Git source
    repoURL:        string
    targetRevision: string
    path:           string

    // Destination
    namespace: string
    server:    string | *"https://kubernetes.default.svc"

    // Configuration
    project:           string | *"default"
    syncPolicy:        {...}
    ignoreDifferences?: [...]
}
```

### Default Values

Located in `argocd/defaults.cue`:

- `#DefaultSyncPolicy`: Automated sync with prune and self-heal
- `#DefaultIgnoreDifferences`: Ignore Deployment replica changes
- `#DefaultArgoAppLabels`: Standard labels (app, environment)
- `#DefaultGitLabRepoBase`: GitLab server URL

## Usage

### Initial Setup

1. **Generate ArgoCD Application manifests**:
   ```bash
   cd k8s-deployments
   ./scripts/generate-manifests.sh dev
   ./scripts/generate-manifests.sh stage
   ./scripts/generate-manifests.sh prod
   ```

2. **Commit to Git**:
   ```bash
   git add manifests/argocd/
   git commit -m "Add ArgoCD Application definitions"
   git push
   ```

3. **Apply Bootstrap Application**:
   ```bash
   # Option 1: Use helper script
   ./argocd-bootstrap/apply-bootstrap.sh

   # Option 2: Manual apply
   kubectl apply -f argocd-bootstrap/bootstrap-app.yaml
   ```

4. **Verify**:
   ```bash
   # Check bootstrap application
   kubectl get application bootstrap -n argocd

   # Watch applications being created
   kubectl get applications -n argocd -w

   # Check all applications
   kubectl get applications -n argocd
   ```

### Adding a New Application

1. **Create app configuration** in `services/apps/new-app.cue`:
   ```cue
   package apps

   import "deployments.local/k8s-deployments/services/core"

   newApp: core.#App & {
       appName: "new-app"
   }
   ```

2. **Add to environment configs** (e.g., `envs/dev.cue`):
   ```cue
   // K8s resources
   dev: newApp: apps.newApp & {
       appConfig: {
           namespace: "dev"
           deployment: {
               image: "docker.local/example/new-app:latest"
               replicas: 1
           }
       }
   }

   // ArgoCD Application
   dev: newAppArgo: argocd.#ArgoApplication & {
       argoConfig: {
           app:         "new-app"
           environment: "dev"
           namespace:   "dev"
           repoURL:        "\(argocd.#DefaultGitLabRepoBase)/example/k8s-deployments.git"
           targetRevision: "dev"
           path:           "manifests/dev"
           syncPolicy:        argocd.#DefaultSyncPolicy
           ignoreDifferences: argocd.#DefaultIgnoreDifferences
       }
   }
   ```

3. **Generate and commit**:
   ```bash
   ./scripts/generate-manifests.sh dev
   git add .
   git commit -m "Add new-app to dev environment"
   git push
   ```

4. **ArgoCD automatically creates the new Application**

### Modifying Application Configuration

1. Update CUE config in `envs/{env}.cue`
2. Regenerate: `./scripts/generate-manifests.sh {env}`
3. Commit and push
4. ArgoCD automatically syncs changes

### Removing an Application

1. Remove config from `envs/{env}.cue`
2. Regenerate manifests (removes YAML from `manifests/argocd/`)
3. Commit and push
4. ArgoCD prunes the Application

## Configuration Options

### Sync Policy Customization

Override the default sync policy per environment:

```cue
dev: argoApp: argocd.#ArgoApplication & {
    argoConfig: {
        // ... other config
        syncPolicy: {
            automated: {
                prune: false      // Disable auto-prune in dev
                selfHeal: true
                allowEmpty: false
            }
            syncOptions: [
                "CreateNamespace=true",
                "PruneLast=true",
                "RespectIgnoreDifferences=true",
            ]
        }
    }
}
```

### Ignore Differences Customization

Add custom ignore rules:

```cue
dev: argoApp: argocd.#ArgoApplication & {
    argoConfig: {
        // ... other config
        ignoreDifferences: [
            {
                group: "apps"
                kind:  "Deployment"
                jsonPointers: ["/spec/replicas"]
            },
            {
                group: ""
                kind:  "Service"
                jsonPointers: ["/spec/clusterIP"]
            },
        ]
    }
}
```

### Multi-Repo Support

Point to a different repository:

```cue
dev: argoApp: argocd.#ArgoApplication & {
    argoConfig: {
        app:         "external-app"
        environment: "dev"
        namespace:   "dev"
        repoURL:        "https://github.com/example/external-app.git"
        targetRevision: "main"
        path:           "k8s/"
        // ... other config
    }
}
```

## Benefits

1. **Version Control**: All ArgoCD configurations in Git with full history
2. **Code Review**: Changes go through merge request process
3. **Consistency**: Same CUE patterns for apps and ArgoCD configs
4. **Reproducibility**: Easy to recreate in new clusters
5. **Automation**: Changes automatically applied by ArgoCD
6. **Self-Healing**: Manual changes automatically reverted
7. **Audit Trail**: Complete history of what was deployed when

## Troubleshooting

### Applications not syncing

```bash
# Check bootstrap app
kubectl describe application bootstrap -n argocd

# Check app controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Force sync
argocd app sync bootstrap
```

### CUE export errors

```bash
# Validate CUE configuration
cue vet ./envs/dev.cue

# Test export manually
cue export ./envs/dev.cue -e dev.argoApp.application --out yaml
```

### Generated manifests incorrect

```bash
# Clean and regenerate
rm -rf manifests/argocd/*.yaml
./scripts/generate-manifests.sh dev
./scripts/generate-manifests.sh stage
./scripts/generate-manifests.sh prod
```

## Next Steps

1. **Migrate existing applications**: Add ArgoCD configs for other apps
2. **Setup CI/CD**: Automate manifest generation in pipeline
3. **Enable notifications**: Configure ArgoCD notifications for sync events
4. **Add ApplicationSets**: For managing multiple similar applications
5. **Implement RBAC**: Use ArgoCD Projects for access control
6. **Add health checks**: Custom health checks for application resources
7. **Setup SSO**: Integrate ArgoCD with identity provider

## References

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [CUE Language](https://cuelang.org/docs/)
- [GitOps Principles](https://opengitops.dev/)
