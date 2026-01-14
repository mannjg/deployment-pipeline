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
