# Troubleshooting Guide

## Common Issues and Solutions

### MicroK8s Issues

#### MicroK8s not starting

**Symptoms**:
```bash
$ microk8s status
microk8s is not running
```

**Solutions**:
```bash
# Check system resources
free -h  # Need at least 4GB free RAM
df -h    # Need at least 20GB free disk

# Start MicroK8s
sudo microk8s start

# Check for errors
sudo microk8s inspect

# Reset if corrupted
sudo microk8s reset
./scripts/install-microk8s.sh
```

#### DNS not working in cluster

**Symptoms**:
- Pods can't resolve service names
- `nslookup kubernetes.default` fails inside pods

**Solutions**:
```bash
# Check DNS addon
microk8s status | grep dns

# Enable if disabled
microk8s enable dns

# Restart CoreDNS
microk8s kubectl rollout restart deployment/coredns -n kube-system

# Verify
microk8s kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default
```

#### Ingress not routing traffic

**Symptoms**:
- `curl http://gitlab.local` times out or connection refused
- Ingress controller pods not running

**Solutions**:
```bash
# Check ingress addon
microk8s status | grep ingress

# Check ingress controller
microk8s kubectl get pods -n ingress

# If not running, restart
microk8s kubectl rollout restart deployment/nginx-ingress-microk8s-controller -n ingress

# Check /etc/hosts
cat /etc/hosts | grep local
# Should have:
# 127.0.0.1 gitlab.local jenkins.local nexus.local argocd.local

# Test nginx directly
curl http://localhost:80
```

#### Insufficient storage

**Symptoms**:
- PVCs stuck in "Pending" state
- Error: "no persistent volumes available"

**Solutions**:
```bash
# Check storage addon
microk8s status | grep storage

# Enable if needed
microk8s enable storage

# Check PVCs
microk8s kubectl get pvc --all-namespaces

# Check disk space
df -h /var/snap/microk8s

# Clean up old images
microk8s ctr images ls | grep -v docker.io/library
microk8s ctr images rm <image>
```

---

### GitLab Issues

#### GitLab pod stuck in CrashLoopBackOff

**Symptoms**:
```bash
$ kubectl get pods -n gitlab
NAME                    READY   STATUS             RESTARTS
gitlab-xxx              0/1     CrashLoopBackOff   5
```

**Solutions**:
```bash
# Check logs
kubectl logs -n gitlab gitlab-xxx --previous

# Common causes:
# 1. Insufficient memory - increase limits in values.yaml
# 2. PostgreSQL not ready - check postgres pod
# 3. Storage issues - check PVC

# Check resources
kubectl describe pod -n gitlab gitlab-xxx

# Increase memory in k8s/gitlab/values.yaml:
# resources:
#   requests:
#     memory: 4Gi
#   limits:
#     memory: 8Gi

# Redeploy
helm upgrade gitlab k8s/gitlab -f k8s/gitlab/values.yaml
```

#### Can't login to GitLab

**Symptoms**:
- "Invalid credentials" error
- Forgot root password

**Solutions**:
```bash
# Get initial root password
kubectl get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d

# Reset root password (if needed)
kubectl exec -it -n gitlab gitlab-xxx -- gitlab-rake "gitlab:password:reset[root]"

# Check if external URL is configured correctly
kubectl get ingress -n gitlab
```

#### GitLab container registry not working

**Symptoms**:
- `docker push nexus.local/example-app` fails
- "unauthorized" or "not found"

**Solutions**:
```bash
# We're using Nexus instead of GitLab registry
# Configure Docker to use Nexus:

# Add to /etc/docker/daemon.json:
{
  "insecure-registries": ["nexus.local:5000"]
}

# Restart Docker
sudo systemctl restart docker

# Login to Nexus
docker login nexus.local:5000
# Username: admin
# Password: <nexus-password>
```

#### Webhook not triggering Jenkins

**Symptoms**:
- Push to GitLab doesn't trigger Jenkins build
- GitLab webhook shows error

**Solutions**:
```bash
# Check webhook in GitLab:
# Settings → Webhooks → Recent Deliveries

# Common issues:
# 1. Jenkins URL wrong - should be http://jenkins.local
# 2. Token mismatch - regenerate in Jenkins
# 3. SSL verification - disable for local setup

# Test webhook manually in GitLab UI

# Check Jenkins logs
kubectl logs -n jenkins jenkins-xxx -f

# Verify Jenkins GitLab plugin installed
# Manage Jenkins → Plugin Manager → Installed → GitLab
```

