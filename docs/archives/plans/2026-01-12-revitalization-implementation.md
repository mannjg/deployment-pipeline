# Deployment Pipeline Revitalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Set up a clean CI/CD reference implementation on jmann-tower that can be cloned to airgapped clusters.

**Architecture:** Infrastructure components (GitLab, Jenkins, Nexus, ArgoCD) deployed via parameterized lightweight yamls on microk8s. CUE-based manifest generation with branch-per-environment promotion model.

**Tech Stack:** microk8s, cert-manager, GitLab CE, Jenkins, Nexus 3, ArgoCD, CUE

**Target Host:** jmann-tower (192.168.7.202) via SSH

---

## Phase 1: Foundation Infrastructure

### Task 1.1: Enable microk8s Addons

**Context:** jmann-tower already has microk8s running. We need hostpath-storage for PVCs.

**Step 1: Check current addon status**

Run (via SSH):
```bash
ssh jmann@jmann-tower "microk8s status --addon hostpath-storage"
```
Expected: Shows enabled or disabled status

**Step 2: Enable hostpath-storage if needed**

Run:
```bash
ssh jmann@jmann-tower "microk8s enable hostpath-storage"
```
Expected: "hostpath-storage is already enabled" or enables successfully

**Step 3: Verify StorageClass exists**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl get storageclass"
```
Expected: Shows `microk8s-hostpath` StorageClass

**Step 4: Verify ingress addon**

Run:
```bash
ssh jmann@jmann-tower "microk8s status --addon ingress"
```
Expected: Shows "enabled"

---

### Task 1.2: Create Namespaces

**Step 1: Create infrastructure namespaces**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl create namespace gitlab --dry-run=client -o yaml | microk8s kubectl apply -f -"
ssh jmann@jmann-tower "microk8s kubectl create namespace jenkins --dry-run=client -o yaml | microk8s kubectl apply -f -"
ssh jmann@jmann-tower "microk8s kubectl create namespace nexus --dry-run=client -o yaml | microk8s kubectl apply -f -"
ssh jmann@jmann-tower "microk8s kubectl create namespace argocd --dry-run=client -o yaml | microk8s kubectl apply -f -"
ssh jmann@jmann-tower "microk8s kubectl create namespace cert-manager --dry-run=client -o yaml | microk8s kubectl apply -f -"
```

**Step 2: Create application namespaces**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl create namespace dev --dry-run=client -o yaml | microk8s kubectl apply -f -"
ssh jmann@jmann-tower "microk8s kubectl create namespace stage --dry-run=client -o yaml | microk8s kubectl apply -f -"
ssh jmann@jmann-tower "microk8s kubectl create namespace prod --dry-run=client -o yaml | microk8s kubectl apply -f -"
```

**Step 3: Verify namespaces**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl get namespaces"
```
Expected: All 8 namespaces exist (gitlab, jenkins, nexus, argocd, cert-manager, dev, stage, prod)

---

### Task 1.3: Create Environment Configuration

**Files:**
- Create: `env.example`
- Create: `env.local`

**Step 1: Create env.example template**

Create file `env.example`:
```bash
# Infrastructure Hostnames
# These will be used for ingress rules and certificate generation
GITLAB_HOST=gitlab.example.local
JENKINS_HOST=jenkins.example.local
NEXUS_HOST=nexus.example.local
ARGOCD_HOST=argocd.example.local

# Cluster Configuration
STORAGE_CLASS=microk8s-hostpath

# GitLab Configuration
GITLAB_ROOT_PASSWORD=changeme

# Nexus Configuration
NEXUS_ADMIN_PASSWORD=changeme
```

**Step 2: Create env.local for jmann-tower**

Create file `env.local`:
```bash
# Infrastructure Hostnames for jmann-tower
GITLAB_HOST=gitlab.jmann.local
JENKINS_HOST=jenkins.jmann.local
NEXUS_HOST=nexus.jmann.local
ARGOCD_HOST=argocd.jmann.local

# Cluster Configuration
STORAGE_CLASS=microk8s-hostpath

# GitLab Configuration
GITLAB_ROOT_PASSWORD=GitLab2026!

# Nexus Configuration
NEXUS_ADMIN_PASSWORD=Nexus2026!
```

**Step 3: Add env.local to .gitignore**

Append to `.gitignore`:
```
# Local environment configuration (contains secrets)
env.local
```

