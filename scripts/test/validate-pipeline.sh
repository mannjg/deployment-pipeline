#!/bin/bash
# Pipeline Validation Script
# Proves the CI/CD pipeline works: commit → build → deploy to dev → stage → prod
#
# Usage: ./validate-pipeline.sh
#
# Prerequisites:
#   - kubectl configured for target cluster
#   - curl, jq, git installed
#   - config/infra.env with infrastructure URLs and secret references
#
# Credentials are loaded from K8s secrets as configured in infra.env.
#
# Note: With the simplified pipeline, promotion MRs are auto-created by
# k8s-deployments CI after successful deployment to dev/stage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Load infrastructure config (single source of truth)
if [[ -f "$REPO_ROOT/config/infra.env" ]]; then
    source "$REPO_ROOT/config/infra.env"
else
    echo "[x] Infrastructure config not found: config/infra.env"
    exit 1
fi

# Load demo helpers for pipeline state checks
source "$REPO_ROOT/scripts/demo/lib/demo-helpers.sh"

# Fetch credentials from K8s secrets
# Uses secret names/keys from infra.env
load_credentials_from_secrets() {
    # Jenkins credentials
    if [[ -z "${JENKINS_USER:-}" ]]; then
        JENKINS_USER=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_USER_KEY}}" 2>/dev/null | base64 -d) || true
    fi
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        JENKINS_TOKEN=$(kubectl get secret "$JENKINS_ADMIN_SECRET" -n "$JENKINS_NAMESPACE" \
            -o jsonpath="{.data.${JENKINS_ADMIN_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi

    # GitLab credentials
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        GITLAB_TOKEN=$(kubectl get secret "$GITLAB_API_TOKEN_SECRET" -n "$GITLAB_NAMESPACE" \
            -o jsonpath="{.data.${GITLAB_API_TOKEN_KEY}}" 2>/dev/null | base64 -d) || true
    fi
}

# Map infra.env variables to script variables (no defaults - must be set)
JENKINS_URL="${JENKINS_URL_EXTERNAL:?JENKINS_URL_EXTERNAL not set in infra.env}"
JENKINS_JOB_NAME="${JENKINS_APP_JOB_PATH:?JENKINS_APP_JOB_PATH not set in infra.env}"
GITLAB_URL="${GITLAB_URL_EXTERNAL:?GITLAB_URL_EXTERNAL not set in infra.env}"
GITLAB_PROJECT_PATH="${APP_REPO_PATH:?APP_REPO_PATH not set in infra.env}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?ARGOCD_NAMESPACE not set in infra.env}"
DEV_NAMESPACE="${DEV_NAMESPACE:?DEV_NAMESPACE not set in infra.env}"

# Derived values (from required infra.env variables)
APP_REPO_NAME="${APP_REPO_NAME:?APP_REPO_NAME not set in infra.env}"
ARGOCD_APP_NAME="${APP_REPO_NAME}-dev"
APP_LABEL="app=${APP_REPO_NAME}"

# Timeouts (sensible defaults)
# BUILD_START_TIMEOUT: Time to wait for Jenkins to detect webhook and start build
# BUILD_TIMEOUT: Time for the build itself to complete (after it starts)
# Timeouts are intentionally short - if webhooks work, builds start within seconds
JENKINS_BUILD_START_TIMEOUT="${JENKINS_BUILD_START_TIMEOUT:-60}"
JENKINS_BUILD_TIMEOUT="${JENKINS_BUILD_TIMEOUT:-180}"
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-60}"
PROMOTION_MR_TIMEOUT="${PROMOTION_MR_TIMEOUT:-60}"
K8S_DEPLOYMENTS_BUILD_START_TIMEOUT="${K8S_DEPLOYMENTS_BUILD_START_TIMEOUT:-60}"
K8S_DEPLOYMENTS_BUILD_TIMEOUT="${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-60}"