---

### Jenkins Issues

#### Jenkins agent can't start Docker

**Symptoms**:
- Build fails with "Cannot connect to Docker daemon"
- Pipeline step `docker build` fails

**Solutions**:
```bash
# Check if Docker-in-Docker is configured
kubectl get pods -n jenkins -o yaml | grep privileged
# Should show: privileged: true

# Check if Docker socket is mounted
kubectl exec -it -n jenkins jenkins-agent-xxx -- ls -la /var/run/docker.sock

# If not mounted, update values.yaml:
# agent:
#   privileged: true
#   volumes:
#     - type: HostPath
#       hostPath: /var/run/docker.sock
#       mountPath: /var/run/docker.sock

# Or use Docker-in-Docker sidecar (preferred)
# See jenkins/Dockerfile.agent
```

#### Maven build fails with "Cannot resolve dependencies"

**Symptoms**:
- `mvn verify` fails with "Could not resolve dependencies"
- "Connection refused" to Nexus

**Solutions**:
```bash
# Check Nexus is running
kubectl get pods -n nexus

# Check Maven settings.xml
# Should have Nexus mirror configured

# Test connectivity from Jenkins pod
kubectl exec -it -n jenkins jenkins-agent-xxx -- curl http://nexus.local/repository/maven-public/

# If fails, check:
# 1. Nexus service
kubectl get svc -n nexus

# 2. Nexus ingress
kubectl get ingress -n nexus

# 3. DNS resolution
kubectl exec -it -n jenkins jenkins-agent-xxx -- nslookup nexus.local
```

#### CUE command not found

**Symptoms**:
- Pipeline fails with "cue: command not found"

**Solutions**:
```bash
# Check if CUE is installed in agent image
kubectl exec -it -n jenkins jenkins-agent-xxx -- which cue

# If not found, rebuild agent image
# See jenkins/Dockerfile.agent

# Build and push new image
docker build -t nexus.local:5000/jenkins-agent:latest jenkins/
docker push nexus.local:5000/jenkins-agent:latest

# Update Jenkins to use new image
# Manage Jenkins → Configure Clouds → Kubernetes → Pod Templates
```

#### Credentials not working

**Symptoms**:
- "Authentication failed" errors
- Can't push to Git repository
- Can't publish to Nexus

**Solutions**:
```bash
# Check credentials in Jenkins
# Manage Jenkins → Credentials

# Common credential IDs needed:
# - gitlab-token (Secret text)
# - gitlab-ssh-key (SSH Username with private key)
# - nexus-credentials (Username with password)

# Test Git access from Jenkins
kubectl exec -it -n jenkins jenkins-agent-xxx -- git ls-remote http://gitlab.local/root/example-app.git

# Recreate if needed
```

---

### ArgoCD Issues

#### ArgoCD not syncing

**Symptoms**:
- Application status shows "OutOfSync"
- Manual sync doesn't work

**Solutions**:
```bash
# Check ArgoCD application status
kubectl get applications -n argocd

# Describe application
kubectl describe application -n argocd example-app-dev

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Common issues:
# 1. Repository not accessible
argocd repo list
argocd repo add http://gitlab.local/root/k8s-deployments.git --username root --password <password>

# 2. Invalid manifests
# Check CUE rendering locally
cd k8s-deployments
./scripts/generate-manifests.sh dev
kubectl apply --dry-run=client -f manifests/dev/

# 3. Namespace doesn't exist
kubectl create namespace dev
kubectl create namespace stage
kubectl create namespace prod
```

#### ArgoCD can't access GitLab repository

**Symptoms**:
- "authentication required" error
- "repository not found"

**Solutions**:
```bash
# Check repository in ArgoCD
argocd repo list

# Add repository with credentials
argocd repo add http://gitlab.local/root/k8s-deployments.git \
  --username root \
  --password <gitlab-password>

# Or use SSH
ssh-keygen -t ed25519 -C "argocd" -f ~/.ssh/argocd
# Add public key to GitLab (root user → Settings → SSH Keys)
argocd repo add git@gitlab.local:root/k8s-deployments.git \
  --ssh-private-key-path ~/.ssh/argocd

# Test connectivity
argocd repo get http://gitlab.local/root/k8s-deployments.git
```