**Step 4: Commit**

```bash
git add env.example .gitignore
git commit -m "feat: add environment configuration templates"
```

---

### Task 1.4: Install cert-manager

**Files:**
- Create: `k8s/cert-manager/cert-manager.yaml`
- Create: `k8s/cert-manager/cluster-issuer.yaml`

**Step 1: Download cert-manager manifest**

Run:
```bash
curl -Lo k8s/cert-manager/cert-manager.yaml https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
```

**Step 2: Create self-signed ClusterIssuer**

Create file `k8s/cert-manager/cluster-issuer.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: ca-key-pair
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ca-certificate
  namespace: cert-manager
spec:
  isCA: true
  commonName: jmann-local-ca
  secretName: ca-key-pair
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

**Step 3: Apply cert-manager**

Run:
```bash
scp k8s/cert-manager/cert-manager.yaml jmann@jmann-tower:/tmp/
ssh jmann@jmann-tower "microk8s kubectl apply -f /tmp/cert-manager.yaml"
```

**Step 4: Wait for cert-manager pods**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s"
```
Expected: All pods ready

**Step 5: Apply ClusterIssuer**

Run:
```bash
scp k8s/cert-manager/cluster-issuer.yaml jmann@jmann-tower:/tmp/
ssh jmann@jmann-tower "microk8s kubectl apply -f /tmp/cluster-issuer.yaml"
```

**Step 6: Verify ClusterIssuer ready**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl get clusterissuer"
```
Expected: `selfsigned-issuer` and `ca-issuer` both show READY=True

**Step 7: Commit**

```bash
git add k8s/cert-manager/
git commit -m "feat: add cert-manager with self-signed CA"
```

---

### Task 1.5: Parameterize GitLab Manifest

**Files:**
- Modify: `k8s/gitlab/gitlab-lightweight.yaml`

**Step 1: Read current gitlab manifest**

Read `k8s/gitlab/gitlab-lightweight.yaml` to understand current structure.

**Step 2: Update with envsubst placeholders**

Update the file to use `${GITLAB_HOST}`, `${STORAGE_CLASS}`, `${GITLAB_ROOT_PASSWORD}` placeholders in:
- Ingress host
- TLS secretName
- PVC storageClassName
- GitLab environment variables

**Step 3: Add Certificate resource**

Add to the manifest:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gitlab-tls
  namespace: gitlab
spec:
  secretName: gitlab-tls
  issuerRef:
    name: ca-issuer
    kind: ClusterIssuer
  commonName: ${GITLAB_HOST}
  dnsNames:
    - ${GITLAB_HOST}
```

**Step 4: Commit**

```bash
git add k8s/gitlab/gitlab-lightweight.yaml
git commit -m "feat: parameterize GitLab manifest for envsubst"
```

---

### Task 1.6: Create Infrastructure Apply Script

**Files:**
- Create: `scripts/apply-infrastructure.sh`

**Step 1: Create the script**

Create file `scripts/apply-infrastructure.sh`:
```bash
#!/bin/bash
set -euo pipefail

# Load environment configuration
ENV_FILE="${1:-env.local}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: Environment file $ENV_FILE not found"
    exit 1
fi
source "$ENV_FILE"

REMOTE_HOST="${REMOTE_HOST:-jmann-tower}"
REMOTE_USER="${REMOTE_USER:-jmann}"

# Function to apply a manifest with envsubst
apply_manifest() {
    local manifest="$1"
    local namespace="${2:-}"

    echo "Applying $manifest..."

    # Substitute variables and apply
    envsubst < "$manifest" | ssh "$REMOTE_USER@$REMOTE_HOST" "microk8s kubectl apply -f -"
}

# Apply cert-manager (no substitution needed)
echo "=== Applying cert-manager ==="
scp k8s/cert-manager/cert-manager.yaml "$REMOTE_USER@$REMOTE_HOST:/tmp/"
ssh "$REMOTE_USER@$REMOTE_HOST" "microk8s kubectl apply -f /tmp/cert-manager.yaml"
echo "Waiting for cert-manager..."
ssh "$REMOTE_USER@$REMOTE_HOST" "microk8s kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s"

# Apply cluster issuers
apply_manifest "k8s/cert-manager/cluster-issuer.yaml"

# Apply GitLab
echo "=== Applying GitLab ==="
apply_manifest "k8s/gitlab/gitlab-lightweight.yaml"

# Apply Nexus
echo "=== Applying Nexus ==="
apply_manifest "k8s/nexus/nexus-lightweight.yaml"

# Apply Jenkins
echo "=== Applying Jenkins ==="
apply_manifest "k8s/jenkins/jenkins-lightweight.yaml"

# Apply ArgoCD
echo "=== Applying ArgoCD ==="
apply_manifest "k8s/argocd/install.yaml"
apply_manifest "k8s/argocd/ingress.yaml"

echo "=== Infrastructure applied ==="
echo "Run scripts/verify-infrastructure.sh to check status"
```

