# Lib Directory Refactoring Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Establish a clean shared library structure for scripts with fail-fast credential handling and no hardcoded defaults.

**Architecture:** Split `scripts/lib/config.sh` into three focused libraries: `logging.sh` (output helpers), `infra.sh` (infrastructure config), and `credentials.sh` (fail-fast K8s secret access). Remove the `local.env` pattern entirely - credentials come from K8s secrets or environment variables only.

**Tech Stack:** Bash, kubectl, Kubernetes secrets

---

## Task 1: Create lib/logging.sh

**Files:**
- Create: `scripts/lib/logging.sh`

**Step 1: Create the logging library**

```bash
#!/bin/bash
# Shared logging functions for pipeline scripts
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/logging.sh"

# Colors (only if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Logging functions
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# Validation-style logging (matches validate-pipeline.sh)
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }

# Section headers
log_header() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$*"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
```

**Step 2: Verify the file is syntactically correct**

Run: `bash -n scripts/lib/logging.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 3: Verify functions work when sourced**

Run: `source scripts/lib/logging.sh && log_info "test" && log_pass "test"`
Expected: Colored output with `[INFO] test` and `[✓] test`

**Step 4: Commit**

```bash
git add scripts/lib/logging.sh
git commit -m "feat(lib): add shared logging library

Extracts duplicated logging functions from 15+ scripts into
a single shared library. Provides both log_info/warn/error
style and log_step/pass/fail validation style.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 2: Create lib/infra.sh

**Files:**
- Create: `scripts/lib/infra.sh`
- Delete: `scripts/lib/config.sh` (after infra.sh is working)

**Step 1: Create the infrastructure config library**

```bash
#!/bin/bash
# Infrastructure configuration loader
# Sources config/infra.env and validates required variables
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/infra.sh"

set -euo pipefail

# Determine paths
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT="$(cd "$_LIB_DIR/../.." && pwd)"
_INFRA_ENV="$_PROJECT_ROOT/config/infra.env"

# Source logging if not already loaded
if ! declare -f log_error &>/dev/null; then
    source "$_LIB_DIR/logging.sh"
fi

# Verify infra.env exists
if [[ ! -f "$_INFRA_ENV" ]]; then
    log_error "Infrastructure config not found: $_INFRA_ENV"
    exit 1
fi

# Source infrastructure configuration
# shellcheck source=../../config/infra.env
source "$_INFRA_ENV"

# Validate required variables exist
: "${GITLAB_NAMESPACE:?GITLAB_NAMESPACE not set in infra.env}"
: "${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set in infra.env}"
: "${GITLAB_GROUP:?GITLAB_GROUP not set in infra.env}"
: "${GITLAB_API_TOKEN_SECRET:?GITLAB_API_TOKEN_SECRET not set in infra.env}"
: "${GITLAB_API_TOKEN_KEY:?GITLAB_API_TOKEN_KEY not set in infra.env}"
: "${JENKINS_NAMESPACE:?JENKINS_NAMESPACE not set in infra.env}"
: "${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set in infra.env}"
: "${JENKINS_ADMIN_SECRET:?JENKINS_ADMIN_SECRET not set in infra.env}"

# Export PROJECT_ROOT for scripts that need it
export PROJECT_ROOT="$_PROJECT_ROOT"
```

**Step 2: Verify syntax**

Run: `bash -n scripts/lib/infra.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 3: Verify it sources infra.env correctly**

Run: `source scripts/lib/infra.sh && echo "GITLAB_GROUP=$GITLAB_GROUP"`
Expected: `GITLAB_GROUP=p2c`

**Step 4: Delete the old config.sh**

Run: `rm scripts/lib/config.sh`

**Step 5: Commit**

```bash
git add scripts/lib/infra.sh
git rm scripts/lib/config.sh
git commit -m "feat(lib): replace config.sh with infra.sh

