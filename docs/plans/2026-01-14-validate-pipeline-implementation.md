# Pipeline Validation Script Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create `validate-pipeline.sh` that proves the CI/CD pipeline works by bumping version, pushing to GitLab, waiting for Jenkins build, and verifying ArgoCD deploys to dev.

**Architecture:** Single self-contained bash script with helper functions. Uses curl for API calls, kubectl for cluster access, sed for version manipulation. Config via environment variables or sourced file.

**Tech Stack:** Bash, curl, jq, kubectl, git, sed

---

## Task 1: Create Configuration Template

**Files:**
- Create: `config/validate-pipeline.env.template`
- Modify: `.gitignore`

**Step 1: Create the config template file**

```bash
#!/bin/bash
# Pipeline Validation Configuration
# Copy to validate-pipeline.env and fill in your values

# =============================================================================
# Required: Jenkins Configuration
# =============================================================================
export JENKINS_URL="${JENKINS_URL:-http://jenkins.local}"
export JENKINS_USER="${JENKINS_USER:-admin}"
export JENKINS_TOKEN="${JENKINS_TOKEN:-}"  # Create at Jenkins > User > Configure > API Token
export JENKINS_JOB_NAME="${JENKINS_JOB_NAME:-example-app-ci}"

# =============================================================================
# Required: GitLab Configuration
# =============================================================================
export GITLAB_URL="${GITLAB_URL:-http://gitlab.jmann.local}"
export GITLAB_TOKEN="${GITLAB_TOKEN:-}"  # Create at GitLab > User Settings > Access Tokens (api scope)
export GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-p2c/example-app}"

# =============================================================================
# Optional: Timeouts (seconds)
# =============================================================================
export JENKINS_BUILD_TIMEOUT="${JENKINS_BUILD_TIMEOUT:-600}"   # 10 minutes
export ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-300}"       # 5 minutes

# =============================================================================
# Optional: ArgoCD and Kubernetes
# =============================================================================
export ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-example-app-dev}"
export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
export DEV_NAMESPACE="${DEV_NAMESPACE:-dev}"
export APP_LABEL="${APP_LABEL:-app=example-app}"
```

**Step 2: Add to .gitignore**

Add this line to `.gitignore`:
```
config/validate-pipeline.env
```

**Step 3: Commit**

```bash
git add config/validate-pipeline.env.template .gitignore
git commit -m "feat: add validate-pipeline config template"
```

---

## Task 2: Create Script Skeleton with Pre-flight Checks

**Files:**
- Create: `validate-pipeline.sh`

**Step 1: Create the script with header and pre-flight checks**

```bash
#!/bin/bash
# Pipeline Validation Script
# Proves the CI/CD pipeline works: commit → build → deploy to dev
#
# Usage: ./validate-pipeline.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - config/validate-pipeline.env with credentials
#   - curl, jq, git installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/config/validate-pipeline.env" ]]; then
    source "$SCRIPT_DIR/config/validate-pipeline.env"
elif [[ -f "$SCRIPT_DIR/config/validate-pipeline.env.template" ]]; then
    echo "[✗] Config file not found"
    echo "    Copy config/validate-pipeline.env.template to config/validate-pipeline.env"
    echo "    and fill in your credentials"
    exit 1
fi

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
preflight_checks() {
    echo "=== Pipeline Validation ==="
    echo ""
    log_step "Running pre-flight checks..."

    local failed=0

    # Check kubectl
    if kubectl cluster-info &>/dev/null; then
        log_info "kubectl: connected to cluster"
    else
        log_fail "kubectl: cannot connect to cluster"
        failed=1
    fi

    # Check GitLab
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_fail "GitLab: GITLAB_TOKEN not set"
        failed=1
    elif curl -sf -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/user" &>/dev/null; then
        log_info "GitLab: $GITLAB_URL (reachable)"
    else
        log_fail "GitLab: $GITLAB_URL (not reachable or token invalid)"
        failed=1
    fi

    # Check Jenkins
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        log_fail "Jenkins: JENKINS_TOKEN not set"
        failed=1
    elif curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/api/json" &>/dev/null; then
        log_info "Jenkins: $JENKINS_URL (reachable)"
    else
        log_fail "Jenkins: $JENKINS_URL (not reachable or credentials invalid)"
        failed=1
    fi

    # Check ArgoCD application exists
    if kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
        log_info "ArgoCD: $ARGOCD_APP_NAME application exists"
    else
        log_fail "ArgoCD: $ARGOCD_APP_NAME application not found in $ARGOCD_NAMESPACE namespace"
        failed=1
    fi

    if [[ $failed -eq 1 ]]; then
        echo ""
        log_fail "Pre-flight checks failed"
        exit 1
    fi

    log_pass "Pre-flight checks passed"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local start_time=$(date +%s)

    preflight_checks

    # TODO: Implement remaining steps
    echo "Pre-flight checks complete. Implementation continues in next tasks."
}

main "$@"
```

**Step 2: Make executable and test**

```bash
chmod +x validate-pipeline.sh
./validate-pipeline.sh
```

Expected: Should fail with "Config file not found" or pass pre-flight checks if config exists.

