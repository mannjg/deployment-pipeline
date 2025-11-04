# CI/CD Pipeline - Complete Implementation Guide

This guide walks you through the complete setup of the end-to-end CI/CD pipeline from infrastructure to production deployment.

## Prerequisites Checklist

Before starting, ensure you have:

- [ ] MicroK8s cluster installed and running
- [ ] kubectl access configured (alias: `kubectl=microk8s kubectl`)
- [ ] At least 10GB RAM and 20GB disk space available
- [ ] Local domain resolution configured in `/etc/hosts`
- [ ] Docker installed and running on your host machine

## Helper Scripts Available

The project includes several helper scripts to simplify common tasks:

| Script | Purpose | Example |
|--------|---------|---------|
| `scripts/docker-registry-helper.sh` | Manage Docker registry access | `./scripts/docker-registry-helper.sh login` |
| `scripts/configure-nexus.sh` | Auto-configure Nexus | `bash scripts/configure-nexus.sh` |
| `scripts/configure-gitlab.sh` | Display GitLab setup guide | `bash scripts/configure-gitlab.sh` |
| `scripts/configure-jenkins.sh` | Display Jenkins setup guide | `bash scripts/configure-jenkins.sh` |

**Quick Help:**
```bash
# Get help for any script
./scripts/docker-registry-helper.sh help
```

## Phase 1: Infrastructure Deployment (COMPLETED ✅)

All infrastructure components are deployed and running:

### Services Running

| Service | URL | Status | Credentials |
|---------|-----|--------|-------------|
| GitLab | http://gitlab.local | ✅ Running | root / changeme123 |
| Jenkins | http://jenkins.local | ✅ Running | No auth (local dev) |
| Nexus | http://nexus.local | ✅ Running | admin / admin123 |
| ArgoCD | http://argocd.local | ✅ Running | admin / KofmrUFAJ7JeEiWr |

### What Was Deployed

1. **MicroK8s** v1.28.15 with addons: dns, storage, ingress, helm
2. **GitLab CE** (lightweight deployment)
3. **Jenkins** (lightweight deployment with custom agent)
4. **Nexus Repository** (Maven + Docker registry on port 5000)
5. **ArgoCD** (full installation with 7 components)

### Verification

```bash
# Check all pods
microk8s kubectl get pods --all-namespaces

# Check ingress
microk8s kubectl get ingress --all-namespaces

# Test service accessibility
curl -I http://gitlab.local
curl -I http://jenkins.local
curl -I http://nexus.local
curl -I http://argocd.local
```

---

## Phase 2: Service Configuration

### 2.1 Nexus Configuration

Status: **Mostly Automated** ✅

#### Automated Steps (Completed)
```bash
bash /home/jmann/git/mannjg/deployment-pipeline/scripts/configure-nexus.sh
```

This script:
- ✅ Changed admin password to `admin123`
- ✅ Created `maven-releases` repository
- ✅ Created `maven-snapshots` repository
- ✅ Created `docker-hosted` repository on port 5000
- ✅ Created `jenkins` user
- ✅ Created NodePort service for Docker registry access

#### Manual Step Required (IMPORTANT!)

⚠️ **The Docker registry will NOT work until you complete this step:**

1. Login to http://nexus.local as `admin / admin123`
2. Go to: **Settings** (gear icon) → **Security** → **Realms**
3. Move **"Docker Bearer Token Realm"** from Available to **Active**
4. Click **Save**

#### Docker Registry Access

The Docker registry is now accessible at multiple endpoints:

| Access From | Address | Use Case |
|-------------|---------|----------|
| **Your host** | `localhost:30500` | Local Docker builds, testing |
| **Kubernetes pods** | `nexus.local:5000` | Jenkins builds, ArgoCD |
| **Port-forward** | `localhost:5000` | Temporary testing |

✅ **Verification:**

Using the helper script (recommended):
```bash
# Check registry status
./scripts/docker-registry-helper.sh status

# Login to registry
./scripts/docker-registry-helper.sh login

# Test connectivity
./scripts/docker-registry-helper.sh test
```

