# ArgoCD Setup - Quick Reference

## Status: ✅ Installed and Configured

ArgoCD is deployed and the CLI is installed locally.

## Access Information

### ArgoCD Server
- **UI Access**: http://localhost:8080 (requires port-forward)
- **CLI Access**: `localhost:8080`
- **Username**: `admin`
- **Password**: `KofmrUFAJ7JeEiWr`

### Port-Forward Command
```bash
# Start port-forward (runs in background)
microk8s kubectl port-forward -n argocd svc/argocd-server 8080:80 > /dev/null 2>&1 &

# Check if running
ps aux | grep "kubectl.*port-forward.*argocd" | grep -v grep
```

## ArgoCD CLI

### Installation
ArgoCD CLI is installed at: `~/bin/argocd`

Make sure `~/bin` is in your PATH:
```bash
export PATH="$HOME/bin:$PATH"

# Add to ~/.bashrc for persistence
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

### Version
```bash
argocd version --client
# argocd: v3.1.9+8665140
```

## Common Commands

### Login
```bash
argocd login localhost:8080 --username admin --password KofmrUFAJ7JeEiWr --insecure
```

### List Applications
```bash
argocd app list
```

### Get Application Details
```bash
argocd app get example-app-dev
argocd app get example-app-stage
argocd app get example-app-prod
```

### Sync Application
```bash
argocd app sync example-app-dev
```

### Check Application Health
```bash
argocd app get example-app-dev --show-operation
```

### List Repositories
```bash
argocd repo list
```

### Add Repository
```bash
argocd repo add http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git \
    --username oauth2 \
    --password glpat-wsbb2YxLwxk3NJSBTMdZ \
    --insecure-skip-server-verification
```

## Cluster Information

### Check ArgoCD Pods
```bash
microk8s kubectl get pods -n argocd
```

### Check ArgoCD Services
```bash
microk8s kubectl get svc -n argocd
```

### Get Initial Admin Password (if needed)
```bash
microk8s kubectl get secret -n argocd argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d && echo
```

## ArgoCD Applications

The following applications are configured in `/home/jmann/git/mannjg/deployment-pipeline/argocd/applications/`:

1. **example-app-dev.yaml** - Development environment
   - Namespace: `dev`
   - Branch: `dev`
   - Auto-sync: Enabled

2. **example-app-stage.yaml** - Staging environment
   - Namespace: `stage`
   - Branch: `stage`
   - Auto-sync: Enabled

3. **example-app-prod.yaml** - Production environment
   - Namespace: `prod`
   - Branch: `prod`
   - Auto-sync: Enabled

### Deploy Applications
```bash
# Deploy all environments
microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/

# Or individually
microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/example-app-dev.yaml
microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/example-app-stage.yaml
microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/example-app-prod.yaml
```

## Web UI Access

1. Make sure port-forward is running
2. Open browser: http://localhost:8080
3. Login with:
   - Username: `admin`
   - Password: `KofmrUFAJ7JeEiWr`

## Troubleshooting

### Port-forward not working
```bash
# Kill existing port-forward
pkill -f "kubectl.*port-forward.*argocd"

# Restart
microk8s kubectl port-forward -n argocd svc/argocd-server 8080:80 > /dev/null 2>&1 &
```

### CLI not found
```bash
# Check if ~/bin is in PATH
echo $PATH | grep -q "$HOME/bin" && echo "OK" || echo "Add ~/bin to PATH"

# Add to PATH temporarily
export PATH="$HOME/bin:$PATH"

# Verify CLI exists
ls -la ~/bin/argocd
```

### Login issues
```bash
# Re-login
argocd logout localhost:8080
argocd login localhost:8080 --username admin --password KofmrUFAJ7JeEiWr --insecure
```

### Check ArgoCD server status
```bash
# Check pods are running
microk8s kubectl get pods -n argocd

# Check server logs
microk8s kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

## Next Steps

1. ✅ ArgoCD CLI installed
2. ✅ Port-forward configured
3. ✅ Logged in successfully
4. ⏳ Add GitLab repository (Section 2.4, Step 5)
5. ⏳ Deploy ArgoCD applications (Section 2.4, Step 6)
6. ⏳ Verify applications sync

## Related Documentation

- Implementation Guide: `/home/jmann/git/mannjg/deployment-pipeline/IMPLEMENTATION_GUIDE.md` (Section 2.4)
- GitLab Verification: `/home/jmann/git/mannjg/deployment-pipeline/GITLAB_VERIFICATION_REPORT.md`
- Docker Registry Guide: `/home/jmann/git/mannjg/deployment-pipeline/DOCKER_REGISTRY_GUIDE.md`