**Step 2: Make executable**

```bash
chmod +x scripts/apply-infrastructure.sh
```

**Step 3: Commit**

```bash
git add scripts/apply-infrastructure.sh
git commit -m "feat: add infrastructure apply script with envsubst"
```

---

### Task 1.7: Deploy and Verify GitLab

**Step 1: Apply GitLab manifest**

Run:
```bash
source env.local
envsubst < k8s/gitlab/gitlab-lightweight.yaml | ssh jmann@jmann-tower "microk8s kubectl apply -f -"
```

**Step 2: Wait for GitLab pod**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl wait --for=condition=ready pod -l app=gitlab -n gitlab --timeout=300s"
```
Expected: Pod ready (may take 3-5 minutes)

**Step 3: Verify certificate issued**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl get certificate -n gitlab"
```
Expected: `gitlab-tls` shows READY=True

**Step 4: Add hosts entry (local machine)**

Run:
```bash
echo "192.168.7.202 gitlab.jmann.local" | sudo tee -a /etc/hosts
```

**Step 5: Verify external HTTPS access**

Run:
```bash
curl -k https://gitlab.jmann.local/api/v4/version
```
Expected: Returns GitLab version JSON

**Step 6: Verify internal access from pod**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl -k https://gitlab.jmann.local/api/v4/version"
```
Expected: Returns GitLab version JSON from inside cluster

---

### Task 1.8: Parameterize and Deploy Nexus

**Files:**
- Modify: `k8s/nexus/nexus-lightweight.yaml`

**Step 1: Update Nexus manifest with placeholders**

Update to use `${NEXUS_HOST}`, `${STORAGE_CLASS}` placeholders and add Certificate resource.

**Step 2: Apply Nexus**

Run:
```bash
source env.local
envsubst < k8s/nexus/nexus-lightweight.yaml | ssh jmann@jmann-tower "microk8s kubectl apply -f -"
```

**Step 3: Wait for Nexus pod**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl wait --for=condition=ready pod -l app=nexus -n nexus --timeout=300s"
```

**Step 4: Add hosts entry**

Run:
```bash
echo "192.168.7.202 nexus.jmann.local" | sudo tee -a /etc/hosts
```

**Step 5: Verify external HTTPS**

Run:
```bash
curl -k https://nexus.jmann.local/service/rest/v1/status
```
Expected: Returns status JSON

**Step 6: Verify internal access**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl -k https://nexus.jmann.local/service/rest/v1/status"
```
Expected: Returns status JSON

**Step 7: Commit**

```bash
git add k8s/nexus/nexus-lightweight.yaml
git commit -m "feat: parameterize Nexus manifest"
```

---

### Task 1.9: Parameterize and Deploy Jenkins

**Files:**
- Modify: `k8s/jenkins/jenkins-lightweight.yaml`

**Step 1: Update Jenkins manifest with placeholders**

Update to use `${JENKINS_HOST}`, `${STORAGE_CLASS}` placeholders and add Certificate resource.

**Step 2: Apply Jenkins**

Run:
```bash
source env.local
envsubst < k8s/jenkins/jenkins-lightweight.yaml | ssh jmann@jmann-tower "microk8s kubectl apply -f -"
```

**Step 3: Wait for Jenkins pod**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl wait --for=condition=ready pod -l app=jenkins -n jenkins --timeout=300s"
```

**Step 4: Add hosts entry**

Run:
```bash
echo "192.168.7.202 jenkins.jmann.local" | sudo tee -a /etc/hosts
```

**Step 5: Verify external HTTPS**

Run:
```bash
curl -k https://jenkins.jmann.local/api/json
```
Expected: Returns Jenkins API JSON