Or manually:
```bash
# Login via NodePort (persistent)
docker login localhost:30500 -u admin -p admin123

# Test registry endpoint
curl http://localhost:30500/v2/
# Should return: {"errors":[{"code":"UNAUTHORIZED"...]} - this is GOOD!

# List repositories
curl -u admin:admin123 http://localhost:30500/v2/_catalog
```

📖 **Complete Docker Registry Guide:** See `DOCKER_REGISTRY_GUIDE.md` for detailed troubleshooting and usage.

### 2.2 GitLab Configuration

Status: **Manual Setup Required**

#### Configuration Guide

The complete guide was generated at:
```
/home/jmann/git/mannjg/deployment-pipeline/GITLAB_SETUP_GUIDE.md
```

**Steps:**

1. **Login to GitLab**
   - URL: http://gitlab.local
   - Username: `root`
   - Password: `changeme123`

2. **Change Root Password** (Recommended)
   - Go to: http://gitlab.local/-/user_settings/password/edit
   - Set a secure password

3. **Create Personal Access Token**
   - Go to: http://gitlab.local/-/user_settings/personal_access_tokens
   - Name: `jenkins-integration`
   - Scopes: ✓ `api`, ✓ `read_repository`, ✓ `write_repository`
   - Click "Create personal access token"
   - **SAVE THE TOKEN** (you won't see it again!)
   - glpat-wsbb2YxLwxk3NJSBTMdZ

4. **Create Projects**

   **A. example-app**
   - Go to: http://gitlab.local/projects/new
   - Project name: `example-app`
   - Visibility: Private
   - Initialize with README: **No**
   - Click "Create project"

   **B. k8s-deployments**
   - Go to: http://gitlab.local/projects/new
   - Project name: `k8s-deployments`
   - Visibility: Private
   - Initialize with README: **No**
   - Click "Create project"

5. **Configure Git Locally**
   ```bash
   git config --global user.name "Root User"
   git config --global user.email "root@local"
   ```

✅ **Verification:**
```bash
# Test API token
curl --header "PRIVATE-TOKEN: glpat-wsbb2YxLwxk3NJSBTMdZ" "http://gitlab.local/api/v4/user"

# Test git access (use your token)
git clone http://oauth2:glpat-wsbb2YxLwxk3NJSBTMdZ@gitlab.local/example/example-app.git

# View verification report
cat GITLAB_VERIFICATION_REPORT.md
```

📖 **Note**: Projects are under `example/` namespace:
- `http://gitlab.local/example/example-app.git`
- `http://gitlab.local/example/k8s-deployments.git`

### 2.3 Jenkins Configuration

Status: **Manual Setup Required**

#### Configuration Guide

The complete guide was generated at:
```
/home/jmann/git/mannjg/deployment-pipeline/JENKINS_SETUP_GUIDE.md
```

**Steps:**

1. **Access Jenkins**
   - URL: http://jenkins.local
   - No authentication required (local dev)

2. **Install Required Plugins**
   - Manage Jenkins → Plugins → Available Plugins

   Install these plugins:
   - `gitlab-plugin` (GitLab integration)
   - `docker-workflow` (Docker pipeline support)
   - `kubernetes` (Kubernetes cloud agents)

   Check "Restart Jenkins when installation is complete"

3. **Add Credentials**

   Go to: Manage Jenkins → Credentials → System → Global credentials

   **A. GitLab API Token**
   - Kind: `GitLab API token`
   - API token: `<paste your token from GitLab>`
   - ID: `gitlab-api-token`
   - Description: `GitLab API Token for Jenkins`

   **B. GitLab Username/Password**
   - Kind: `Username with password`
   - Username: `root`
   - Password: `<your GitLab password>`
   - ID: `gitlab-credentials`

   **C. Nexus Credentials**
   - Kind: `Username with password`
   - Username: `admin`
   - Password: `admin123`
   - ID: `nexus-credentials`

   **D. Docker Registry Credentials**
   - Kind: `Username with password`
   - Username: `admin`
   - Password: `admin123`
   - ID: `docker-registry-credentials`

4. **Configure Kubernetes Cloud**

   Manage Jenkins → Clouds → New cloud

   - Name: `kubernetes`
   - Type: `Kubernetes`
   - Kubernetes URL: `https://kubernetes.default.svc.cluster.local`
   - Kubernetes Namespace: `jenkins`
   - Jenkins URL: `http://jenkins.jenkins.svc.cluster.local:8080`

   **Pod Template:**
   - Name: `jenkins-agent`
   - Labels: `jenkins-agent`
   - Container: `nexus.local:5000/jenkins-agent-custom:latest`
   - Add Volume: Host Path (`/var/run/docker.sock` → `/var/run/docker.sock`)

5. **Configure GitLab Connection**

   Manage Jenkins → System → GitLab

   - Connection name: `gitlab`
   - GitLab host URL: `http://gitlab.gitlab.svc.cluster.local`
   - Credentials: Select `gitlab-api-token`
   - Click "Test Connection" (should succeed)

   ⚠️ **Important**: Use the internal Kubernetes DNS name, not `http://gitlab.local`

   **Why?** Jenkins runs inside the cluster and needs to use Kubernetes service DNS names:
   - ❌ `http://gitlab.local` - Only works from your host (via /etc/hosts)
   - ✅ `http://gitlab.gitlab.svc.cluster.local` - Works from inside cluster

✅ **Verification:**

Create and run a test pipeline:
```groovy
pipeline {
    agent {
        kubernetes {
            label 'jenkins-agent'
        }
    }
    stages {
        stage('Test') {
            steps {
                sh 'java -version'
                sh 'mvn -version'
                sh 'docker --version'
                sh 'cue version'
            }
        }
    }
}
```

### 2.4 ArgoCD Configuration

Status: **Requires Setup**

**Prerequisites:**
- [ ] ArgoCD CLI installed (`~/bin/argocd`)
- [ ] Port-forward running to access ArgoCD

**Steps:**

1. **Install ArgoCD CLI** (if not already installed)
   ```bash
   # Download and install
   curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
   mkdir -p ~/bin
   mv /tmp/argocd ~/bin/argocd
   chmod +x ~/bin/argocd
   export PATH="$HOME/bin:$PATH"

   # Verify installation
   argocd version --client
   ```

2. **Access ArgoCD Server**
   ```bash
   # Start port-forward (runs in background)
   microk8s kubectl port-forward -n argocd svc/argocd-server 8080:80 > /dev/null 2>&1 &

   # Verify access
   curl -sI http://localhost:8080
   ```

   ✅ **Note**: Port-forward runs on `localhost:8080` for CLI access and UI: http://localhost:8080

3. **Login to ArgoCD**
   ```bash
   # Get initial admin password
   microk8s kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

   # CLI login
   argocd login localhost:8080 --username admin --password KofmrUFAJ7JeEiWr --insecure
   ```

   **Credentials:**
   - Username: `admin`
   - Password: `KofmrUFAJ7JeEiWr`
   - UI: http://localhost:8080

4. **Change Admin Password** (Recommended)
   ```bash
   argocd account update-password
   ```

5. **Add GitLab Repository**
   ```bash
   argocd repo add http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git \
       --username oauth2 \
       --password glpat-wsbb2YxLwxk3NJSBTMdZ \
       --insecure-skip-server-verification
   ```

   ⚠️ **Note**: Use the internal cluster DNS `http://gitlab.gitlab.svc.cluster.local` and OAuth2 token authentication

6. **Create ArgoCD Applications**
   ```bash
   # Dev environment
   microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/example-app-dev.yaml

   # Stage environment
   microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/example-app-stage.yaml

   # Prod environment
   microk8s kubectl apply -f /home/jmann/git/mannjg/deployment-pipeline/argocd/applications/example-app-prod.yaml
   ```

✅ **Verification:**
```bash
# Check applications
argocd app list

# Sync dev application
argocd app sync example-app-dev
```

---

## Phase 2.5: Push Jenkins Agent to Registry

**IMPORTANT**: Before Jenkins can use the custom agent, push it to Nexus registry.

### Prerequisites
- [ ] Docker Bearer Token Realm enabled in Nexus
- [ ] Docker logged into registry (`docker login localhost:30500`)

### Push the Agent Image

```bash
# Login to registry
docker login localhost:30500 -u admin -p admin123

# The agent image is already built locally
docker images | grep jenkins-agent

# Tag for Nexus registry
docker tag jenkins-agent-custom:latest localhost:30500/jenkins-agent-custom:latest

# Push to registry
docker push localhost:30500/jenkins-agent-custom:latest

# Verify the push
curl -u admin:admin123 http://localhost:30500/v2/jenkins-agent-custom/tags/list
```

**Or use the helper script:**
```bash
./scripts/docker-registry-helper.sh push jenkins-agent-custom:latest
```

✅ **Verification:**
```bash
# Check the image is in the registry
curl -u admin:admin123 http://localhost:30500/v2/_catalog
# Should show: {"repositories":["jenkins-agent-custom"]}

# Check tags
curl -u admin:admin123 http://localhost:30500/v2/jenkins-agent-custom/tags/list
# Should show: {"name":"jenkins-agent-custom","tags":["latest"]}
```

Now Jenkins can pull this image from `nexus.local:5000/jenkins-agent-custom:latest` inside the cluster.

---

## Phase 3: Application Setup

### 3.1 Push example-app to GitLab

```bash
cd /home/jmann/git/mannjg/deployment-pipeline/example-app

# Initialize git (if not already)
git init
git config user.name "Root User"
git config user.email "root@local"

# Add remote (using token for authentication)
git remote add origin http://oauth2:glpat-wsbb2YxLwxk3NJSBTMdZ@gitlab.local/example/example-app.git

# Commit and push
git add .
git commit -m "Initial commit: Quarkus application with TestContainers

- REST API endpoints
- Health checks and metrics
- Unit and integration tests
- Jib Docker image build
- CUE deployment configuration
- Jenkins CI/CD pipeline"

git branch -M main
git push -u origin main
```

### 3.2 Push k8s-deployments to GitLab

```bash
cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments

# Add GitLab remote (using token for authentication)
git remote add origin http://oauth2:glpat-wsbb2YxLwxk3NJSBTMdZ@gitlab.local/example/k8s-deployments.git

# Push all branches
git push -u origin master
git push origin dev
git push origin stage
git push origin prod
```

### 3.3 Create Jenkins Pipeline Job

1. **Go to Jenkins**: http://jenkins.local
2. **New Item** → Name: `example-app-ci` → Type: `Pipeline`
3. **Configure:**
   - Build Triggers: ✓ `Build when a change is pushed to GitLab`
   - Pipeline Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `http://gitlab.gitlab.svc.cluster.local/example/example-app.git`
   - Credentials: Select `gitlab-credentials`
   - Branch: `*/main`
   - Script Path: `Jenkinsfile`

   ⚠️ **Note**: Use `http://gitlab.gitlab.svc.cluster.local` (internal cluster DNS)
   not `http://gitlab.local` (which only works from host)
4. **Save**

### 3.4 Configure GitLab Webhook

1. Go to: http://gitlab.local/example/example-app → Settings → Webhooks
2. **URL**: `http://jenkins.local/project/example-app-ci`
3. **Trigger**: ✓ `Push events`, ✓ `Merge request events`
4. **SSL verification**: Disable (local dev)
5. Click "Add webhook"
6. **Test**: Click "Test" → "Push events" (should return HTTP 200)

---

## Phase 4: End-to-End Testing

### 4.1 Test Build Pipeline

```bash
cd /home/jmann/git/mannjg/deployment-pipeline/example-app

# Make a small change
echo "# Test change" >> README.md

# Commit and push
git add README.md
git commit -m "Test: Trigger Jenkins pipeline"
git push origin main
```

**Expected Flow:**
1. ✅ GitLab webhook triggers Jenkins
2. ✅ Jenkins runs unit tests
3. ✅ Jenkins runs integration tests (TestContainers)
4. ✅ Jenkins builds Docker image with Jib
5. ✅ Jenkins pushes image to Nexus
6. ✅ Jenkins updates k8s-deployments `dev` branch
7. ✅ ArgoCD detects change and syncs to dev namespace

**Monitor:**
```bash
# Watch Jenkins job
# Go to: http://jenkins.local/job/example-app-ci/

# Watch ArgoCD sync
argocd app get example-app-dev

# Watch pods in dev namespace
microk8s kubectl get pods -n dev -w
```

### 4.2 Verify Deployment

```bash
# Check deployment
microk8s kubectl get all -n dev

# Check application logs
microk8s kubectl logs -n dev -l app=example-app

# Port-forward and test
microk8s kubectl port-forward -n dev svc/example-app 8080:80

# Test endpoints (in another terminal)
curl http://localhost:8080/api/greetings
curl http://localhost:8080/health
curl http://localhost:8080/metrics
```

### 4.3 Test Environment Promotion

**Manual Promotion Flow:**

1. **Review Changes**
   ```bash
   cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments

   # Compare dev vs stage
   git diff stage dev
   ```

2. **Create Merge Request** (via GitLab UI)
   - Go to: http://gitlab.local/example/k8s-deployments/-/merge_requests/new
   - Source: `dev`
   - Target: `stage`
   - Title: "Promote example-app to stage"
   - Create as draft initially

3. **Review Diff**
   - Review changes in MR (should show image version update)
   - Undraft when ready

4. **Merge MR**
   - Click "Merge"
   - ArgoCD will automatically sync to stage namespace

5. **Verify Stage Deployment**
   ```bash
   # Check stage namespace
   microk8s kubectl get all -n stage

   # Check ArgoCD
   argocd app get example-app-stage
   ```

6. **Repeat for Production**
   - Create MR: stage → prod
   - Review, approve, and merge
   - Verify prod deployment

---

## Phase 5: Continuous Delivery in Action

### Complete Feature Delivery Flow

1. **Create Feature Branch**
   ```bash
   cd /home/jmann/git/mannjg/deployment-pipeline/example-app
   git checkout -b feature/new-endpoint
   ```

2. **Make Changes**
   - Add new REST endpoint
   - Add tests
   - Update version in pom.xml (optional)

3. **Commit and Push**
   ```bash
   git add .
   git commit -m "Add new endpoint"
   git push origin feature/new-endpoint
   ```

4. **Create Merge Request** (GitLab UI)
   - ✅ Jenkins runs unit tests on commit
   - ✅ Jenkins runs integration tests on MR creation

5. **Merge to Main**
   - ✅ Jenkins builds and publishes artifacts
   - ✅ Jenkins updates k8s-deployments dev branch
   - ✅ ArgoCD syncs to dev namespace
   - ✅ Feature is now live in dev!

6. **Promote Through Environments**
   - Create MR: dev → stage
   - Test in stage
   - Create MR: stage → prod
   - Promote to production

---

## Troubleshooting

### Jenkins Build Fails

```bash
# Check Jenkins logs
microk8s kubectl logs -n jenkins -l app=jenkins

# Check agent pods
microk8s kubectl get pods -n jenkins

# Check Docker access
microk8s kubectl exec -n jenkins <agent-pod> -- docker ps
```

### ArgoCD Sync Fails

```bash
# Check application status
argocd app get example-app-dev

# View detailed sync status
argocd app sync example-app-dev --dry-run

# Check ArgoCD logs
microk8s kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

### Docker Registry Connection Issues

**Symptom:** `connection refused` when trying to `docker login nexus.local:5000`

**Solution:**

1. **Use localhost:30500 instead** (NodePort):
   ```bash
   docker login localhost:30500 -u admin -p admin123
   ```

2. **Or use the helper script:**
   ```bash
   ./scripts/docker-registry-helper.sh login
   ```

3. **Verify Docker Bearer Token Realm is enabled:**
   - Go to: http://nexus.local → Settings → Security → Realms
   - Make sure "Docker Bearer Token Realm" is in Active list

4. **Check registry status:**
   ```bash
   ./scripts/docker-registry-helper.sh status
   ```

5. **Test registry endpoint:**
   ```bash
   curl http://localhost:30500/v2/
   # Should return unauthorized error - this is GOOD!
   ```

📖 **See:** `DOCKER_REGISTRY_GUIDE.md` for complete troubleshooting

### Nexus Repository Issues

```bash
# Check Nexus logs
microk8s kubectl logs -n nexus -l app=nexus

# Test Nexus UI
curl -I http://nexus.local

# Test Maven repository
curl http://nexus.local/repository/maven-releases/

# Restart Nexus
microk8s kubectl rollout restart deployment -n nexus nexus
```

### GitLab Issues

```bash
# Check GitLab logs
microk8s kubectl logs -n gitlab -l app=gitlab

# Restart GitLab
microk8s kubectl rollout restart deployment -n gitlab gitlab
```

---

## Architecture Summary

```
Developer
   │
   ├─> Push Code to GitLab (example-app)
   │
   └─> GitLab Webhook → Jenkins Pipeline
                            │
                            ├─> Unit Tests (every commit)
                            ├─> Integration Tests (MR + main)
                            ├─> Build & Publish (main branch only)
                            │   ├─> Build Docker Image (Jib)
                            │   ├─> Push to Nexus Docker Registry
                            │   └─> Publish Maven Artifacts
                            │
                            └─> Update k8s-deployments (dev branch)
                                   │
                                   └─> ArgoCD Detects Change
                                          │
                                          └─> Syncs to dev Namespace
                                                 │
                                                 └─> Application Running!

Promotion:
  dev → stage → prod (via GitLab MR with complete diff)
```

---

## Next Steps After Setup

1. **Add More Applications**
   - Copy example-app structure
   - Add to k8s-deployments repository
   - Create ArgoCD Applications

2. **Add Monitoring**
   - Prometheus for metrics
   - Grafana for dashboards
   - AlertManager for alerts

3. **Add Logging**
   - ELK Stack or Loki
   - Centralized log aggregation

4. **Security Hardening**
   - Enable Jenkins authentication
   - Use proper secrets management
   - Enable HTTPS with TLS certificates
   - Implement RBAC policies

5. **Performance Optimization**
   - Add HPA (Horizontal Pod Autoscaler)
   - Configure resource requests/limits
   - Add caching layers

---

## Appendix: Quick Reference

### Service URLs

- GitLab: http://gitlab.local
- Jenkins: http://jenkins.local
- Nexus: http://nexus.local
- ArgoCD: http://argocd.local

### Default Credentials

See: `/home/jmann/git/mannjg/deployment-pipeline/CREDENTIALS.md`

### Useful Commands

**Docker Registry:**
```bash
# Login to registry
docker login localhost:30500 -u admin -p admin123

# Or use helper script
./scripts/docker-registry-helper.sh login

# Check registry status
./scripts/docker-registry-helper.sh status

# Push an image
docker tag myimage:latest localhost:30500/myimage:latest
docker push localhost:30500/myimage:latest
```

**Kubernetes:**
```bash
# Check all pods
microk8s kubectl get pods --all-namespaces

# Check application in dev
microk8s kubectl get all -n dev

# Follow logs
microk8s kubectl logs -f -n dev -l app=example-app

# Port forward
microk8s kubectl port-forward -n dev svc/example-app 8080:80

# Restart deployment
microk8s kubectl rollout restart deployment -n dev example-app
```

**ArgoCD:**
```bash
# Check applications
argocd app list

# Sync application
argocd app sync example-app-dev

# Get application status
argocd app get example-app-dev

# View diff
argocd app diff example-app-dev
```

### Project Structure

```
deployment-pipeline/
├── scripts/               # Infrastructure setup scripts
├── k8s/                   # Kubernetes manifests
├── argocd/               # ArgoCD Application definitions
├── jenkins/              # Jenkins Docker agent
├── example-app/          # Quarkus application
├── k8s-deployments/      # CUE deployment configs
└── docs/                 # Documentation
```

---

## Success Criteria

You have successfully implemented the CI/CD pipeline when:

- [ ] All infrastructure services are running
- [ ] GitLab has both repositories (example-app, k8s-deployments)
- [ ] Jenkins can build and test example-app
- [ ] Nexus stores Docker images and Maven artifacts
- [ ] ArgoCD syncs deployments across dev/stage/prod
- [ ] Code changes flow automatically from commit to dev
- [ ] Promotion MRs show complete environment diffs
- [ ] Application is accessible in all environments

**Congratulations! Your CI/CD pipeline is complete! 🎉**