#### Application stuck in "Progressing"

**Symptoms**:
- Sync shows "Progressing" for long time
- Health status "Unknown"

**Solutions**:
```bash
# Check actual Kubernetes resources
kubectl get all -n dev

# Check pod status
kubectl describe pod -n dev example-app-xxx

# Common issues:
# 1. Image pull error
kubectl describe pod -n dev example-app-xxx | grep -A 5 Events

# 2. Readiness probe failing
kubectl logs -n dev example-app-xxx

# 3. Insufficient resources
kubectl describe nodes | grep -A 5 Allocated

# Force refresh
argocd app get example-app-dev --refresh
```

---

### Nexus Issues

#### Can't login to Nexus

**Symptoms**:
- Default admin password doesn't work

**Solutions**:
```bash
# Get initial admin password
kubectl exec -it -n nexus nexus-xxx -- cat /nexus-data/admin.password

# Login with:
# Username: admin
# Password: <from above>

# Change password on first login
```

#### Docker push fails

**Symptoms**:
- `docker push nexus.local:5000/example-app:1.0.0` fails
- "unauthorized" or "server gave HTTP response to HTTPS client"

**Solutions**:
```bash
# Configure Docker for insecure registry
# /etc/docker/daemon.json:
{
  "insecure-registries": ["nexus.local:5000"]
}

sudo systemctl restart docker

# Create docker-hosted repository in Nexus
# - HTTP connector: 5000
# - Allow anonymous pull: true (for dev)

# Create Docker registry credentials in Jenkins
# - ID: nexus-docker-credentials
# - Username: admin
# - Password: <nexus-password>
```

#### Maven publish fails

**Symptoms**:
- `mvn deploy` fails with "unauthorized"
- "Return code is: 401"

**Solutions**:
```bash
# Check Maven settings.xml has credentials
cat ~/.m2/settings.xml
# Should have:
# <server>
#   <id>nexus-releases</id>
#   <username>admin</username>
#   <password>nexus-password</password>
# </server>

# In Jenkins, use settings.xml from Managed Files

# Check repository in pom.xml matches settings.xml server id
grep -A 5 distributionManagement pom.xml
```

---

### CUE Issues

#### CUE validation fails

**Symptoms**:
- `cue vet` fails with type errors
- "field not allowed"

**Solutions**:
```bash
# Check CUE syntax
cue vet ./envs/dev.cue

# Common issues:
# 1. Missing required field
# Fix: Add field to app.cue or dev.cue

# 2. Type mismatch (e.g., string vs int)
# Fix: Check schema in services/base/schema.cue

# 3. Extra field not in schema
# Fix: Add field to schema or remove from config

# Validate against schema
cue vet ./services/apps/example-app.cue ./services/base/schema.cue
```

#### Manifest generation produces empty files

**Symptoms**:
- `generate-manifests.sh` runs but manifests/ is empty
- No errors shown

**Solutions**:
```bash
# Run CUE export manually
cue export --out yaml ./envs/dev.cue

# Check if resources_list is defined
grep resources_list ./envs/dev.cue

# Check if app is included
grep example-app ./envs/dev.cue

# Validate full CUE structure
cue eval ./envs/dev.cue
```

#### Manifest diff shows unexpected changes

**Symptoms**:
- Promotion MR shows changes that shouldn't be there
- Generated YAML differs from expected

**Solutions**:
```bash
# Regenerate manifests fresh
rm -rf manifests/
./scripts/generate-manifests.sh dev
./scripts/generate-manifests.sh stage
./scripts/generate-manifests.sh prod

# Compare with expected
./scripts/validate-manifests.sh

# Check for non-deterministic output
# CUE should be deterministic, check for:
# - Generated timestamps
# - Random values
# - Environment variables in CUE

# Format CUE files
cue fmt ./...
```

---

### TestContainers Issues

#### Tests fail with "Cannot connect to Docker"

**Symptoms**:
- Integration tests fail in Jenkins
- `@QuarkusTest` with TestContainers can't start containers

**Solutions**:
```bash
# Ensure Docker-in-Docker or Docker socket is available
# In Jenkins agent pod:
kubectl exec -it -n jenkins jenkins-agent-xxx -- docker ps

# If fails, check:
# 1. Agent has privileged: true
# 2. Docker socket mounted or DinD sidecar running

# In Jenkinsfile:
podTemplate(containers: [
  containerTemplate(name: 'docker', image: 'docker:dind', privileged: true)
])
```