**Step 6: Verify internal access**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl -k https://jenkins.jmann.local/api/json"
```
Expected: Returns Jenkins API JSON

**Step 7: Commit**

```bash
git add k8s/jenkins/jenkins-lightweight.yaml
git commit -m "feat: parameterize Jenkins manifest"
```

---

### Task 1.10: Parameterize and Deploy ArgoCD

**Files:**
- Modify: `k8s/argocd/ingress.yaml`

**Step 1: Update ArgoCD ingress with placeholders**

Update to use `${ARGOCD_HOST}` placeholder and add Certificate resource.

**Step 2: Apply ArgoCD**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
source env.local
envsubst < k8s/argocd/ingress.yaml | ssh jmann@jmann-tower "microk8s kubectl apply -f -"
```

**Step 3: Wait for ArgoCD pods**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s"
```

**Step 4: Add hosts entry**

Run:
```bash
echo "192.168.7.202 argocd.jmann.local" | sudo tee -a /etc/hosts
```

**Step 5: Verify external HTTPS**

Run:
```bash
curl -k https://argocd.jmann.local/api/version
```
Expected: Returns ArgoCD version JSON

**Step 6: Verify internal access**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- curl -k https://argocd.jmann.local/api/version"
```
Expected: Returns ArgoCD version JSON

**Step 7: Commit**

```bash
git add k8s/argocd/ingress.yaml
git commit -m "feat: parameterize ArgoCD ingress"
```

---

### Task 1.11: Phase 1 Gate Verification

**Step 1: Verify all pods healthy**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd|cert-manager'"
```
Expected: All pods Running/Completed

**Step 2: Create verification script**

Create file `scripts/verify-phase1.sh`:
```bash
#!/bin/bash
set -euo pipefail

source "${1:-env.local}"
REMOTE_HOST="${REMOTE_HOST:-jmann-tower}"

echo "=== Phase 1 Verification ==="

# External access tests
echo "Testing external HTTPS access..."
curl -sk "https://$GITLAB_HOST/api/v4/version" | grep -q version && echo "✓ GitLab external" || echo "✗ GitLab external"
curl -sk "https://$NEXUS_HOST/service/rest/v1/status" | grep -q status && echo "✓ Nexus external" || echo "✗ Nexus external"
curl -sk "https://$JENKINS_HOST/api/json" | grep -q _class && echo "✓ Jenkins external" || echo "✗ Jenkins external"
curl -sk "https://$ARGOCD_HOST/api/version" | grep -q Version && echo "✓ ArgoCD external" || echo "✗ ArgoCD external"

# Internal access tests
echo ""
echo "Testing internal pod access..."
for host in "$GITLAB_HOST" "$NEXUS_HOST" "$JENKINS_HOST" "$ARGOCD_HOST"; do
    ssh "$REMOTE_HOST" "microk8s kubectl run curl-test-$RANDOM --image=curlimages/curl --rm -it --restart=Never -- curl -sk https://$host/ -o /dev/null -w '%{http_code}'" 2>/dev/null | grep -q "200\|302" && echo "✓ $host internal" || echo "✗ $host internal"
done

echo ""
echo "=== Phase 1 Complete ==="
```

**Step 3: Run verification**

```bash
chmod +x scripts/verify-phase1.sh
./scripts/verify-phase1.sh
```
Expected: All checks pass (✓)

**Step 4: Commit**

```bash
git add scripts/verify-phase1.sh
git commit -m "feat: add Phase 1 verification script"
```

---

## Phase 2: Integration Verification

### Task 2.1: Configure Jenkins GitLab Credentials

**Step 1: Get GitLab root password**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl get secret gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d"
```

**Step 2: Create GitLab API token**

1. Open https://gitlab.jmann.local in browser
2. Login as root with password from Step 1
3. Go to User Settings → Access Tokens
4. Create token with `api`, `read_repository`, `write_repository` scopes
5. Save token value

**Step 3: Create Jenkins credential via API**

Run (replace TOKEN with actual token):
```bash
GITLAB_TOKEN="<token-from-step-2>"
curl -k -X POST "https://jenkins.jmann.local/credentials/store/system/domain/_/createCredentials" \
  --user admin:$(ssh jmann@jmann-tower "microk8s kubectl get secret jenkins-admin -n jenkins -o jsonpath='{.data.password}' | base64 -d") \
  --data-urlencode "json={
    '': '0',
    'credentials': {
      'scope': 'GLOBAL',
      'id': 'gitlab-token',
      'description': 'GitLab API Token',
      'secret': '$GITLAB_TOKEN',
      '\$class': 'org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl'
    }
  }"
```

