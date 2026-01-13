# GitLab P2C Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate GitLab project paths from mixed `/example/` and `/root/` to `/p2c/` group, and centralize all GitLab URL configuration.

**Architecture:** Two configuration sources - `config/gitlab.env` for scripts and `pipeline-config` ConfigMap for Jenkins pods. All hardcoded URLs replaced with references to central config. Fail-fast if config missing.

**Tech Stack:** Bash, Groovy (Jenkins), YAML (Kubernetes/ArgoCD)

**Design Document:** `docs/plans/2026-01-13-gitlab-p2c-migration-design.md`

---

## Phase 1: Central Configuration

### Task 1: Create config/gitlab.env

**Files:**
- Create: `config/gitlab.env`

**Step 1: Create config directory**

```bash
mkdir -p config
```

**Step 2: Create gitlab.env file**

```bash
cat > config/gitlab.env << 'EOF'
#!/bin/bash
# GitLab Configuration - Single Source of Truth
# Used by: local scripts, CI/CD pipelines
#
# Source this file: source config/gitlab.env

# =============================================================================
# Host URLs
# =============================================================================
GITLAB_HOST_INTERNAL="gitlab.gitlab.svc.cluster.local"
GITLAB_HOST_EXTERNAL="gitlab.jmann.local"

# =============================================================================
# Group/Namespace
# =============================================================================
GITLAB_GROUP="p2c"

# =============================================================================
# Repository Names
# =============================================================================
APP_REPO_NAME="example-app"
DEPLOYMENTS_REPO_NAME="k8s-deployments"

# =============================================================================
# Full URLs (Internal - for pods/cluster communication)
# =============================================================================
GITLAB_URL="http://${GITLAB_HOST_INTERNAL}"
APP_REPO_URL="${GITLAB_URL}/${GITLAB_GROUP}/${APP_REPO_NAME}.git"
DEPLOYMENTS_REPO_URL="${GITLAB_URL}/${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}.git"

# =============================================================================
# Full URLs (External - for local access outside cluster)
# =============================================================================
GITLAB_URL_EXTERNAL="http://${GITLAB_HOST_EXTERNAL}"
APP_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${GITLAB_GROUP}/${APP_REPO_NAME}.git"
DEPLOYMENTS_REPO_URL_EXTERNAL="${GITLAB_URL_EXTERNAL}/${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}.git"

# =============================================================================
# Derived Variables (for scripts that need just the path)
# =============================================================================
APP_REPO_PATH="${GITLAB_GROUP}/${APP_REPO_NAME}"
DEPLOYMENTS_REPO_PATH="${GITLAB_GROUP}/${DEPLOYMENTS_REPO_NAME}"
EOF
```

**Step 3: Verify file created**

Run: `cat config/gitlab.env | head -20`
Expected: File contents displayed

**Step 4: Commit**

```bash
git add config/gitlab.env
git commit -m "feat: add centralized GitLab configuration

Create config/gitlab.env as single source of truth for:
- GitLab host URLs (internal/external)
- Group name (p2c)
- Repository names and full URLs

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 2: Update pipeline-config ConfigMap

**Files:**
- Modify: `k8s/jenkins/pipeline-config.yaml`

**Step 1: Update GITLAB_GROUP to p2c**

In `k8s/jenkins/pipeline-config.yaml`, change line 35:
```yaml
# FROM:
  GITLAB_GROUP: "root"

# TO:
  GITLAB_GROUP: "p2c"
```

**Step 2: Add repository URL variables**

After line 35, add:
```yaml
  # Repository URLs (internal - for pod-to-pod communication)
  APP_REPO_URL: "http://gitlab.gitlab.svc.cluster.local/p2c/example-app.git"
  DEPLOYMENTS_REPO_URL: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"
```

**Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('k8s/jenkins/pipeline-config.yaml'))"`
Expected: No output (valid YAML)

**Step 4: Commit**