# -----------------------------------------------------------------------------
# Output Helpers
# -----------------------------------------------------------------------------
log_step()  { echo "[->] $*"; }
log_pass()  { echo "[ok] $*"; }
log_fail()  { echo "[x] $*"; }
log_info()  { echo "    $*"; }

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
preflight_checks() {
    echo "=== Pipeline Validation ==="
    echo ""
    log_step "Running pre-flight checks..."

    local failed=0

    # Validate required configuration
    local missing_config=()
    [[ -z "$JENKINS_URL" ]] && missing_config+=("JENKINS_URL")
    [[ -z "$JENKINS_JOB_NAME" ]] && missing_config+=("JENKINS_JOB_NAME")
    [[ -z "$GITLAB_URL" ]] && missing_config+=("GITLAB_URL")
    [[ -z "$GITLAB_PROJECT_PATH" ]] && missing_config+=("GITLAB_PROJECT_PATH")
    [[ -z "$ARGOCD_APP_NAME" ]] && missing_config+=("ARGOCD_APP_NAME")
    [[ -z "$ARGOCD_NAMESPACE" ]] && missing_config+=("ARGOCD_NAMESPACE")
    [[ -z "$DEV_NAMESPACE" ]] && missing_config+=("DEV_NAMESPACE")
    [[ -z "$APP_LABEL" ]] && missing_config+=("APP_LABEL")

    if [[ ${#missing_config[@]} -gt 0 ]]; then
        log_fail "Missing required configuration:"
        for var in "${missing_config[@]}"; do
            log_info "  - $var"
        done
        log_info ""
        log_info "Create config/validate-pipeline.env from the template:"
        log_info "  cp config/validate-pipeline.env.template config/validate-pipeline.env"
        return 1
    fi

    # Check kubectl
    if kubectl cluster-info &>/dev/null; then
        log_info "kubectl: connected to cluster"
    else
        log_fail "kubectl: cannot connect to cluster"
        failed=1
        return 1  # Can't proceed without kubectl
    fi

    # Load credentials from K8s secrets
    log_info "Loading credentials from K8s secrets..."
    load_credentials_from_secrets

    # Verify GitLab credentials work
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_fail "GitLab: GITLAB_TOKEN not set (check gitlab-api-token secret in gitlab namespace)"
        failed=1
    else
        local gitlab_user
        gitlab_user=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/user" 2>/dev/null | jq -r '.username // empty')
        if [[ -n "$gitlab_user" ]]; then
            log_info "GitLab: authenticated as '$gitlab_user' at $GITLAB_URL"
        else
            log_fail "GitLab: $GITLAB_URL (token invalid or API unreachable)"
            failed=1
        fi
    fi

    # Verify Jenkins credentials work
    if [[ -z "${JENKINS_TOKEN:-}" ]]; then
        log_fail "Jenkins: JENKINS_TOKEN not set (check jenkins-admin-credentials secret in jenkins namespace)"
        failed=1
    else
        local jenkins_mode
        jenkins_mode=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" "$JENKINS_URL/api/json" 2>/dev/null | jq -r '.mode // empty')
        if [[ -n "$jenkins_mode" ]]; then
            log_info "Jenkins: authenticated as '$JENKINS_USER' at $JENKINS_URL (mode: $jenkins_mode)"
        else
            log_fail "Jenkins: $JENKINS_URL (credentials invalid or API unreachable)"
            failed=1
        fi
    fi

    # Check ArgoCD applications exist (dev, stage, prod)
    for env in dev stage prod; do
        local app="${APP_REPO_NAME}-${env}"
        if kubectl get application "$app" -n "$ARGOCD_NAMESPACE" &>/dev/null; then
            log_info "ArgoCD: $app application exists"
        else
            log_fail "ArgoCD: $app application not found in $ARGOCD_NAMESPACE namespace"
            failed=1
        fi
    done

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

    local pom_file="$REPO_ROOT/example-app/pom.xml"

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

    log_info "Version: $current_version -> $new_version"

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

    cd "$REPO_ROOT"

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

    local start_timeout="${JENKINS_BUILD_START_TIMEOUT:-300}"
    local build_timeout="${JENKINS_BUILD_TIMEOUT:-600}"
    local poll_interval=10
    local elapsed=0
    local build_number=""
    local build_url=""

    # Get the last build number before we triggered
    local last_build=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/job/$JENKINS_JOB_NAME/lastBuild/api/json" 2>/dev/null | jq -r '.number // 0')

    # Wait for a new build to start (separate timeout for webhook/scan delay)
    log_info "Waiting for new build (last was #$last_build, timeout ${start_timeout}s)..."

    while [[ $elapsed -lt $start_timeout ]]; do
        local current_build=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/job/$JENKINS_JOB_NAME/lastBuild/api/json" 2>/dev/null | jq -r '.number // 0')

        if [[ "$current_build" -gt "$last_build" ]]; then
            build_number="$current_build"
            build_url="$JENKINS_URL/job/$JENKINS_JOB_NAME/$build_number"
            log_info "Build #$build_number started (after ${elapsed}s)"
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        log_fail "Timeout waiting for build to start (${start_timeout}s)"
        log_info "This may indicate webhook issues or Jenkins not scanning the branch"
        log_info "Check: $JENKINS_URL/job/$JENKINS_JOB_NAME/"
        exit 1
    fi

    # Wait for build to complete (separate timeout, resets elapsed)
    elapsed=0
    log_info "Waiting for build to complete (timeout ${build_timeout}s)..."

    while [[ $elapsed -lt $build_timeout ]]; do
        local build_info=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
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
                curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
                    "$build_url/consoleText" | tail -50
                echo "--- End Console ---"
                exit 1
            fi
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for build to complete (${build_timeout}s)"
    exit 1
}

# -----------------------------------------------------------------------------
# Trigger MultiBranch Pipeline scan
# -----------------------------------------------------------------------------
# MultiBranch Pipelines only detect new branches on periodic scans (default 5min).
# This function triggers an immediate scan so new branches are discovered quickly.
# TODO: Replace with webhook-triggered Pipeline to eliminate this workaround.
trigger_multibranch_scan() {
    local job_name="${DEPLOYMENTS_REPO_NAME:-k8s-deployments}"
    log_info "Triggering MultiBranch scan for $job_name..."

    # Jenkins CSRF protection requires session cookie from crumb request
    local cookie_jar=$(mktemp)
    local crumb_file=$(mktemp)

    # Get CSRF crumb with session cookie
    curl -sk -c "$cookie_jar" -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/crumbIssuer/api/json" > "$crumb_file" 2>/dev/null || true

    local crumb_header=""
    if jq empty "$crumb_file" 2>/dev/null; then
        local crumb_field=$(jq -r '.crumbRequestField // empty' "$crumb_file")
        local crumb_value=$(jq -r '.crumb // empty' "$crumb_file")
        if [[ -n "$crumb_field" && -n "$crumb_value" ]]; then
            crumb_header="-H ${crumb_field}:${crumb_value}"
        fi
    fi

    # Trigger branch indexing with same session cookie
    local response
    response=$(curl -sk -w "%{http_code}" -o /dev/null -X POST \
        -b "$cookie_jar" \
        -u "$JENKINS_USER:$JENKINS_TOKEN" \
        $crumb_header \
        "$JENKINS_URL/job/${job_name}/build?delay=0sec" 2>/dev/null) || true

    rm -f "$cookie_jar" "$crumb_file"

    # 302 = redirect after success, 200/201 also success
    if [[ "$response" == "302" || "$response" == "201" || "$response" == "200" ]]; then
        log_info "Branch scan triggered successfully"
    else
        log_info "Branch scan trigger returned $response (may already be scanning)"
    fi

    # Give Jenkins a moment to start scanning
    sleep 3
}

# -----------------------------------------------------------------------------
# Wait for k8s-deployments CI
# -----------------------------------------------------------------------------
wait_for_k8s_deployments_ci() {
    local branch="$1"
    local baseline_build="${2:-}"  # Optional: baseline build number passed by caller

    log_step "Waiting for k8s-deployments CI to generate manifests..."

    # Trigger immediate branch scan (MultiBranch Pipelines are slow to detect new branches)
    trigger_multibranch_scan

    # k8s-deployments is a MultiBranch Pipeline - the job is named after the repo
    local job_name="${DEPLOYMENTS_REPO_NAME:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    local start_timeout="${K8S_DEPLOYMENTS_BUILD_START_TIMEOUT:-60}"
    local build_timeout="${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-60}"
    local poll_interval=10
    local elapsed=0
    local build_number=""
    local build_url=""

    # Give Jenkins a moment to process the scan and start the build
    sleep 2

    # Get the last build number to use as baseline
    # If caller provided a baseline, use that (helps with race conditions)
    local last_build=0
    local response
    if [[ -n "$baseline_build" ]]; then
        last_build="$baseline_build"
    else
        response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/${job_path}/lastBuild/api/json" 2>/dev/null) || true
        if echo "$response" | jq empty 2>/dev/null; then
            last_build=$(echo "$response" | jq -r '.number // 0')
        fi
    fi

    log_info "Waiting for new build on branch $branch (baseline #$last_build, timeout ${start_timeout}s)..."

    while [[ $elapsed -lt $start_timeout ]]; do
        local current_build=0
        local is_building="false"
        response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$JENKINS_URL/${job_path}/lastBuild/api/json" 2>/dev/null) || true
        if echo "$response" | jq empty 2>/dev/null; then
            current_build=$(echo "$response" | jq -r '.number // 0')
            is_building=$(echo "$response" | jq -r '.building // false')
        fi

        if [[ "$current_build" -gt "$last_build" ]]; then
            build_number="$current_build"
            build_url="$JENKINS_URL/${job_path}/$build_number"
            log_info "Build #$build_number detected (after ${elapsed}s, building=$is_building)"
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$build_number" ]]; then
        log_fail "Timeout waiting for k8s-deployments CI build to start (${start_timeout}s)"
        exit 1
    fi

    # Wait for build to complete (separate timeout, resets elapsed)
    elapsed=0
    log_info "Waiting for build to complete (timeout ${build_timeout}s)..."

    while [[ $elapsed -lt $build_timeout ]]; do
        local build_info=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "$build_url/api/json" 2>/dev/null)

        local building=$(echo "$build_info" | jq -r '.building')
        local result=$(echo "$build_info" | jq -r '.result // "null"')

        if [[ "$building" == "false" ]]; then
            local duration=$(echo "$build_info" | jq -r '.duration')
            local duration_sec=$((duration / 1000))

            if [[ "$result" == "SUCCESS" ]]; then
                log_pass "k8s-deployments CI build #$build_number completed (${duration_sec}s)"
                return 0
            else
                log_fail "k8s-deployments CI build #$build_number $result"
                echo ""
                echo "--- Build Console (last 50 lines) ---"
                curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
                    "$build_url/consoleText" | tail -50
                echo "--- End Console ---"
                exit 1
            fi
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for k8s-deployments CI build to complete (${build_timeout}s)"
    exit 1
}

# -----------------------------------------------------------------------------
# Merge Dev MR
# -----------------------------------------------------------------------------
merge_dev_mr() {
    log_step "Finding and merging dev MR..."

    local deployments_project="${DEPLOYMENTS_REPO_PATH:?DEPLOYMENTS_REPO_PATH not set}"
    local encoded_project=$(echo "$deployments_project" | sed 's/\//%2F/g')

    # Match MR by version - handles multiple open MRs correctly
    # Branch format: update-dev-{version}-{commit}
    local branch_prefix="update-dev-${NEW_VERSION}-"

    local timeout=60
    local poll_interval=5
    local elapsed=0
    local mr_iid=""
    local source_branch=""

    log_info "Looking for MR with branch: ${branch_prefix}*"

    while [[ $elapsed -lt $timeout ]]; do
        local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=dev" 2>/dev/null)

        # Find MR matching our specific version (ignores stale MRs)
        local match=$(echo "$mrs" | jq -r --arg prefix "$branch_prefix" \
            'first(.[] | select(.source_branch | startswith($prefix))) // empty')

        if [[ -n "$match" ]]; then
            mr_iid=$(echo "$match" | jq -r '.iid')
            source_branch=$(echo "$match" | jq -r '.source_branch')
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$mr_iid" ]]; then
        log_fail "No MR found for version $NEW_VERSION"
        log_info "Open MRs targeting dev:"
        curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=dev" | \
            jq -r '.[] | "  !\(.iid): \(.source_branch)"' 2>/dev/null || echo "  (none)"
        exit 1
    fi

    log_info "Found MR !$mr_iid (branch: $source_branch)"

    # Extract IMAGE_TAG from branch name (update-dev-{version}-{commit} -> {version}-{commit})
    export IMAGE_TAG="${source_branch#update-dev-}"

    # Wait for k8s-deployments CI to generate manifests before verifying
    # (example-app CI only updates L5/L6 CUE files, k8s-deployments CI generates manifests)
    wait_for_k8s_deployments_ci "$source_branch"

    # Verify the image in the MR is correct
    verify_mr_image "$encoded_project" "$source_branch"

    # Merge the MR
    log_info "Merging MR !$mr_iid..."
    local merge_result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid/merge" 2>/dev/null)

    local merge_state=$(echo "$merge_result" | jq -r '.state // .message // "unknown"')

    if [[ "$merge_state" == "merged" ]]; then
        log_pass "MR !$mr_iid merged successfully"
        echo ""
    else
        log_fail "Failed to merge MR: $merge_state"
        echo "$merge_result" | jq .
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Wait for Auto-Created Promotion MR
# -----------------------------------------------------------------------------
wait_for_promotion_mr() {
    local target_env="$1"
    local baseline_time="${2:-}"  # Optional: baseline timestamp from before MR creation
    local timeout="${PROMOTION_MR_TIMEOUT:-180}"

    log_step "Waiting for auto-created promotion MR to $target_env..."

    local deployments_project="${DEPLOYMENTS_REPO_PATH:?DEPLOYMENTS_REPO_PATH not set}"
    local encoded_project=$(echo "$deployments_project" | sed 's/\//%2F/g')

    # Promotion branches created by k8s-deployments CI: promote-{targetEnv}-{timestamp}
    local branch_prefix="promote-${target_env}-"

    # Use provided baseline or current time (ISO 8601)
    local start_time
    if [[ -n "$baseline_time" ]]; then
        start_time="$baseline_time"
    else
        start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    local poll_interval=10
    local elapsed=0
    local mr_iid=""

    log_info "Looking for MR with branch: ${branch_prefix}* created after $start_time (timeout ${timeout}s)"

    while [[ $elapsed -lt $timeout ]]; do
        # GitLab API: created_after filter for MRs created since we started waiting
        local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_env&created_after=$start_time" 2>/dev/null)

        # Find any MR with promotion branch pattern
        local match=$(echo "$mrs" | jq -r --arg prefix "$branch_prefix" \
            'first(.[] | select(.source_branch | startswith($prefix))) // empty')

        if [[ -n "$match" ]]; then
            mr_iid=$(echo "$match" | jq -r '.iid')
            local source_branch=$(echo "$match" | jq -r '.source_branch')
            log_info "Found promotion MR !$mr_iid (branch: $source_branch)"
            return 0
        fi

        log_info "Waiting for promotion MR... (${elapsed}s elapsed)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for promotion MR to $target_env (${timeout}s)"
    log_info "Open MRs targeting $target_env (all, including stale):"
    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_env" | \
        jq -r '.[] | "  !\(.iid): \(.source_branch) (created: \(.created_at))"' 2>/dev/null || echo "  (none)"
    exit 1
}

# -----------------------------------------------------------------------------
# Merge Environment MR
# -----------------------------------------------------------------------------
merge_env_mr() {
    local target_env="$1"

    log_step "Finding and merging $target_env MR..."

    local deployments_project="${DEPLOYMENTS_REPO_PATH:?DEPLOYMENTS_REPO_PATH not set}"
    local encoded_project=$(echo "$deployments_project" | sed 's/\//%2F/g')

    # Promotion branches created by k8s-deployments CI: promote-{targetEnv}-{timestamp}
    local branch_prefix="promote-${target_env}-"

    local timeout=60
    local poll_interval=5
    local elapsed=0
    local mr_iid=""
    local source_branch=""

    log_info "Looking for MR with branch: ${branch_prefix}*"

    while [[ $elapsed -lt $timeout ]]; do
        local mrs=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_env" 2>/dev/null)

        local match=$(echo "$mrs" | jq -r --arg prefix "$branch_prefix" \
            'first(.[] | select(.source_branch | startswith($prefix))) // empty')

        if [[ -n "$match" ]]; then
            mr_iid=$(echo "$match" | jq -r '.iid')
            source_branch=$(echo "$match" | jq -r '.source_branch')
            break
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    if [[ -z "$mr_iid" ]]; then
        log_fail "No MR found for $target_env promotion"
        log_info "Open MRs targeting $target_env:"
        curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
            "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests?state=opened&target_branch=$target_env" | \
            jq -r '.[] | "  !\(.iid): \(.source_branch)"' 2>/dev/null || echo "  (none)"
        exit 1
    fi

    log_info "Found MR !$mr_iid (branch: $source_branch)"

    log_info "Merging MR !$mr_iid..."
    local merge_result=$(curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/merge_requests/$mr_iid/merge" 2>/dev/null)

    local merge_state=$(echo "$merge_result" | jq -r '.state // .message // "unknown"')

    if [[ "$merge_state" == "merged" ]]; then
        log_pass "MR !$mr_iid merged successfully"
        echo ""
    else
        log_fail "Failed to merge MR: $merge_state"
        echo "$merge_result" | jq .
        exit 1
    fi
}

verify_mr_image() {
    local encoded_project="$1"
    local branch="$2"

    log_info "Verifying image in MR..."

    # Fetch the GENERATED MANIFEST (not env.cue) - this is what actually deploys
    # Using manifests avoids parsing CUE and handles only the target app's deployment
    local app_cue_name="${APP_CUE_NAME:?APP_CUE_NAME not set in infra.env}"
    local manifest_path="manifests%2F${app_cue_name}%2F${app_cue_name}.yaml"
    local manifest=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "$GITLAB_URL/api/v4/projects/$encoded_project/repository/files/$manifest_path/raw?ref=$branch" 2>/dev/null)

    if [[ -z "$manifest" ]] || [[ "$manifest" == *"error"* ]] || [[ "$manifest" == *"404"* ]]; then
        log_fail "Could not fetch manifest from branch $branch"
        exit 1
    fi

    # Extract image from Deployment resource only (ignores ConfigMap, Service, etc.)
    # Uses Python for proper multi-document YAML parsing
    local mr_image=$(echo "$manifest" | python3 -c "
import sys
import yaml

try:
    for doc in yaml.safe_load_all(sys.stdin):
        if doc and doc.get('kind') == 'Deployment':
            containers = doc.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
            if containers:
                print(containers[0].get('image', ''))
                break
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)

    if [[ -z "$mr_image" ]] || [[ "$mr_image" == "ERROR:"* ]]; then
        log_fail "Could not extract image from manifest: $mr_image"
        exit 1
    fi

    # Validate the image meets all requirements
    local expected_registry="${DOCKER_REGISTRY_EXTERNAL:?DOCKER_REGISTRY_EXTERNAL not set}"
    local expected_app="${APP_REPO_NAME}"

    # Check for placeholder/internal URLs (should have been replaced by Jenkins)
    if [[ "$mr_image" == *"NOT_SET"* ]] || [[ "$mr_image" == *"nexus.nexus.svc"* ]]; then
        log_fail "Image contains invalid/placeholder URL: $mr_image"
        exit 1
    fi

    # Check external registry
    if [[ "$mr_image" != "${expected_registry}/"* ]]; then
        log_fail "Image uses wrong registry"
        log_info "  Expected: ${expected_registry}/..."
        log_info "  Got:      $mr_image"
        exit 1
    fi

    # Check app name in path
    if [[ "$mr_image" != *"/${expected_app}:"* ]]; then
        log_fail "Image missing app name in path"
        log_info "  Expected: .../${expected_app}:..."
        log_info "  Got:      $mr_image"
        exit 1
    fi

    # Check version in tag (format: {version}-{commit})
    if [[ "$mr_image" != *":${NEW_VERSION}-"* ]]; then
        log_fail "Image has wrong version in tag"
        log_info "  Expected: ...:${NEW_VERSION}-..."
        log_info "  Got:      $mr_image"
        exit 1
    fi

    log_info "Image validated: $mr_image"
}

# -----------------------------------------------------------------------------
# ArgoCD Sync
# -----------------------------------------------------------------------------
wait_for_argocd_sync() {
    local baseline_rev="${1:-}"  # Optional: baseline revision passed by caller

    log_step "Waiting for ArgoCD sync..."

    # Use provided baseline or get current revision
    local prev_revision
    if [[ -n "$baseline_rev" ]]; then
        prev_revision="$baseline_rev"
    else
        prev_revision=$(kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.sync.revision}' 2>/dev/null)
    fi

    # Trigger ArgoCD to refresh by annotating the application
    kubectl annotate application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

    local timeout="${ARGOCD_SYNC_TIMEOUT:-300}"
    local poll_interval=15
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local app_status=$(kubectl get application "$ARGOCD_APP_NAME" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)

        local sync_status=$(echo "$app_status" | jq -r '.status.sync.status // "Unknown"')
        local health_status=$(echo "$app_status" | jq -r '.status.health.status // "Unknown"')
        local current_revision=$(echo "$app_status" | jq -r '.status.sync.revision // ""')

        # Wait for revision to change AND status to be Synced+Healthy
        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$current_revision" != "$prev_revision" ]]; then
            log_pass "$ARGOCD_APP_NAME synced and healthy (${elapsed}s)"
            echo ""
            return 0
        fi

        log_info "Status: sync=$sync_status health=$health_status rev=${current_revision:0:7} (${elapsed}s elapsed)"

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

wait_for_env_sync() {
    local env_name="$1"
    local baseline_rev="${2:-}"  # Optional: baseline revision passed by caller
    local app_name="${APP_REPO_NAME}-${env_name}"

    log_step "Waiting for ArgoCD sync ($env_name)..."

    # Use provided baseline or get current revision
    local prev_revision
    if [[ -n "$baseline_rev" ]]; then
        prev_revision="$baseline_rev"
    else
        prev_revision=$(kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" \
            -o jsonpath='{.status.sync.revision}' 2>/dev/null)
    fi

    # Trigger ArgoCD to refresh
    kubectl annotate application "$app_name" -n "$ARGOCD_NAMESPACE" \
        argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

    local timeout="${ARGOCD_SYNC_TIMEOUT:-300}"
    local poll_interval=15
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local app_status=$(kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
        local sync_status=$(echo "$app_status" | jq -r '.status.sync.status // "Unknown"')
        local health_status=$(echo "$app_status" | jq -r '.status.health.status // "Unknown"')
        local current_revision=$(echo "$app_status" | jq -r '.status.sync.revision // ""')

        # Wait for revision to change AND status to be Synced+Healthy
        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" && "$current_revision" != "$prev_revision" ]]; then
            log_pass "$app_name synced and healthy (${elapsed}s)"
            echo ""
            return 0
        fi

        log_info "Status: sync=$sync_status health=$health_status rev=${current_revision:0:7} (${elapsed}s elapsed)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for ArgoCD sync ($env_name)"
    echo ""
    echo "--- ArgoCD Application Status ---"
    kubectl describe application "$app_name" -n "$ARGOCD_NAMESPACE" 2>/dev/null | tail -30
    echo "--- End Status ---"
    exit 1
}

# -----------------------------------------------------------------------------
# Deployment Verification
# -----------------------------------------------------------------------------
verify_deployment() {
    log_step "Verifying deployment..."

    # Expected image tag from the build
    local expected_tag="$IMAGE_TAG"
    local timeout=120
    local elapsed=0
    local poll_interval=5

    while [[ $elapsed -lt $timeout ]]; do
        # Get pod info - look for pods with the expected image
        local pod_info=$(kubectl get pods -n "$DEV_NAMESPACE" -l "$APP_LABEL" -o json 2>/dev/null)

        # Find running pods with the correct image tag
        local matching_pod=$(echo "$pod_info" | jq -r --arg tag "$expected_tag" \
            '.items[] | select(.status.phase == "Running") | select(.spec.containers[0].image | contains($tag)) | .metadata.name' | head -1)

        if [[ -n "$matching_pod" ]]; then
            local deployed_image=$(echo "$pod_info" | jq -r --arg name "$matching_pod" \
                '.items[] | select(.metadata.name == $name) | .spec.containers[0].image')
            log_pass "Pod running with image: $deployed_image"
            echo ""
            export DEPLOYED_IMAGE="$deployed_image"
            return 0
        fi

        log_info "Waiting for pod with image tag $expected_tag... (${elapsed}s elapsed)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for pod with image tag $expected_tag"
    echo ""
    echo "--- Pod Status ---"
    kubectl get pods -n "$DEV_NAMESPACE" -l "$APP_LABEL"
    echo ""
    echo "--- Pod Events ---"
    kubectl describe pods -n "$DEV_NAMESPACE" -l "$APP_LABEL" | grep -A 20 "Events:" | head -25
    echo "--- End ---"
    exit 1
}

verify_env_deployment() {
    local env_name="$1"
    local namespace="${env_name}"

    log_step "Verifying deployment ($env_name)..."

    # Expected image tag from the build (same as dev)
    local expected_tag="$IMAGE_TAG"
    local timeout=120
    local elapsed=0
    local poll_interval=5

    while [[ $elapsed -lt $timeout ]]; do
        local pod_info=$(kubectl get pods -n "$namespace" -l "$APP_LABEL" -o json 2>/dev/null)

        # Find running pods with the correct image tag
        local matching_pod=$(echo "$pod_info" | jq -r --arg tag "$expected_tag" \
            '.items[] | select(.status.phase == "Running") | select(.spec.containers[0].image | contains($tag)) | .metadata.name' | head -1)

        if [[ -n "$matching_pod" ]]; then
            local deployed_image=$(echo "$pod_info" | jq -r --arg name "$matching_pod" \
                '.items[] | select(.metadata.name == $name) | .spec.containers[0].image')
            log_pass "Pod running with image: $deployed_image ($env_name)"
            echo ""
            return 0
        fi

        log_info "Waiting for pod with image tag $expected_tag in $env_name... (${elapsed}s elapsed)"
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log_fail "Timeout waiting for pod with image tag $expected_tag ($env_name)"
    echo ""
    echo "--- Pod Status ---"
    kubectl get pods -n "$namespace" -l "$APP_LABEL"
    echo "--- End ---"
    exit 1
}

# -----------------------------------------------------------------------------
# Get Jenkins Build Baseline
# Helper to capture build number BEFORE triggering an action
# -----------------------------------------------------------------------------
get_jenkins_baseline() {
    local branch="$1"
    local job_name="${DEPLOYMENTS_REPO_NAME:-k8s-deployments}"
    local job_path="job/${job_name}/job/${branch}"

    local response
    response=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
        "$JENKINS_URL/${job_path}/lastBuild/api/json" 2>/dev/null) || true
    if echo "$response" | jq empty 2>/dev/null; then
        echo "$response" | jq -r '.number // 0'
    else
        echo "0"
    fi
}

# -----------------------------------------------------------------------------
# Get ArgoCD Revision Baseline
# Helper to capture revision BEFORE triggering an action
# -----------------------------------------------------------------------------
get_argocd_baseline() {
    local app_name="${1:-$ARGOCD_APP_NAME}"
    kubectl get application "$app_name" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local start_time=$(date +%s)

    preflight_checks

    # Verify pipeline is quiescent (no open MRs, running builds, or lingering branches)
    demo_preflight_check

    bump_version
    commit_and_push
    wait_for_jenkins_build

    # Capture baselines BEFORE merging (to avoid race conditions)
    local dev_baseline=$(get_jenkins_baseline "dev")
    local dev_argocd_baseline=$(get_argocd_baseline)
    # Capture promotion MR baseline before dev build creates it
    local stage_mr_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    merge_dev_mr

    # Wait for k8s-deployments dev branch build (this creates the promotion MR to stage)
    wait_for_k8s_deployments_ci "dev" "$dev_baseline"

    wait_for_argocd_sync "$dev_argocd_baseline"
    verify_deployment

    # Stage promotion (MR auto-created by k8s-deployments CI after dev deployment)
    wait_for_promotion_mr "stage" "$stage_mr_baseline"

    # Capture baselines BEFORE merging stage MR
    local stage_baseline=$(get_jenkins_baseline "stage")
    local stage_argocd_baseline=$(get_argocd_baseline "${APP_REPO_NAME}-stage")
    # Capture promotion MR baseline before stage build creates it
    local prod_mr_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    merge_env_mr "stage"

    # Wait for k8s-deployments stage branch build (this creates the prod promotion MR)
    wait_for_k8s_deployments_ci "stage" "$stage_baseline"

    wait_for_env_sync "stage" "$stage_argocd_baseline"
    verify_env_deployment "stage"

    # Prod promotion (MR auto-created by k8s-deployments CI after stage deployment)
    wait_for_promotion_mr "prod" "$prod_mr_baseline"
    local prod_argocd_baseline=$(get_argocd_baseline "${APP_REPO_NAME}-prod")
    merge_env_mr "prod"
    wait_for_env_sync "prod" "$prod_argocd_baseline"
    verify_env_deployment "prod"

    # Verify pipeline is quiescent after validation
    demo_postflight_check

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))

    echo "=== VALIDATION PASSED ==="
    echo "Version $NEW_VERSION deployed to dev, stage, and prod in ${minutes}m ${seconds}s"
}

main "$@"