**Step 4: Verify credential exists**

Run:
```bash
curl -sk "https://jenkins.jmann.local/credentials/store/system/domain/_/credential/gitlab-token/api/json" \
  --user admin:$(ssh jmann@jmann-tower "microk8s kubectl get secret jenkins-admin -n jenkins -o jsonpath='{.data.password}' | base64 -d")
```
Expected: Returns credential JSON

---

### Task 2.2: Configure Jenkins Nexus Credentials

**Step 1: Create Jenkins credential for Nexus**

Run:
```bash
source env.local
curl -k -X POST "https://jenkins.jmann.local/credentials/store/system/domain/_/createCredentials" \
  --user admin:$(ssh jmann@jmann-tower "microk8s kubectl get secret jenkins-admin -n jenkins -o jsonpath='{.data.password}' | base64 -d") \
  --data-urlencode "json={
    '': '0',
    'credentials': {
      'scope': 'GLOBAL',
      'id': 'nexus-credentials',
      'description': 'Nexus Admin Credentials',
      'username': 'admin',
      'password': '$NEXUS_ADMIN_PASSWORD',
      '\$class': 'com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl'
    }
  }"
```

**Step 2: Verify credential**

Run:
```bash
curl -sk "https://jenkins.jmann.local/credentials/store/system/domain/_/credential/nexus-credentials/api/json" \
  --user admin:$(ssh jmann@jmann-tower "microk8s kubectl get secret jenkins-admin -n jenkins -o jsonpath='{.data.password}' | base64 -d")
```
Expected: Returns credential JSON

---

### Task 2.3: Test Jenkins Can Clone from GitLab

**Step 1: Create test project in GitLab**

Run:
```bash
curl -sk -X POST "https://gitlab.jmann.local/api/v4/projects" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "test-clone", "visibility": "private"}'
```

**Step 2: Create Jenkins test job**

Create a freestyle job that clones from GitLab and verify it succeeds.

**Step 3: Verify clone works**

Check Jenkins console output shows successful clone.

---

### Task 2.4: Configure ArgoCD GitLab Repository

**Step 1: Get ArgoCD admin password**

Run:
```bash
ssh jmann@jmann-tower "microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

**Step 2: Add repository via ArgoCD CLI or UI**

```bash
argocd login argocd.jmann.local --insecure --username admin --password <password>
argocd repo add https://gitlab.jmann.local/example/k8s-deployments.git \
  --username root \
  --password $GITLAB_TOKEN \
  --insecure-skip-server-verification
```

**Step 3: Verify repository connection**

Run:
```bash
argocd repo list
```
Expected: Repository shows as connected

---

### Task 2.5: Phase 2 Gate Verification

**Step 1: Create verification script**

Create file `scripts/verify-phase2.sh`:
```bash
#!/bin/bash
set -euo pipefail

echo "=== Phase 2 Integration Verification ==="

echo "Checking Jenkins credentials..."
# Verify gitlab-token credential
# Verify nexus-credentials credential

echo "Checking ArgoCD repository connection..."
# Verify repo is connected

echo "=== Phase 2 Complete ==="
```

---

## Phase 3: Repository Cleanup

### Task 3.1: Clean Parent Repository Duplicates

**Files to delete from deployment-pipeline:**
- `cue-templates/`
- `envs/`
- `manifests/`
- `cue.mod/`
- `k8s/configmap.cue`
- `k8s/deployment.cue`
- `k8s/pvc.cue`
- `k8s/secret.cue`
- `k8s/service.cue`
- `jenkins/k8s-deployments-validation.Jenkinsfile`
- `jenkins/pipelines/`

**Step 1: Remove duplicate files**

Run:
```bash
rm -rf cue-templates/ envs/ manifests/ cue.mod/ src/
rm -f k8s/configmap.cue k8s/deployment.cue k8s/pvc.cue k8s/secret.cue k8s/service.cue
rm -rf jenkins/pipelines/
rm -f jenkins/k8s-deployments-validation.Jenkinsfile
rm -f Jenkinsfile pom.xml
```

**Step 2: Verify structure**

Run:
```bash
ls -la
```
Expected: Only k8s/, docs/, scripts/, example-app/, k8s-deployments/, env.* files remain

**Step 3: Commit**

```bash
git add -A
git commit -m "cleanup: remove duplicate CUE files from parent repo