```bash
git add k8s/jenkins/pipeline-config.yaml
git commit -m "feat: update pipeline-config with p2c group and repo URLs

- Change GITLAB_GROUP from 'root' to 'p2c'
- Add APP_REPO_URL and DEPLOYMENTS_REPO_URL

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 2: Jenkinsfile Updates

### Task 3: Update example-app/Jenkinsfile environment block

**Files:**
- Modify: `example-app/Jenkinsfile:345-348`

**Step 1: Replace hardcoded environment variables**

Change lines 345-348 from:
```groovy
        // Git repositories (internal cluster DNS)
        GITLAB_URL = 'http://gitlab.gitlab.svc.cluster.local'
        DEPLOYMENT_REPO = "${GITLAB_URL}/example/k8s-deployments.git"
```

To:
```groovy
        // Git repositories (from pipeline-config ConfigMap)
        GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')
        DEPLOYMENT_REPO = System.getenv('DEPLOYMENTS_REPO_URL')
```

**Step 2: Add validation in Checkout stage**

After line 366 (inside 'Checkout & Setup' stage script block), add validation:
```groovy
                        // Validate required environment variables
                        if (!env.GITLAB_URL) {
                            error "GITLAB_INTERNAL_URL not set. Configure pipeline-config ConfigMap."
                        }
                        if (!env.DEPLOYMENT_REPO) {
                            error "DEPLOYMENTS_REPO_URL not set. Configure pipeline-config ConfigMap."
                        }