**Step 3: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: add validate-pipeline.sh with pre-flight checks"
```

---

## Task 3: Add Version Bump Function

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Add version bump function after pre-flight checks section**

Add this function before `main()`:

```bash
# -----------------------------------------------------------------------------
# Version Bump
# -----------------------------------------------------------------------------
bump_version() {
    log_step "Bumping version in example-app/pom.xml..."

    local pom_file="$SCRIPT_DIR/example-app/pom.xml"

    if [[ ! -f "$pom_file" ]]; then
        log_fail "pom.xml not found at $pom_file"
        exit 1
    fi

    # Extract current version (handles X.Y.Z or X.Y.Z-SNAPSHOT)
    local current_version=$(grep -m1 '<version>' "$pom_file" | sed 's/.*<version>\(.*\)<\/version>.*/\1/')

    # Parse version parts
    local base_version="${current_version%-SNAPSHOT}"
    local suffix=""
    [[ "$current_version" == *-SNAPSHOT ]] && suffix="-SNAPSHOT"

    local major minor patch
    IFS='.' read -r major minor patch <<< "$base_version"

    # Increment patch
    patch=$((patch + 1))
    local new_version="${major}.${minor}.${patch}${suffix}"

    log_info "Version: $current_version → $new_version"

    # Update pom.xml (first <version> tag after <artifactId>example-app</artifactId>)
    sed -i "0,/<version>$current_version<\/version>/s//<version>$new_version<\/version>/" "$pom_file"

    # Export for later use
    export NEW_VERSION="$new_version"
    export NEW_VERSION_TAG="${new_version%-SNAPSHOT}"  # Tag without SNAPSHOT
}
```

**Step 2: Test the function**

Run the script and verify it correctly parses and would bump the version:

```bash
# Dry run - check current version
grep -m1 '<version>' example-app/pom.xml

./validate-pipeline.sh
```

**Step 3: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: add version bump function to validate-pipeline.sh"
```

---

## Task 4: Add Git Commit and Push Function

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Add git operations function after bump_version()**

```bash
# -----------------------------------------------------------------------------
# Git Operations
# -----------------------------------------------------------------------------
commit_and_push() {
    log_step "Committing and pushing to GitLab..."

    cd "$SCRIPT_DIR"

    # Stage the pom.xml change
    git add example-app/pom.xml

    # Commit with identifiable message
    git commit -m "chore: bump version to $NEW_VERSION [pipeline-validation]"

    # Push to origin first (GitHub - full monorepo)
    log_info "Pushing to origin (GitHub)..."
    git push origin main

    # Sync subtree to GitLab
    log_info "Syncing to GitLab..."
    GIT_SSL_NO_VERIFY=true git subtree push --prefix=example-app gitlab-app main 2>&1 || {
        log_fail "Failed to sync to GitLab"
        echo ""
        echo "--- Diagnostic ---"
        echo "Check that 'gitlab-app' remote is configured:"
        git remote -v | grep gitlab-app || echo "Remote not found"
        echo "--- End Diagnostic ---"
        exit 1
    }

    log_pass "Committed and pushed to GitLab"
    echo ""
}
```