- Sources config/infra.env (was incorrectly referencing gitlab.env)
- Validates required infrastructure variables
- Auto-sources logging.sh for consistent error output
- Removes broken config.sh that referenced non-existent file

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 3: Create lib/credentials.sh

**Files:**
- Create: `scripts/lib/credentials.sh`

**Step 1: Create the credentials library**

```bash
#!/bin/bash
# Credential helpers with fail-fast behavior
# Fetches credentials from K8s secrets or environment variables
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/credentials.sh"
#        GITLAB_TOKEN=$(require_gitlab_token)

set -euo pipefail

# Determine paths
_CRED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies if not already loaded
if ! declare -f log_error &>/dev/null; then
    source "$_CRED_LIB_DIR/logging.sh"
fi

# Ensure infra.sh is loaded (we need secret names from infra.env)
if [[ -z "${GITLAB_API_TOKEN_SECRET:-}" ]]; then
    source "$_CRED_LIB_DIR/infra.sh"
fi

# Fetch GitLab API token - fails if not available
# Checks: 1) GITLAB_TOKEN env var, 2) K8s secret
require_gitlab_token() {
    # Check environment variable first
    if [[ -n "${GITLAB_TOKEN:-}" ]]; then
        echo "$GITLAB_TOKEN"
        return 0
    fi

    # Try K8s secret
    local token
    token=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$token" ]]; then
        echo "$token"
        return 0
    fi

    # Fail fast with clear instructions
    log_error "GitLab token not available."
    echo "" >&2
    echo "Provide token via one of:" >&2
    echo "  1. Environment: export GITLAB_TOKEN=glpat-..." >&2
    echo "  2. K8s secret:  kubectl get secret $GITLAB_API_TOKEN_SECRET -n $GITLAB_NAMESPACE" >&2
    exit 1
}

# Fetch Jenkins credentials - fails if not available
# Returns: username:password (for basic auth)
require_jenkins_credentials() {
    local user password

    # Check environment variables first
    if [[ -n "${JENKINS_USER:-}" && -n "${JENKINS_TOKEN:-}" ]]; then
        echo "${JENKINS_USER}:${JENKINS_TOKEN}"
        return 0
    fi

    # Try K8s secret
    user=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    password=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
        -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$user" && -n "$password" ]]; then
        echo "${user}:${password}"
        return 0
    fi

    # Fail fast with clear instructions
    log_error "Jenkins credentials not available."
    echo "" >&2
    echo "Provide credentials via one of:" >&2
    echo "  1. Environment: export JENKINS_USER=... JENKINS_TOKEN=..." >&2
    echo "  2. K8s secret:  kubectl get secret $JENKINS_ADMIN_SECRET -n $JENKINS_NAMESPACE" >&2
    exit 1
}

# Fetch GitLab user credentials (username for git operations)
require_gitlab_user() {
    # Check environment variable first
    if [[ -n "${GITLAB_USER:-}" ]]; then
        echo "$GITLAB_USER"
        return 0
    fi

    # Try K8s secret
    local user
    user=$(kubectl get secret "$GITLAB_USER_SECRET" -n "$GITLAB_NAMESPACE" \
        -o jsonpath="{.data.${GITLAB_USER_KEY}}" 2>/dev/null | base64 -d) || true

    if [[ -n "$user" ]]; then
        echo "$user"
        return 0
    fi

    # Fail fast
    log_error "GitLab user not available."
    echo "" >&2
    echo "Provide via: export GITLAB_USER=... or ensure K8s secret exists" >&2
    exit 1
}
```

**Step 2: Verify syntax**

Run: `bash -n scripts/lib/credentials.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 3: Test fail-fast behavior (without K8s access)**

Run: `unset GITLAB_TOKEN; source scripts/lib/credentials.sh && require_gitlab_token`
Expected: Error message with instructions, exit code 1

**Step 4: Test with environment variable**

Run: `GITLAB_TOKEN=test-token bash -c 'source scripts/lib/credentials.sh && require_gitlab_token'`
Expected: `test-token`

**Step 5: Commit**

```bash
git add scripts/lib/credentials.sh
git commit -m "feat(lib): add fail-fast credential helpers

