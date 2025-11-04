# Quick Access Guide

Last Updated: 2025-11-02

## Service URLs

| Service | URL | Username | Password | Purpose |
|---------|-----|----------|----------|---------|
| **GitLab** | http://gitlab.local | root | changeme123 | Source control, webhooks |
| **Jenkins** | http://jenkins.local | admin | admin | CI/CD builds |
| **Nexus** | http://nexus.local | admin | admin123 | Maven artifacts, Docker registry |
| **ArgoCD** | http://argocd.local | admin | KofmrUFAJ7JeEiWr | GitOps deployment |

## GitLab Integration

**Personal Access Token:** `glpat-9m86y9YHyGf77Kr8bRjX`
- **Scopes:** api, read_repository, write_repository
- **Use for:** Jenkins, ArgoCD, automation scripts

**Projects:**
- http://gitlab.local/example/example-app
- http://gitlab.local/example/k8s-deployments

## Docker Registry

**External (HTTPS - for local development):**
```bash
# Login
docker login docker.local:5000
# Username: admin
# Password: admin123

# Pull image
docker pull docker.local:5000/example-app:latest
```

**Internal (HTTP - used by Jenkins/Kubernetes):**
- URL: `nexus.nexus.svc.cluster.local:5000`
- No TLS required for cluster-internal access

## Quick Health Checks

### Check All Infrastructure
```bash
sg microk8s -c "microk8s kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd'"
```

**Expected Output:**
```
gitlab      gitlab-xxx                          1/1     Running
jenkins     jenkins-xxx                         1/1     Running
nexus       nexus-xxx                           1/1     Running
argocd      argocd-server-xxx                   1/1     Running
argocd      argocd-application-controller-xxx   1/1     Running
argocd      argocd-repo-server-xxx              1/1     Running
```

### Verify Service Accessibility
```bash
# GitLab
curl -s http://gitlab.local/users/sign_in | grep -q "GitLab" && echo "✓ GitLab accessible"

# Jenkins
curl -s http://jenkins.local | grep -q "Jenkins" && echo "✓ Jenkins accessible"

# Nexus
curl -s http://nexus.local | grep -q "Nexus" && echo "✓ Nexus accessible"

# ArgoCD
curl -s http://argocd.local | grep -q "Argo" && echo "✓ ArgoCD accessible"
```

### Check GitLab API
```bash
export GITLAB_TOKEN="glpat-9m86y9YHyGf77Kr8bRjX"

# List all projects
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" http://gitlab.local/api/v4/projects | \
  python3 -c "import sys, json; [print(p['path_with_namespace']) for p in json.load(sys.stdin)]"
```

### Check Jenkins Jobs
```bash
# List all jobs
curl -s http://jenkins.local/api/json | \
  python3 -c "import sys, json; [print(j['name']) for j in json.load(sys.stdin)['jobs']]"

# Get last build status
curl -s http://jenkins.local/job/example-app-ci/lastBuild/api/json | \
  python3 -c "import sys, json; d=json.load(sys.stdin); print(f\"Build #{d['number']}: {d['result'] or 'BUILDING'}\")"
```

### Check Nexus Repositories
```bash
# Docker images
curl -s http://nexus.local/service/rest/v1/search?repository=docker-hosted | \
  python3 -c "import sys, json; [print(i['name']) for i in json.load(sys.stdin).get('items', [])]"

# Maven artifacts
curl -s http://nexus.local/service/rest/v1/search?repository=maven-snapshots | \
  python3 -c "import sys, json; [print(i['name']) for i in json.load(sys.stdin).get('items', [])]"
```

### Check ArgoCD Applications
```bash
# List applications
sg microk8s -c "microk8s kubectl get applications -n argocd"

# Check specific app sync status
sg microk8s -c "microk8s kubectl get application example-app-dev -n argocd -o jsonpath='{.status.sync.status}'"
```

## Jenkins Credentials (for pipeline jobs)

These credentials must be configured in Jenkins (Manage Jenkins → Credentials):

| ID | Type | Username | Password | Used For |
|----|------|----------|----------|----------|
| gitlab-credentials | Username/Password | root | glpat-9m86y9YHyGf77Kr8bRjX | GitLab repository access |
| nexus-credentials | Username/Password | admin | admin123 | Maven artifact publishing |
| docker-registry-credentials | Username/Password | admin | admin123 | Docker image publishing |

## Ingress Hostnames

Add these to `/etc/hosts` for local access:
```
127.0.0.1  gitlab.local
127.0.0.1  jenkins.local
127.0.0.1  nexus.local
127.0.0.1  argocd.local
127.0.0.1  docker.local
```

## Namespaces

| Namespace | Purpose | Check Status |
|-----------|---------|--------------|
| gitlab | GitLab CE | `sg microk8s -c "microk8s kubectl get pods -n gitlab"` |
| jenkins | Jenkins CI/CD | `sg microk8s -c "microk8s kubectl get pods -n jenkins"` |
| nexus | Nexus Repository | `sg microk8s -c "microk8s kubectl get pods -n nexus"` |
| argocd | ArgoCD GitOps | `sg microk8s -c "microk8s kubectl get pods -n argocd"` |
| dev | Development apps | `sg microk8s -c "microk8s kubectl get pods -n dev"` |
| stage | Staging apps | `sg microk8s -c "microk8s kubectl get pods -n stage"` |
| prod | Production apps | `sg microk8s -c "microk8s kubectl get pods -n prod"` |

## Getting ArgoCD CLI Password

If you need to reset or retrieve the ArgoCD admin password:
```bash
# Get current password
sg microk8s -c "microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
```

## Port Forwards (for local testing)

```bash
# Port-forward to dev application
sg microk8s -c "microk8s kubectl port-forward -n dev svc/example-app 8080:8080" &

# Test
curl http://localhost:8080/api/greetings
# Expected: {"message":"Hello, World!"}

# Kill port-forward
pkill -f "port-forward.*example-app"
```

## Troubleshooting Access

### Can't access *.local URLs
```bash
# Check ingress controller
sg microk8s -c "microk8s kubectl get pods -n ingress"

# Check ingress resources
sg microk8s -c "microk8s kubectl get ingress -A"
```

### GitLab not responding
```bash
# Check pod logs
sg microk8s -c "microk8s kubectl logs -n gitlab deployment/gitlab --tail=50"

# Restart GitLab
sg microk8s -c "microk8s kubectl rollout restart -n gitlab deployment/gitlab"
```

### Jenkins build agents failing
```bash
# Check jenkins-agent service
sg microk8s -c "microk8s kubectl get svc -n jenkins jenkins-agent"

# Expected: ClusterIP on port 50000
```

### Docker registry authentication fails
```bash
# Check Nexus Docker Bearer Token Realm is enabled
# 1. Visit http://nexus.local
# 2. Login as admin/admin123
# 3. Go to Administration → Security → Realms
# 4. Ensure "Docker Bearer Token Realm" is in Active list
```
