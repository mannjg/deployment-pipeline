# ArgoCD Bootstrap - App of Apps

This directory contains the bootstrap ArgoCD Application that implements the "App of Apps" pattern.

## What is App of Apps?

The App of Apps pattern is a GitOps best practice where:
1. A single "bootstrap" Application manages all other Applications
2. All Application definitions are stored in Git
3. ArgoCD automatically syncs changes to Application definitions
4. The entire deployment configuration is version-controlled and auditable

## Directory Structure

```
argocd-bootstrap/
├── bootstrap-app.yaml      # Bootstrap Application (manages all apps)
└── README.md               # This file

manifests/argocd/
├── example-app-dev.yaml    # ArgoCD Application for dev environment
├── example-app-stage.yaml  # ArgoCD Application for stage environment
└── example-app-prod.yaml   # ArgoCD Application for prod environment
```

## Initial Setup

### Prerequisites
- ArgoCD installed in the cluster
- Git repository accessible from the cluster
- ArgoCD CLI (optional, for verification)

### Apply Bootstrap Application

**One-time setup:**

```bash
# Apply the bootstrap application
kubectl apply -f argocd-bootstrap/bootstrap-app.yaml

# Verify the bootstrap application was created
kubectl get application -n argocd bootstrap

# Watch ArgoCD sync the applications
kubectl get applications -n argocd -w
```

### Verify Applications

After applying the bootstrap, ArgoCD will automatically create all Application resources:

```bash
# List all applications
kubectl get applications -n argocd

# Check application status
kubectl get applications -n argocd -o wide

# Or use ArgoCD CLI
argocd app list
argocd app get bootstrap
```

## How It Works

1. **Bootstrap Application** watches `manifests/argocd/` directory
2. When you push changes to Application YAMLs in that directory:
   - Bootstrap detects the change
   - Automatically creates/updates/deletes Application resources
3. Each Application then manages its own resources in the target namespace

## Making Changes

### Adding a New Application

1. Create CUE configuration in `envs/{environment}.cue`:
   ```cue
   {env}: argoApp: argocd.#ArgoApplication & {
       argoConfig: {
           app: "new-app"
           environment: "{env}"
           // ... other config
       }
   }
   ```

2. Generate manifests:
   ```bash
   ./scripts/generate-manifests.sh dev
   ./scripts/generate-manifests.sh stage
   ./scripts/generate-manifests.sh prod
   ```

3. Commit and push to Git

4. ArgoCD automatically detects and creates the new Application

### Modifying an Application

1. Update CUE configuration in `envs/{environment}.cue`
2. Regenerate manifests with `./scripts/generate-manifests.sh {env}`
3. Commit and push
4. ArgoCD automatically syncs the changes

### Removing an Application

1. Remove ArgoCD config from `envs/{environment}.cue`
2. Regenerate manifests (this removes the YAML from `manifests/argocd/`)
3. Commit and push
4. ArgoCD automatically prunes the Application (if prune is enabled)

## Benefits

✅ **Version Control**: All ArgoCD Applications are in Git
✅ **Automated Sync**: Changes to Applications are automatically applied
✅ **Audit Trail**: Full history of what was deployed when
✅ **Self-Healing**: Manual changes are automatically reverted
✅ **Disaster Recovery**: Entire setup can be recreated from Git
✅ **Multi-Environment**: Easy to manage apps across dev/stage/prod

## Troubleshooting

### Bootstrap application not syncing

```bash
# Check bootstrap app status
kubectl describe application bootstrap -n argocd

# Force sync
argocd app sync bootstrap
```

### Applications not being created

```bash
# Check bootstrap app logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Verify manifests exist
ls -la manifests/argocd/

# Verify Git repo is accessible
argocd repo list
```

### Need to delete all applications

```bash
# Delete bootstrap (will cascade to all managed apps if finalizer is set)
kubectl delete application bootstrap -n argocd

# Or delete individually
kubectl delete applications -n argocd -l managed-by=argocd
```

## Security Notes

- The bootstrap app has `prune: true` - be careful when removing Applications
- Always review changes before pushing to the repository
- Use Git branches and merge requests for changes to production
- Consider using ArgoCD Projects to restrict what Applications can do