#### Tests fail with "Port already in use"

**Symptoms**:
- TestContainers can't bind port
- "Address already in use"

**Solutions**:
```bash
# Use random ports in tests
# TestContainers should auto-assign ports

# In test code:
@Container
static PostgreSQLContainer postgres = new PostgreSQLContainer("postgres:15")
  .withExposedPorts(5432);  // Don't specify host port

# Get dynamic port:
int port = postgres.getMappedPort(5432);
```

---

### Network and Connectivity

#### Service name resolution fails

**Symptoms**:
- Pod can't reach other service by name
- `curl http://gitlab` fails from Jenkins pod

**Solutions**:
```bash
# Check DNS
kubectl exec -it -n jenkins jenkins-xxx -- nslookup gitlab.gitlab.svc.cluster.local

# Check service exists
kubectl get svc -n gitlab

# Use full service name
# Format: <service>.<namespace>.svc.cluster.local
curl http://gitlab.gitlab.svc.cluster.local
```

#### Ingress returns 404

**Symptoms**:
- `curl http://gitlab.local` returns 404
- Ingress exists but not routing

**Solutions**:
```bash
# Check ingress
kubectl get ingress --all-namespaces

# Describe ingress
kubectl describe ingress -n gitlab gitlab

# Check backend service
kubectl get svc -n gitlab gitlab

# Verify ingress class
kubectl get ingressclass

# Test backend directly
kubectl port-forward -n gitlab svc/gitlab 8080:80
curl http://localhost:8080
```

---

### Performance Issues

#### Builds are slow

**Symptoms**:
- Maven build takes >10 minutes
- Tests timeout

**Solutions**:
```bash
# Enable Maven parallel builds
mvn -T 4 clean verify

# Use Nexus as mirror for faster downloads
# Check ~/.m2/settings.xml has Nexus mirror

# Increase Jenkins agent resources
# In values.yaml:
# agent:
#   resources:
#     requests:
#       cpu: 2
#       memory: 4Gi
```

#### ArgoCD sync is slow

**Symptoms**:
- Takes >5 minutes to detect changes
- Manual sync is fast

**Solutions**:
```bash
# Enable webhook instead of polling
# In k8s-deployments repository → Settings → Webhooks
# URL: http://argocd.local/api/webhook
# Events: Push events

# Reduce poll interval (not recommended, use webhook)
kubectl edit configmap -n argocd argocd-cm
# Add:
# data:
#   timeout.reconciliation: 60s  # default is 180s
```

---

## Debugging Commands

### Quick Health Check

```bash
#!/bin/bash
# scripts/health-check.sh

echo "=== MicroK8s ==="
microk8s status

echo "=== GitLab ==="
kubectl get pods -n gitlab
curl -s -o /dev/null -w "%{http_code}" http://gitlab.local

echo "=== Jenkins ==="
kubectl get pods -n jenkins
curl -s -o /dev/null -w "%{http_code}" http://jenkins.local

echo "=== Nexus ==="
kubectl get pods -n nexus
curl -s -o /dev/null -w "%{http_code}" http://nexus.local

echo "=== ArgoCD ==="
kubectl get pods -n argocd
argocd app list

echo "=== Applications ==="
kubectl get pods -n dev
kubectl get pods -n stage
kubectl get pods -n prod
```

### Log Collection

```bash
# Collect all logs for troubleshooting
mkdir -p /tmp/pipeline-logs

kubectl logs -n gitlab --all-containers --prefix > /tmp/pipeline-logs/gitlab.log
kubectl logs -n jenkins --all-containers --prefix > /tmp/pipeline-logs/jenkins.log
kubectl logs -n nexus --all-containers --prefix > /tmp/pipeline-logs/nexus.log
kubectl logs -n argocd --all-containers --prefix > /tmp/pipeline-logs/argocd.log

tar -czf pipeline-logs.tar.gz /tmp/pipeline-logs/
```

---

## Getting Help

If issues persist:

1. Check logs: `kubectl logs -n <namespace> <pod-name>`
2. Describe resources: `kubectl describe <resource> -n <namespace> <name>`
3. Check events: `kubectl get events -n <namespace> --sort-by='.lastTimestamp'`
4. Review documentation in `docs/`
5. Check component-specific documentation (GitLab, Jenkins, ArgoCD, etc.)