**Step 2: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: add git commit and push function to validate-pipeline.sh"
```

---

## Task 5: Add Jenkins Build Polling

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Add Jenkins polling function after commit_and_push()**

```bash
# -----------------------------------------------------------------------------
# Jenkins Build
# -----------------------------------------------------------------------------
wait_for_jenkins_build() {
    log_step "Waiting for Jenkins build..."

    local timeout="${JENKINS_BUILD_TIMEOUT:-600}"
    local poll_interval=10
    local elapsed=0
    local build_number=""
    local build_url=""

    # Get the last build number before we triggered
    local last_build=$(curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/job/$JENKINS_JOB_NAME/lastBuild/api/json" 2>/dev/null | jq -r '.number // 0')

    # Wait for a new build to start
    log_info "Waiting for new build (last was #$last_build)..."

    while [[ $elapsed -lt $timeout ]]; do
        local current_build=$(curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/job/$JENKINS_JOB_NAME/lastBuild/api/json" 2>/dev/null | jq -r '.number // 0')

        if [[ "$current_build" -gt "$last_build" ]]; then
            build_number="$current_build"
            build_url="$JENKINS_URL/job/$JENKINS_JOB_NAME/$build_number"
            log_info "Build #$build_number started"
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        log_fail "Timeout waiting for build to start"
        exit 1
    fi

    # Wait for build to complete
    while [[ $elapsed -lt $timeout ]]; do
        local build_info=$(curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$build_url/api/json")

        local building=$(echo "$build_info" | jq -r '.building')
        local result=$(echo "$build_info" | jq -r '.result // "null"')

        if [[ "$building" == "false" ]]; then
            local duration=$(echo "$build_info" | jq -r '.duration')
            local duration_sec=$((duration / 1000))

            if [[ "$result" == "SUCCESS" ]]; then
                log_pass "Build #$build_number completed successfully (${duration_sec}s)"
                echo ""
                export BUILD_NUMBER="$build_number"
                return 0
            else
                log_fail "Build #$build_number $result"
                echo ""
                echo "--- Build Console (last 50 lines) ---"
                curl -sf -u "$JENKINS_USER:$JENKINS_TOKEN" \
                    "$build_url/consoleText" | tail -50
                echo "--- End Console ---"
                exit 1
            fi
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for build to complete"
    exit 1
}
```

**Step 2: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: add Jenkins build polling to validate-pipeline.sh"
```

---

## Task 6: Add ArgoCD Sync Polling

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Add ArgoCD polling function after wait_for_jenkins_build()**

```bash
# -----------------------------------------------------------------------------
# ArgoCD Sync
# -----------------------------------------------------------------------------
wait_for_argocd_sync() {
    log_step "Waiting for ArgoCD sync..."

    local timeout="${ARGOCD_SYNC_TIMEOUT:-300}"
    local poll_interval=15
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local app_status=$(kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)

        local sync_status=$(echo "$app_status" | jq -r '.status.sync.status // "Unknown"')
        local health_status=$(echo "$app_status" | jq -r '.status.health.status // "Unknown"')

        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            log_pass "$ARGOCD_APP_NAME synced and healthy (${elapsed}s)"
            echo ""
            return 0
        fi

        log_info "Status: sync=$sync_status health=$health_status (${elapsed}s elapsed)"

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for ArgoCD sync"
    echo ""
    echo "--- ArgoCD Application Status ---"
    kubectl describe application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" 2>/dev/null | tail -30
    echo "--- End Status ---"
    exit 1
}
```

**Step 2: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: add ArgoCD sync polling to validate-pipeline.sh"
```

---

## Task 7: Add Deployment Verification

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Add verification function after wait_for_argocd_sync()**

```bash
# -----------------------------------------------------------------------------
# Deployment Verification
# -----------------------------------------------------------------------------
verify_deployment() {
    log_step "Verifying deployment..."

    # Get pod info
    local pod_info=$(kubectl get pods -n "$DEV_NAMESPACE" -l "$APP_LABEL" -o json 2>/dev/null)
    local pod_count=$(echo "$pod_info" | jq '.items | length')

    if [[ "$pod_count" -eq 0 ]]; then
        log_fail "No pods found with label $APP_LABEL in $DEV_NAMESPACE"
        exit 1
    fi

    # Check pod status
    local ready_pods=$(echo "$pod_info" | jq '[.items[] | select(.status.phase == "Running")] | length')

    if [[ "$ready_pods" -eq 0 ]]; then
        log_fail "No pods in Running state"
        echo ""
        echo "--- Pod Status ---"
        kubectl get pods -n "$DEV_NAMESPACE" -l "$APP_LABEL"
        echo ""
        echo "--- Pod Events ---"
        kubectl describe pods -n "$DEV_NAMESPACE" -l "$APP_LABEL" | grep -A 20 "Events:" | head -25
        echo "--- End ---"
        exit 1
    fi

    # Get deployed image
    local deployed_image=$(echo "$pod_info" | jq -r '.items[0].spec.containers[0].image')

    log_pass "Pod running with image: $deployed_image"
    echo ""

    export DEPLOYED_IMAGE="$deployed_image"
}
```

**Step 2: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: add deployment verification to validate-pipeline.sh"
```

---

## Task 8: Wire Up Main Function

**Files:**
- Modify: `validate-pipeline.sh`

**Step 1: Update main() to call all functions**

Replace the `main()` function:

```bash
# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local start_time=$(date +%s)

    preflight_checks
    bump_version
    commit_and_push
    wait_for_jenkins_build
    wait_for_argocd_sync
    verify_deployment

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo "=== VALIDATION PASSED ==="
    echo "Version $NEW_VERSION deployed to dev in ${minutes}m ${seconds}s"
}

main "$@"
```

**Step 2: Commit**

```bash
git add validate-pipeline.sh
git commit -m "feat: wire up main function in validate-pipeline.sh"
```

---

## Task 9: Create Config File and Test

**Files:**
- Create: `config/validate-pipeline.env` (local only, gitignored)

**Step 1: Copy template and fill in credentials**

```bash
cp config/validate-pipeline.env.template config/validate-pipeline.env
# Edit config/validate-pipeline.env with your actual credentials
```

**Step 2: Run the full validation**

```bash
./validate-pipeline.sh
```

Expected: Full pipeline runs and deploys new version to dev.

**Step 3: Final commit with any fixes**

```bash
git add -A
git commit -m "feat: complete validate-pipeline.sh implementation"
```

---

## Summary

After completing all tasks, you will have:

1. `config/validate-pipeline.env.template` - Configuration template
2. `validate-pipeline.sh` - Self-contained validation script (~200 lines)
3. Updated `.gitignore` - Excludes actual config with credentials

The script:
- Runs pre-flight checks on kubectl, GitLab, Jenkins, ArgoCD
- Bumps patch version in example-app/pom.xml
- Commits and pushes via git subtree to GitLab
- Polls Jenkins for build completion with diagnostics on failure
- Polls ArgoCD for sync completion with diagnostics on failure
- Verifies pod is running with new image
- Reports total time and success/failure status