```

**Step 3: Verify Groovy syntax**

Run: `grep -n "GITLAB_URL\|DEPLOYMENT_REPO" example-app/Jenkinsfile | head -10`
Expected: Shows updated variable references

**Step 4: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "refactor: use ConfigMap for GitLab URLs in example-app Jenkinsfile

- Replace hardcoded GITLAB_URL with System.getenv('GITLAB_INTERNAL_URL')
- Replace hardcoded DEPLOYMENT_REPO with System.getenv('DEPLOYMENTS_REPO_URL')
- Add fail-fast validation in Checkout stage

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 4: Update k8s-deployments/Jenkinsfile environment block

**Files:**
- Modify: `k8s-deployments/Jenkinsfile:263-266`

**Step 1: Replace hardcoded environment variables**

Change lines 263-266 from:
```groovy
    environment {
        // GitLab configuration
        GITLAB_URL = 'http://gitlab.gitlab.svc.cluster.local'
        DEPLOYMENTS_REPO = "${GITLAB_URL}/example/k8s-deployments.git"
```

To:
```groovy
    environment {
        // GitLab configuration (from pipeline-config ConfigMap)
        GITLAB_URL = System.getenv('GITLAB_INTERNAL_URL')
        DEPLOYMENTS_REPO = System.getenv('DEPLOYMENTS_REPO_URL')
```

**Step 2: Add validation in Detect Workflow stage**

In 'Detect Workflow' stage (around line 278), add after the echo block:
```groovy
                        // Validate required environment variables
                        if (!env.GITLAB_URL) {
                            error "GITLAB_INTERNAL_URL not set. Configure pipeline-config ConfigMap."
                        }
                        if (!env.DEPLOYMENTS_REPO) {
                            error "DEPLOYMENTS_REPO_URL not set. Configure pipeline-config ConfigMap."
                        }
```

**Step 3: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor: use ConfigMap for GitLab URLs in k8s-deployments Jenkinsfile

- Replace hardcoded GITLAB_URL with System.getenv('GITLAB_INTERNAL_URL')
- Replace hardcoded DEPLOYMENTS_REPO with System.getenv('DEPLOYMENTS_REPO_URL')
- Add fail-fast validation in Detect Workflow stage

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 3: ArgoCD Application Updates

### Task 5: Update ArgoCD application manifests

**Files:**
- Modify: `argocd/applications/example-app-dev.yaml:14`
- Modify: `argocd/applications/example-app-stage.yaml:14`
- Modify: `argocd/applications/example-app-prod.yaml:14`
- Modify: `argocd/applications/postgres-dev.yaml:14`
- Modify: `argocd/applications/postgres-stage.yaml:14`
- Modify: `argocd/applications/postgres-prod.yaml:14`

**Step 1: Update all ArgoCD applications**

Run sed replacement on all 6 files:
```bash
sed -i 's|/example/k8s-deployments.git|/p2c/k8s-deployments.git|g' \
  argocd/applications/example-app-dev.yaml \
  argocd/applications/example-app-stage.yaml \
  argocd/applications/example-app-prod.yaml \
  argocd/applications/postgres-dev.yaml \
  argocd/applications/postgres-stage.yaml \
  argocd/applications/postgres-prod.yaml
```

**Step 2: Verify changes**

Run: `grep -r "repoURL" argocd/applications/`
Expected: All show `/p2c/k8s-deployments.git`

**Step 3: Validate YAML syntax**

```bash
for f in argocd/applications/*.yaml; do
  python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "$f: OK"
done
```
Expected: All files show "OK"

**Step 4: Commit**

```bash
git add argocd/applications/
git commit -m "refactor: update ArgoCD applications to use p2c group

Update repoURL in all 6 application manifests:
- example-app-dev, example-app-stage, example-app-prod
- postgres-dev, postgres-stage, postgres-prod

Changed: /example/k8s-deployments.git -> /p2c/k8s-deployments.git

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 4: Script Updates

### Task 6: Create script helper for sourcing config

**Files:**
- Create: `scripts/lib/config.sh`

**Step 1: Create lib directory**

```bash
mkdir -p scripts/lib
```

**Step 2: Create config helper**

```bash
cat > scripts/lib/config.sh << 'EOF'
#!/bin/bash
# Helper to source GitLab configuration with validation
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

# Determine script location and source config
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_FILE="${_SCRIPT_DIR}/../config/gitlab.env"

# Handle scripts in subdirectories (like scripts/lib/)
if [[ ! -f "$_CONFIG_FILE" ]]; then
    _CONFIG_FILE="${_SCRIPT_DIR}/../../config/gitlab.env"
fi

if [[ ! -f "$_CONFIG_FILE" ]]; then
    echo "ERROR: Cannot find config/gitlab.env" >&2
    echo "Expected at: ${_SCRIPT_DIR}/../config/gitlab.env" >&2
    exit 1
fi

# shellcheck source=../../config/gitlab.env
source "$_CONFIG_FILE"

# Validate required variables
: "${GITLAB_URL:?GITLAB_URL is required - check config/gitlab.env}"
: "${GITLAB_GROUP:?GITLAB_GROUP is required - check config/gitlab.env}"
: "${DEPLOYMENTS_REPO_URL:?DEPLOYMENTS_REPO_URL is required - check config/gitlab.env}"
EOF
chmod +x scripts/lib/config.sh
```

**Step 3: Commit**

```bash
git add scripts/lib/config.sh
git commit -m "feat: add config helper script for GitLab configuration

scripts/lib/config.sh provides:
- Automatic sourcing of config/gitlab.env
- Path detection for scripts in any subdirectory
- Fail-fast validation of required variables

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 7: Update scripts/setup-gitlab-repos.sh

**Files:**
- Modify: `scripts/setup-gitlab-repos.sh`

**Step 1: Replace hardcoded config with sourced config**

At top of file (after shebang), replace lines 32-35:
```bash
# FROM:
GITLAB_URL="http://gitlab.gitlab.svc.cluster.local"
GITLAB_USER="root"

# TO:
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
GITLAB_USER="${GITLAB_USER:-root}"
```

**Step 2: Update repo path references**

Replace line 44:
```bash
# FROM:
    local remote_url="http://${GITLAB_USER}:${GITLAB_TOKEN}@gitlab.gitlab.svc.cluster.local/example/${repo_name}.git"

# TO:
    local remote_url="http://${GITLAB_USER}:${GITLAB_TOKEN}@${GITLAB_HOST_INTERNAL}/${GITLAB_GROUP}/${repo_name}.git"
```

Replace line 75:
```bash
# FROM:
    local remote_url="http://${GITLAB_USER}:${GITLAB_TOKEN}@gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git"

# TO:
    local remote_url="http://${GITLAB_USER}:${GITLAB_TOKEN}@${GITLAB_HOST_INTERNAL}/${DEPLOYMENTS_REPO_PATH}.git"
```

**Step 3: Commit**

```bash
git add scripts/setup-gitlab-repos.sh
git commit -m "refactor: use centralized config in setup-gitlab-repos.sh

- Source config/gitlab.env via lib/config.sh
- Replace hardcoded URLs with config variables
- Use GITLAB_GROUP and GITLAB_HOST_INTERNAL

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 8: Update scripts/create-gitlab-mr.sh

**Files:**
- Modify: `scripts/create-gitlab-mr.sh`

**Step 1: Add config sourcing**

After line 12, add:
```bash
# Source configuration if not already set
if [[ -z "${GITLAB_URL:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
fi
```

**Step 2: Update PROJECT_ID default**

Change line 16:
```bash
# FROM:
PROJECT_ID="${PROJECT_ID:-example%2Fk8s-deployments}"

# TO:
PROJECT_ID="${PROJECT_ID:-${GITLAB_GROUP}%2F${DEPLOYMENTS_REPO_NAME}}"
```

**Step 3: Commit**

```bash
git add scripts/create-gitlab-mr.sh
git commit -m "refactor: use centralized config in create-gitlab-mr.sh

- Source config if GITLAB_URL not already set
- Use GITLAB_GROUP and DEPLOYMENTS_REPO_NAME for PROJECT_ID

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 9: Update remaining scripts (batch)

**Files:**
- Modify: `scripts/setup-manifest-generator-job.sh`
- Modify: `scripts/configure-jenkins.sh`
- Modify: `scripts/setup-gitlab-webhook.sh`
- Modify: `scripts/setup-k8s-deployments-webhook.sh`
- Modify: `scripts/setup-k8s-deployments-validation-job.sh`
- Modify: `scripts/configure-gitlab.sh`
- Modify: `scripts/create-gitlab-projects.sh`
- Modify: `scripts/configure-gitlab-connection.sh`
- Modify: `scripts/configure-merge-requirements.sh`

**Step 1: Add config sourcing to each script**

For each script, add after the shebang/header:
```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
```

And remove any existing hardcoded GITLAB_URL definitions.

**Step 2: Update URL references**

- Replace `http://gitlab.local` with `${GITLAB_URL_EXTERNAL}`
- Replace `http://gitlab.gitlab.svc.cluster.local` with `${GITLAB_URL}`
- Replace `/example/` paths with `/${GITLAB_GROUP}/`
- Replace `/root/` paths with `/${GITLAB_GROUP}/`

**Step 3: Verify no hardcoded URLs remain**

```bash
grep -r "gitlab.local\|/example/\|/root/" scripts/ --include="*.sh" | grep -v "lib/config.sh"
```
Expected: No output (no hardcoded URLs)

**Step 4: Commit**

```bash
git add scripts/
git commit -m "refactor: update all scripts to use centralized GitLab config

Updated scripts:
- setup-manifest-generator-job.sh
- configure-jenkins.sh
- setup-gitlab-webhook.sh
- setup-k8s-deployments-webhook.sh
- setup-k8s-deployments-validation-job.sh
- configure-gitlab.sh
- create-gitlab-projects.sh
- configure-gitlab-connection.sh
- configure-merge-requirements.sh

All now source config/gitlab.env via lib/config.sh

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 5: Test Configuration Updates

### Task 10: Update e2e test configuration

**Files:**
- Modify: `tests/e2e/config/e2e-config.sh`
- Modify: `tests/e2e/config/e2e-config.template.sh`

**Step 1: Update e2e-config.sh**

Replace contents with:
```bash
#!/bin/bash
# E2E Test Configuration
# Sources central config and uses external URLs for outside-cluster access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../config/gitlab.env"

# Use external URLs for e2e tests (run from outside cluster)
export GITLAB_URL="${GITLAB_URL_EXTERNAL}"
export GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-9m86y9YHyGf77Kr8bRjX}"
export GITLAB_GROUP="${GITLAB_GROUP}"
export APP_REPO_URL="${APP_REPO_URL_EXTERNAL}"
export DEPLOYMENTS_REPO_URL="${DEPLOYMENTS_REPO_URL_EXTERNAL}"
```

**Step 2: Update e2e-config.template.sh**

Update the default URL:
```bash
# FROM:
export GITLAB_URL="${GITLAB_URL:-http://gitlab.gitlab.svc.cluster.local}"

# TO:
export GITLAB_URL="${GITLAB_URL:-http://gitlab.jmann.local}"
```

**Step 3: Commit**

```bash
git add tests/e2e/config/
git commit -m "refactor: update e2e test config to use centralized GitLab config

- e2e-config.sh now sources config/gitlab.env
- Uses external URLs for outside-cluster test execution
- Updated template default to gitlab.jmann.local

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 6: Verification

### Task 11: Verify no hardcoded URLs remain

**Step 1: Search for remaining hardcoded URLs**

```bash
echo "=== Checking for hardcoded /example/ paths ==="
grep -r "/example/" --include="*.sh" --include="*.groovy" --include="*.yaml" --include="Jenkinsfile*" . | grep -v ".git" | grep -v "docs/"

echo "=== Checking for hardcoded /root/ paths ==="
grep -r "/root/" --include="*.sh" --include="*.groovy" --include="*.yaml" --include="Jenkinsfile*" . | grep -v ".git" | grep -v "docs/"

echo "=== Checking for hardcoded gitlab.local ==="
grep -r "gitlab\.local[^.]" --include="*.sh" --include="*.groovy" --include="*.yaml" --include="Jenkinsfile*" . | grep -v ".git" | grep -v "docs/" | grep -v "gitlab.env" | grep -v "jmann.local"
```

Expected: No output or only documentation files

**Step 2: Verify config file is properly structured**

```bash
source config/gitlab.env
echo "GITLAB_GROUP: $GITLAB_GROUP"
echo "GITLAB_URL: $GITLAB_URL"
echo "DEPLOYMENTS_REPO_URL: $DEPLOYMENTS_REPO_URL"
```

Expected:
```
GITLAB_GROUP: p2c
GITLAB_URL: http://gitlab.gitlab.svc.cluster.local
DEPLOYMENTS_REPO_URL: http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git
```

---

### Task 12: Final commit and summary

**Step 1: Check git status**

```bash
git status
git log --oneline -10
```

**Step 2: Create summary of changes**

Expected commits:
1. feat: add centralized GitLab configuration
2. feat: update pipeline-config with p2c group and repo URLs
3. refactor: use ConfigMap for GitLab URLs in example-app Jenkinsfile
4. refactor: use ConfigMap for GitLab URLs in k8s-deployments Jenkinsfile
5. refactor: update ArgoCD applications to use p2c group
6. feat: add config helper script for GitLab configuration
7. refactor: use centralized config in setup-gitlab-repos.sh
8. refactor: use centralized config in create-gitlab-mr.sh
9. refactor: update all scripts to use centralized GitLab config
10. refactor: update e2e test config to use centralized GitLab config

---

## Post-Implementation: E2E Validation

After merging and deploying, validate with full pipeline flow:

1. **GitLab Setup:** Create `p2c` group, move projects
2. **Apply ConfigMap:** `envsubst < k8s/jenkins/pipeline-config.yaml | kubectl apply -f -`
3. **Update ArgoCD credentials:** Point to new repo path
4. **Apply ArgoCD apps:** `kubectl apply -f argocd/applications/`
5. **Test pipeline:** Push to example-app, verify MR created in p2c/k8s-deployments
6. **Verify promotion flow:** dev → stage → prod

See design document for detailed validation checkpoints.