Provides require_gitlab_token() and require_jenkins_credentials()
that fetch from environment variables or K8s secrets. Fails
immediately with clear instructions if credentials unavailable.

No hardcoded defaults. No silent fallbacks.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 4: Update scripts with hardcoded tokens

**Files:**
- Modify: `scripts/03-pipelines/create-gitlab-projects.sh`
- Modify: `scripts/03-pipelines/configure-merge-requirements.sh`
- Modify: `scripts/02-configure/configure-gitlab-connection.sh`

**Step 1: Update create-gitlab-projects.sh**

Replace the entire file with:

```bash
#!/bin/bash
# Create GitLab projects for the pipeline demo
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)

log_header "Creating GitLab Projects"
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Group: ${GITLAB_GROUP}"
echo ""

# Create group
log_step "Creating group '${GITLAB_GROUP}'..."
curl -sf -X POST "${GITLAB_URL_EXTERNAL}/api/v4/groups" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${GITLAB_GROUP}\", \"path\": \"${GITLAB_GROUP}\", \"visibility\": \"private\"}" > /dev/null 2>&1 \
  && log_pass "Group created" \
  || log_warn "Group may already exist"

# Get group ID
GROUP_ID=$(curl -sf "${GITLAB_URL_EXTERNAL}/api/v4/groups/${GITLAB_GROUP}" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
log_info "Group ID: $GROUP_ID"

# Create example-app project
log_step "Creating project '${APP_REPO_NAME}'..."
curl -sf -X POST "${GITLAB_URL_EXTERNAL}/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${APP_REPO_NAME}\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 \
  && log_pass "Project '${APP_REPO_NAME}' created" \
  || log_warn "Project '${APP_REPO_NAME}' may already exist"

# Create k8s-deployments project
log_step "Creating project '${DEPLOYMENTS_REPO_NAME}'..."
curl -sf -X POST "${GITLAB_URL_EXTERNAL}/api/v4/projects" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"name\": \"${DEPLOYMENTS_REPO_NAME}\", \"namespace_id\": $GROUP_ID, \"visibility\": \"private\"}" > /dev/null 2>&1 \
  && log_pass "Project '${DEPLOYMENTS_REPO_NAME}' created" \
  || log_warn "Project '${DEPLOYMENTS_REPO_NAME}' may already exist"

echo ""
log_header "Projects Ready"
```

**Step 2: Verify syntax**

Run: `bash -n scripts/03-pipelines/create-gitlab-projects.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 3: Update configure-merge-requirements.sh**

Replace the entire file with:

```bash
#!/bin/bash
# Configure GitLab merge requirements for k8s-deployments
# Sets up project settings for merge request workflow
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)

# Get project ID for k8s-deployments
PROJECT_PATH="${DEPLOYMENTS_REPO_PATH//\//%2F}"

log_header "Configuring Merge Requirements"
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Project: ${DEPLOYMENTS_REPO_PATH}"
echo ""

