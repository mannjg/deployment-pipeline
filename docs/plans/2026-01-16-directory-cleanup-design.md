# Directory Cleanup and Reorganization

## Summary

Remove orphaned directories (`./argocd/`, `./deployment/`) and consolidate Jenkins agent files into `k8s/jenkins/agent/` for a consistent infrastructure layout.

## Background

The repository has accumulated orphaned directories from earlier development phases:
- `./argocd/` - Superseded by `k8s/argocd/`, not referenced by any current scripts
- `./deployment/` - Superseded by `example-app/deployment/`, orphaned
- `./jenkins/` - Active but misplaced at root level instead of under `k8s/`
- `example-app/jenkins/Dockerfile.agent` - Stale duplicate of `./jenkins/Dockerfile.agent`

## Changes

### 1. Delete Orphaned Directories

**Remove `./argocd/`:**
- `argocd/applications/example-app-dev.yaml`
- `argocd/applications/example-app-stage.yaml`
- `argocd/applications/example-app-prod.yaml`
- `argocd/applications/postgres-dev.yaml`
- `argocd/applications/postgres-stage.yaml`
- `argocd/applications/postgres-prod.yaml`
- `argocd/tls-secret.yaml`
- `argocd/ingress.yaml`
- `argocd/README.md`

**Remove `./deployment/`:**
- `deployment/app.cue`

### 2. Consolidate Jenkins Agent Files

**Move `./jenkins/*` → `k8s/jenkins/agent/`:**
- `jenkins/Dockerfile.agent` → `k8s/jenkins/agent/Dockerfile.agent`
- `jenkins/build-agent-image.sh` → `k8s/jenkins/agent/build-agent-image.sh`
- `jenkins/certs/internal-ca.crt` → `k8s/jenkins/agent/certs/internal-ca.crt`

**Update script reference:**
- `scripts/01-infrastructure/setup-jenkins.sh:48` - Update path from `./jenkins/build-agent-image.sh` to `./k8s/jenkins/agent/build-agent-image.sh`

**Update build script internal paths:**
- `k8s/jenkins/agent/build-agent-image.sh` - No changes needed (uses `$SCRIPT_DIR` for relative paths)

### 3. Remove Stale Duplicate

**Remove `example-app/jenkins/`:**
- `example-app/jenkins/Dockerfile.agent` - Stale (JDK17, no ArgoCD CLI, older CUE version)

## Resulting Structure

```
k8s/
├── argocd/
│   ├── ingress.yaml
│   └── install.yaml
├── cert-manager/
│   ├── cert-manager.yaml
│   └── cluster-issuer.yaml
├── gitlab/
│   ├── gitlab-lightweight.yaml
│   ├── root-password.txt
│   └── values.yaml
├── jenkins/
│   ├── agent/                    # NEW
│   │   ├── Dockerfile.agent
│   │   ├── build-agent-image.sh
│   │   └── certs/
│   │       └── internal-ca.crt
│   ├── jenkins-lightweight.yaml
│   ├── pipeline-config.yaml
│   └── values.yaml
├── microk8s/
│   ├── kubeconfig
│   └── README.md
└── nexus/
    ├── nexus-credentials.txt
    ├── nexus-docker-nodeport.yaml
    └── nexus-lightweight.yaml
```

## Verification

After changes:
1. Run `./k8s/jenkins/agent/build-agent-image.sh` to confirm build still works
2. Verify no broken references: `grep -r "argocd/" scripts/` should return nothing
3. Verify no broken references: `grep -r "deployment/" scripts/` should return nothing (except k8s-deployments)