k8s-deployments is now the sole source of truth for CUE definitions"
```

---

### Task 3.2: Create k8s-deployments Branch Structure

**Step 1: Enter k8s-deployments directory**

```bash
cd k8s-deployments
```

**Step 2: Create dev branch from main**

```bash
git checkout -b dev
```

**Step 3: Create single env.cue for dev**

Create/update `env.cue`:
```cue
package config

env: "dev"

config: {
    namespace: "dev"
    replicas: 1

    registry: "nexus.jmann.local:8082"

    domain: "dev.jmann.local"

    resources: {
        requests: {
            memory: "256Mi"
            cpu: "100m"
        }
        limits: {
            memory: "512Mi"
            cpu: "500m"
        }
    }
}
```

**Step 4: Remove old env files**

```bash
rm -f envs/dev.cue envs/stage.cue envs/prod.cue
rmdir envs/
```

**Step 5: Commit dev branch**

```bash
git add -A
git commit -m "feat: create dev branch with single env.cue"
git push -u origin dev
```

**Step 6: Create stage branch**

```bash
git checkout -b stage
```

**Step 7: Update env.cue for stage**

Update `env.cue`:
```cue
package config

env: "stage"

config: {
    namespace: "stage"
    replicas: 2

    registry: "nexus.jmann.local:8082"

    domain: "stage.jmann.local"

    resources: {
        requests: {
            memory: "512Mi"
            cpu: "200m"
        }
        limits: {
            memory: "1Gi"
            cpu: "1000m"
        }
    }
}
```

**Step 8: Commit and push stage**

```bash
git add env.cue
git commit -m "feat: create stage branch with stage env.cue"
git push -u origin stage
```

**Step 9: Create prod branch (similar process)**

```bash
git checkout -b prod
# Update env.cue with prod values (replicas: 3, etc.)
git add env.cue
git commit -m "feat: create prod branch with prod env.cue"
git push -u origin prod
```

**Step 10: Return to main and clean up**

```bash
git checkout main
rm -f envs/dev.cue envs/stage.cue envs/prod.cue
rmdir envs/ 2>/dev/null || true
git add -A
git commit -m "cleanup: remove env files from main (now branch-specific)"
git push
```

---

### Task 3.3: Phase 3 Gate Verification

**Step 1: Verify branch structure**

```bash
cd k8s-deployments
git branch -a
```
Expected: main, dev, stage, prod branches exist

**Step 2: Verify CUE evaluation on each branch**

```bash
for branch in dev stage prod; do
    git checkout $branch
    cue eval ./... > /dev/null && echo "✓ $branch CUE valid" || echo "✗ $branch CUE invalid"
done
git checkout main
```
Expected: All branches validate

---

## Phase 4: Pipeline Implementation

### Task 4.1: Update k8s-deployments Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile`

**Step 1: Update Jenkinsfile with regenerate-on-merge logic**

The Jenkinsfile should:
1. Validate CUE syntax
2. Generate manifests using current branch's env.cue
3. Commit generated manifests
4. Create MR for promotion (if on dev, create MR to stage, etc.)

**Step 2: Test on dev branch**

Push a change to dev and verify pipeline runs.

---

### Task 4.2: Update example-app Jenkinsfile

**Files:**
- Modify: `example-app/Jenkinsfile`

**Step 1: Update Stage 5 to copy app.cue**

Add logic to:
1. Clone k8s-deployments
2. Copy `deployment/app.cue` to `services/apps/example-app.cue`
3. Update image tag in the CUE file
4. Commit and push

---

## Phase 5-7: To Be Detailed

Phases 5 (Promotion Flow), 6 (Multi-app), and 7 (Documentation) will be detailed after Phase 4 is complete and verified.

---

## Quick Reference

**SSH to jmann-tower:**
```bash
ssh jmann@jmann-tower
```

**Run kubectl on jmann-tower:**
```bash
ssh jmann@jmann-tower "microk8s kubectl <command>"
```

**Apply manifest with envsubst:**
```bash
source env.local
envsubst < k8s/component/manifest.yaml | ssh jmann@jmann-tower "microk8s kubectl apply -f -"
```

**Check all infrastructure pods:**
```bash
ssh jmann@jmann-tower "microk8s kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd|cert-manager'"
```