# Get project ID
log_step "Fetching project ID..."
PROJECT_ID=$(curl -sf "${GITLAB_URL_EXTERNAL}/api/v4/projects/${PROJECT_PATH}" \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
log_pass "Project ID: $PROJECT_ID"

# Configure project settings
log_step "Updating project settings..."
HTTP_STATUS=$(curl -sf -X PUT "${GITLAB_URL_EXTERNAL}/api/v4/projects/${PROJECT_ID}" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  -w "%{http_code}" \
  -o /tmp/gitlab-project-$$.json \
  -d '{
    "only_allow_merge_if_pipeline_succeeds": false,
    "only_allow_merge_if_all_discussions_are_resolved": false,
    "merge_method": "merge",
    "remove_source_branch_after_merge": true
  }')

if [[ "$HTTP_STATUS" == "200" ]]; then
    log_pass "Project settings updated"
else
    log_warn "Could not update project settings (HTTP $HTTP_STATUS)"
    cat /tmp/gitlab-project-$$.json >&2
fi
rm -f /tmp/gitlab-project-$$.json

echo ""
log_header "Configuration Complete"
echo ""
echo "How it works:"
echo "  1. Jenkins webhook triggers on MR creation/update"
echo "  2. Jenkins runs validation pipeline"
echo "  3. Jenkins reports status back to GitLab commit"
echo "  4. GitLab shows status check in MR"
echo ""
echo "Note: GitLab CE doesn't enforce external status checks"
echo "      (requires Premium). Status shown but not enforced."
```

**Step 4: Verify syntax**

Run: `bash -n scripts/03-pipelines/configure-merge-requirements.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 5: Update configure-gitlab-connection.sh**

Replace the entire file with:

```bash
#!/bin/bash
# Configure GitLab connection in Jenkins
# Documents the manual steps required for GitLab plugin setup
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)
JENKINS_CREDS=$(require_jenkins_credentials)
JENKINS_USER="${JENKINS_CREDS%%:*}"
JENKINS_PASS="${JENKINS_CREDS#*:}"

CONNECTION_NAME="gitlab-local"

log_header "GitLab Connection Setup for Jenkins"
log_info "Jenkins: ${JENKINS_URL_EXTERNAL}"
log_info "GitLab: ${GITLAB_URL_EXTERNAL}"
log_info "Connection: $CONNECTION_NAME"
echo ""

COOKIE_JAR="/tmp/jenkins-cookies-$$.txt"
CRUMB_FILE="/tmp/jenkins-crumb-$$.json"
trap 'rm -f "$COOKIE_JAR" "$CRUMB_FILE"' EXIT

# Get CSRF crumb
log_step "Getting CSRF crumb..."
if curl -sf -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    "${JENKINS_URL_EXTERNAL}/crumbIssuer/api/json" \
    -u "${JENKINS_USER}:${JENKINS_PASS}" \
    > "$CRUMB_FILE"; then
    log_pass "CSRF crumb obtained"
else
    log_warn "Could not get CSRF crumb (Jenkins may have CSRF disabled)"
fi

echo ""
log_header "Manual Configuration Required"
echo ""
echo "The GitLab plugin requires manual configuration in Jenkins UI:"
echo ""
echo "Step 1: Add GitLab API Token Credential"
echo "  URL: ${JENKINS_URL_EXTERNAL}/manage/credentials/store/system/domain/_/"
echo "  1. Click 'Add Credentials'"
echo "  2. Kind: GitLab API token"
echo "  3. API token: (use token from K8s secret or GITLAB_TOKEN env)"
echo "  4. ID: gitlab-api-token"
echo "  5. Description: GitLab API Token for status reporting"
echo "  6. Click 'Create'"
echo ""
echo "Step 2: Configure GitLab Connection"
echo "  URL: ${JENKINS_URL_EXTERNAL}/manage/configure"
echo "  1. Scroll to 'GitLab' section"
echo "  2. Click 'Add GitLab Server'"
echo "  3. Connection name: ${CONNECTION_NAME}"
echo "  4. GitLab host URL: ${GITLAB_URL_EXTERNAL}"
echo "  5. Credentials: Select 'gitlab-api-token'"
echo "  6. Click 'Test Connection' - should show 'Success'"
echo "  7. Click 'Save'"
echo ""
log_header "Setup Instructions Complete"
```

**Step 6: Verify syntax**

Run: `bash -n scripts/02-configure/configure-gitlab-connection.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 7: Commit all three updated scripts**

```bash
git add scripts/03-pipelines/create-gitlab-projects.sh \
        scripts/03-pipelines/configure-merge-requirements.sh \
        scripts/02-configure/configure-gitlab-connection.sh
git commit -m "refactor: remove hardcoded tokens, use lib/credentials.sh

All three scripts now:
- Source shared libraries (logging, infra, credentials)
- Use require_gitlab_token() for fail-fast credential access
- No hardcoded default tokens
- Consistent logging patterns

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 5: Update sync-k8s-deployments.sh

**Files:**
- Modify: `scripts/04-operations/sync-k8s-deployments.sh`

**Step 1: Replace the entire file**

```bash
#!/bin/bash
# Sync k8s-deployments to GitLab
# Pushes dev, stage, and prod branches to the p2c/k8s-deployments GitLab repo
set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials (fail-fast if not available)
GITLAB_TOKEN=$(require_gitlab_token)

K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

log_header "Syncing k8s-deployments to GitLab"
log_info "GitLab: ${GITLAB_HOST_EXTERNAL}"
log_info "Group: ${GITLAB_GROUP}"
echo ""

cd "$K8S_DEPLOYMENTS_DIR"

# Configure remote with token
git remote set-url origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST_EXTERNAL}/${GITLAB_GROUP}/k8s-deployments.git" 2>/dev/null || \
    git remote add origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST_EXTERNAL}/${GITLAB_GROUP}/k8s-deployments.git"

# Branches to sync
BRANCHES="${1:-dev stage prod}"

for branch in $BRANCHES; do
    log_step "Pushing ${branch}..."
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        GIT_SSL_NO_VERIFY=true git push origin "$branch" --force
        log_pass "${branch} pushed"
    else
        log_warn "Branch ${branch} not found locally, skipping"
    fi
done

echo ""
log_header "Sync Complete"
```

**Step 2: Verify syntax**

Run: `bash -n scripts/04-operations/sync-k8s-deployments.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add scripts/04-operations/sync-k8s-deployments.sh
git commit -m "refactor: sync-k8s-deployments uses shared libs, removes local.env

- Sources logging.sh, infra.sh, credentials.sh
- Removes get_gitlab_token() function (now in credentials.sh)
- Removes local.env fallback pattern
- Fail-fast if credentials not available

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 6: Remove local.env pattern

**Files:**
- Delete: `config/local.env`
- Delete: `config/local.env.template`
- Modify: `.gitignore` (remove local.env entry)

**Step 1: Delete the files**

Run: `rm config/local.env config/local.env.template`

**Step 2: Update .gitignore**

Remove lines 54-55 (`config/local.env`). The file should end with:

```
# Git worktrees
.worktrees/

# Pipeline validation overrides (may contain credentials)
config/validate-pipeline.env
```

**Step 3: Verify .gitignore is correct**

Run: `tail -5 .gitignore`
Expected: Shows worktrees and validate-pipeline.env entries, no local.env

**Step 4: Commit**

```bash
git rm config/local.env config/local.env.template
git add .gitignore
git commit -m "chore: remove local.env pattern

Credentials now come exclusively from:
1. Environment variables (GITLAB_TOKEN, JENKINS_USER, etc.)
2. Kubernetes secrets

The local.env pattern created redundancy and potential for
stale credentials. Scripts now fail-fast if credentials
are not available from the approved sources.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 7: Update remaining scripts using lib/config.sh

Several scripts still reference `lib/config.sh`. Update them to use the new structure.

**Files:**
- Modify: `scripts/02-configure/configure-gitlab.sh`
- Modify: `scripts/02-configure/configure-jenkins.sh`
- Modify: `scripts/03-pipelines/setup-gitlab-repos.sh`
- Modify: `scripts/03-pipelines/setup-manifest-generator-job.sh`
- Modify: `scripts/03-pipelines/setup-k8s-deployments-validation-job.sh`
- Modify: `scripts/04-operations/create-gitlab-mr.sh`

**Step 1: For each script, replace the config.sh source line**

Find lines like:
```bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
```

Replace with:
```bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/infra.sh"
```

Or if the script needs credentials, add both:
```bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/infra.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/credentials.sh"
```

**Step 2: For scripts with hardcoded credentials**

If any script has patterns like:
```bash
GITLAB_TOKEN="${GITLAB_TOKEN:-glpat-...}"
```

Replace with:
```bash
GITLAB_TOKEN=$(require_gitlab_token)
```

**Step 3: Verify all scripts have valid syntax**

Run: `for f in scripts/**/*.sh; do bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done`
Expected: All scripts show `OK`

**Step 4: Commit**

```bash
git add scripts/
git commit -m "refactor: migrate all scripts from config.sh to infra.sh

Updates remaining scripts to use the new lib/ structure:
- lib/infra.sh for infrastructure configuration
- lib/credentials.sh for fail-fast credential access

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 8: Create verify-credentials.sh (optional enhancement)

**Files:**
- Create: `scripts/test/verify-credentials.sh`

**Step 1: Create the verification script**

```bash
#!/bin/bash
# Verify credentials are valid and can access their respective APIs
# Use this to detect credential drift or expiration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/logging.sh"
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

log_header "Credential Verification"
echo ""

FAILED=0

# Test GitLab token
log_step "Testing GitLab token..."
GITLAB_TOKEN=$(require_gitlab_token)
GITLAB_USER=$(curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/user" 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('username', ''))" 2>/dev/null) || true

if [[ -n "$GITLAB_USER" ]]; then
    log_pass "GitLab: authenticated as '$GITLAB_USER'"
else
    log_fail "GitLab: token invalid or API unreachable"
    FAILED=1
fi

# Test Jenkins credentials
log_step "Testing Jenkins credentials..."
JENKINS_CREDS=$(require_jenkins_credentials)
JENKINS_RESPONSE=$(curl -sf -u "$JENKINS_CREDS" \
    "${JENKINS_URL_EXTERNAL}/api/json" 2>/dev/null) || true

if [[ -n "$JENKINS_RESPONSE" ]]; then
    log_pass "Jenkins: authentication successful"
else
    log_fail "Jenkins: credentials invalid or API unreachable"
    FAILED=1
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
    log_header "All Credentials Valid"
    exit 0
else
    log_header "Credential Issues Detected"
    exit 1
fi
```

**Step 2: Verify syntax**

Run: `bash -n scripts/test/verify-credentials.sh && echo "Syntax OK"`
Expected: `Syntax OK`

**Step 3: Commit**

```bash
git add scripts/test/verify-credentials.sh
git commit -m "feat: add credential verification script

Tests that GitLab and Jenkins credentials are valid by
making API calls. Useful for detecting credential drift
or expiration before running other scripts.

Usage: ./scripts/test/verify-credentials.sh

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 9: Final verification

**Step 1: Run shellcheck on all library files**

Run: `shellcheck scripts/lib/*.sh`
Expected: No errors (warnings about sourced files are OK)

**Step 2: Verify no references to old patterns remain**

Run: `grep -r "config\.sh\|local\.env\|:-glpat" scripts/ --include="*.sh" | grep -v "\.git"`
Expected: No matches

**Step 3: Run credential verification (if cluster is accessible)**

Run: `./scripts/test/verify-credentials.sh`
Expected: Both GitLab and Jenkins credentials verified

**Step 4: Create summary commit if needed**

If any fixups were needed, commit them:

```bash
git add -A
git commit -m "chore: lib refactoring cleanup

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Summary

| Before | After |
|--------|-------|
| `lib/config.sh` → broken (referenced non-existent gitlab.env) | `lib/infra.sh` → sources config/infra.env |
| Hardcoded tokens in 3 scripts | `lib/credentials.sh` with fail-fast helpers |
| Duplicated logging in 15+ scripts | `lib/logging.sh` shared library |
| `local.env` pattern | Removed - K8s secrets or env vars only |
| Inconsistent credential handling | Consistent `require_*()` pattern |
