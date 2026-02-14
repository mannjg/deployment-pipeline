# Current Status

## Infrastructure

**State:** Kubernetes cluster with GitLab, Jenkins, Nexus, ArgoCD deployed.

**GitLab Configuration:**
- External URL: `http://gitlab.jmann.local`
- Internal URL: `http://gitlab.gitlab.svc.cluster.local`
- Group: `p2c`
- Repositories: `p2c/example-app`, `p2c/k8s-deployments`

**Known Limitations:**
- Single cluster (all environments in one cluster).
- No HA (single replicas of infrastructure components).
- Local storage only.
- Missing feature: Feature-branch deployments to shared dev/stage/prod environments are not supported (main-only app deployments).

**Last verified:** 2026-01-16

## Infrastructure Notes

**Kubernetes Cluster:**
- **Distribution-agnostic**: Works with any K8s cluster (microk8s, kind, k3s, EKS, GKE, etc.).
- **Prerequisite**: User must configure `kubectl` to access their target cluster.
- Scripts use standard `kubectl` commands - no distribution-specific tooling.

**Namespaces:**
| Namespace | Purpose |
|---------|---------|
| gitlab | GitLab CE |
| jenkins | Jenkins CI/CD |
| nexus | Nexus Repository |
| argocd | ArgoCD GitOps |
| dev | Development environment |
| stage | Staging environment |
| prod | Production environment |

**Centralized Config:**
Source a cluster config via `scripts/lib/infra.sh` for infrastructure URLs in scripts:
```bash
source scripts/lib/infra.sh config/clusters/alpha.env
echo $GITLAB_URL_EXTERNAL   # https://gitlab-alpha.jmann.local
echo $JENKINS_URL_EXTERNAL  # https://jenkins-alpha.jmann.local
echo $APP_REPO_PATH         # p2c/example-app
```

## Service Access

**URLs (add to /etc/hosts pointing to 127.0.0.1):**
| Service | URL | Purpose |
|---------|-----|---------|
| GitLab | http://gitlab.jmann.local | Source control, webhooks |
| Jenkins | http://jenkins.local | CI/CD builds |
| Nexus | http://nexus.local | Maven artifacts |
| ArgoCD | http://argocd.local | GitOps deployment |
| Container Registry | https://registry.local | Container images |

**Credentials:** Stored in Jenkins credentials store and Kubernetes secrets. Do not hardcode.

**Check service health:**
```bash
kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd'
```
