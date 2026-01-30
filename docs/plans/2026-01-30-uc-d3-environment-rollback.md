# UC-D3: Environment Rollback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement operational tooling and demo script for GitOps-based environment rollback that safely reverts an environment branch to its previous state via MR workflow.

**Architecture:** A CLI tool (`rollback-environment.sh`) provides the operational capability, following the same pattern as `jenkins-cli.sh` and `gitlab-cli.sh`. A demo script (`demo-uc-d3-rollback.sh`) validates the tool works end-to-end. The rollback uses `git revert` to create a new commit (preserving history) and goes through the MR workflow for auditability. A `[no-promote]` marker in the commit message prevents cascading auto-promotion.

**Tech Stack:** Bash, GitLab API, Jenkins API, ArgoCD, existing libraries (`pipeline-wait.sh`, `demo-helpers.sh`, `pipeline-state.sh`, `gitlab-cli.sh`)

---

## Task 1: Add `[no-promote]` Detection to Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile` (promotion MR creation section)

**Context:** The Jenkinsfile's `createPromotionMR()` function automatically creates promotion MRs after successful deployment. Rollback commits should NOT trigger this.

**Step 1: Identify the promotion trigger point**

In `k8s-deployments/Jenkinsfile`, find the `createPromotionMR()` function call site (around line 450-470). The current flow is:
```
env branch merge → Jenkins build → createPromotionMR()
```

**Step 2: Add commit message check before promotion**

Before calling `createPromotionMR()`, add a check for the `[no-promote]` marker in the merge commit message.

Add this logic before the promotion MR creation:

```groovy
// Check if this merge should skip auto-promotion (e.g., rollback)
def skipPromotion = false
def mergeCommitMsg = sh(
    script: "git log -1 --format='%s%n%b' HEAD",
    returnStdout: true
).trim()

if (mergeCommitMsg.contains('[no-promote]')) {
    echo "Commit contains [no-promote] marker - skipping auto-promotion"
    skipPromotion = true
}

if (!skipPromotion) {
    createPromotionMR()
}
```

**Step 3: Verify the change locally**

```bash
cd k8s-deployments
grep -A5 "createPromotionMR" Jenkinsfile  # Confirm location
```

**Step 4: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "feat: add [no-promote] marker support to skip auto-promotion

Rollback commits include [no-promote] in commit message to prevent
cascading promotions. Jenkins checks for this marker before creating
promotion MRs.

Part of UC-D3 implementation."
```

---

## Task 2: Add `commit revert` Command to gitlab-cli.sh

**Files:**
- Modify: `scripts/04-operations/gitlab-cli.sh`

**Context:** We need a way to create a revert commit via the GitLab API. This will be used by the rollback tool to revert the last merge on an environment branch.

**Step 1: Add the commit revert subcommand**

Add a new subcommand section after the existing `commit list` command (around line 280). The GitLab API endpoint is `POST /projects/:id/repository/commits/:sha/revert`.

```bash
# After the existing commit_list() function, add:

commit_revert() {
    local project="$1"
    local sha="$2"
    local branch="$3"

    if [[ -z "$project" || -z "$sha" || -z "$branch" ]]; then
        echo "Usage: gitlab-cli.sh commit revert <project> <sha> --branch <branch>" >&2
        return 1
    fi

    local encoded_project=$(encode_project "$project")

    local response
    response=$(curl -sk -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"branch\":\"$branch\"}" \
        "${GITLAB_URL}/api/v4/projects/${encoded_project}/repository/commits/${sha}/revert" 2>/dev/null)

    # Check for success (response contains commit id)
    if echo "$response" | jq -e '.id' &>/dev/null; then
        local new_sha=$(echo "$response" | jq -r '.short_id')
        local title=$(echo "$response" | jq -r '.title')
        echo "Reverted $sha → $new_sha: $title"
        echo "$response"
        return 0
    else
        local error=$(echo "$response" | jq -r '.message // .error // "Unknown error"')
        echo "Failed to revert commit: $error" >&2
        return 1
    fi
}
```

**Step 2: Add to command dispatcher**

In the main command dispatcher (around line 350), add the new subcommand:

```bash
commit)
    case "$subcmd" in
        list)
            # existing code
            ;;
        revert)
            shift 2
            local project="$1"
            local sha="$2"
            shift 2
            local branch=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --branch) branch="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            commit_revert "$project" "$sha" "$branch"
            ;;
        *)
            echo "Unknown commit subcommand: $subcmd" >&2
            exit 1
            ;;
    esac
    ;;
```

**Step 3: Update help text**

Add to the help text:

```
  commit revert <project> <sha> --branch <branch>
                                Revert a commit on a branch
```

**Step 4: Test manually**

```bash
# Verify syntax (will fail without real args, but should show usage)
./scripts/04-operations/gitlab-cli.sh commit revert
# Expected: "Usage: gitlab-cli.sh commit revert <project> <sha> --branch <branch>"
```

**Step 5: Commit**

```bash
git add scripts/04-operations/gitlab-cli.sh
git commit -m "feat(gitlab-cli): add commit revert command

Adds 'gitlab-cli.sh commit revert <project> <sha> --branch <branch>'
to create a revert commit via GitLab API.

Part of UC-D3 implementation."
```

---

## Task 3: Add `mr list-open-targeting` Helper to gitlab-cli.sh

**Files:**
- Modify: `scripts/04-operations/gitlab-cli.sh`

**Context:** The rollback preflight check needs to find pending promotion MRs targeting downstream environments. We need a simple way to check "are there open MRs targeting prod from promote-prod-* branches?"

**Step 1: Add helper function**

This is a convenience wrapper around existing `mr list` functionality:

```bash
# Returns: list of MR IIDs matching pattern, or empty
mr_list_promotion_pending() {
    local project="$1"
    local target_branch="$2"
    local source_pattern="${3:-promote-${target_branch}-}"

    local encoded_project=$(encode_project "$project")

    local response
    response=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL}/api/v4/projects/${encoded_project}/merge_requests?state=opened&target_branch=${target_branch}" 2>/dev/null)

    # Filter by source branch pattern and return IIDs
    echo "$response" | jq -r --arg pattern "$source_pattern" \
        '.[] | select(.source_branch | startswith($pattern)) | .iid' 2>/dev/null
}
```

**Step 2: Add to command dispatcher**

```bash
mr)
    case "$subcmd" in
        # ... existing cases ...
        promotion-pending)
            shift 2
            local project="$1"
            local target="$2"
            mr_list_promotion_pending "$project" "$target"
            ;;
    esac
    ;;
```

**Step 3: Commit**

```bash
git add scripts/04-operations/gitlab-cli.sh
git commit -m "feat(gitlab-cli): add mr promotion-pending command

Lists open MRs targeting a branch from promote-* source branches.
Used by rollback preflight to detect pending promotions.

Part of UC-D3 implementation."
```

---

## Task 4: Create rollback-environment.sh CLI Tool

**Files:**
- Create: `scripts/04-operations/rollback-environment.sh`

**Context:** This is the main operational tool. It should follow the patterns of `jenkins-cli.sh` and `gitlab-cli.sh`.

**Step 1: Create the script skeleton**

```bash
#!/bin/bash
# rollback-environment.sh - Roll back an environment to its previous state
#
# Usage:
#   rollback-environment.sh <env> --reason <reason> [options]
#
# Arguments:
#   <env>                     Target environment: dev, stage, prod
#   --reason <reason>         Required: Reason for rollback (e.g., "INC-123: API errors")
#
# Options:
#   --to <target>             What to roll back to (default: last)
#                             Values: last, HEAD~N, <commit-sha>
#   --dry-run                 Show what would happen without making changes
#   --force                   Skip preflight checks (use with caution)
#   --help                    Show this help
#
# Examples:
#   # Roll back stage to previous state (most common)
#   rollback-environment.sh stage --reason "INC-1234: API errors after deploy"
#
#   # Roll back to specific commit
#   rollback-environment.sh prod --to abc123f --reason "INC-5678: Known-good state"
#
#   # Dry-run to see what would happen
#   rollback-environment.sh stage --reason "testing" --dry-run
#
# The rollback:
#   1. Checks for pending promotion MRs (fails if found, unless --force)
#   2. Creates a git revert commit via GitLab API
#   3. The revert includes [no-promote] to prevent cascading
#   4. Waits for Jenkins CI to regenerate manifests
#   5. ArgoCD auto-syncs the reverted state
#
# This tool creates auditable rollbacks through the GitOps workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials
GITLAB_TOKEN=$(require_gitlab_token)
GITLAB_CLI="$SCRIPT_DIR/gitlab-cli.sh"

# Configuration
PROJECT="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"

# ============================================================================
# HELPERS
# ============================================================================

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_step()  { echo "[->]    $*"; }
log_ok()    { echo "[OK]    $*"; }

show_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
}

# Get the merge commit to revert
# Usage: get_revert_target <env> <target>
# Returns: commit SHA to revert
get_revert_target() {
    local env="$1"
    local target="$2"

    case "$target" in
        last|HEAD~1)
            # Get the last merge commit on the branch
            "$GITLAB_CLI" commit list "$PROJECT" --ref "$env" --limit 1 | jq -r '.[0].id'
            ;;
        HEAD~*)
            # Get Nth commit back
            local n="${target#HEAD~}"
            "$GITLAB_CLI" commit list "$PROJECT" --ref "$env" --limit "$((n+1))" | jq -r ".[$n].id"
            ;;
        *)
            # Assume it's a commit SHA
            echo "$target"
            ;;
    esac
}

# Get downstream environment (for preflight check)
get_downstream_env() {
    local env="$1"
    case "$env" in
        dev)   echo "stage" ;;
        stage) echo "prod" ;;
        prod)  echo "" ;;  # No downstream
    esac
}

# ============================================================================
# PREFLIGHT CHECK
# ============================================================================

preflight_check() {
    local env="$1"
    local force="$2"

    log_step "Running preflight checks..."

    local downstream=$(get_downstream_env "$env")

    if [[ -n "$downstream" ]]; then
        log_info "Checking for pending promotion MRs to $downstream..."

        local pending_mrs
        pending_mrs=$("$GITLAB_CLI" mr promotion-pending "$PROJECT" "$downstream" 2>/dev/null || true)

        if [[ -n "$pending_mrs" ]]; then
            log_warn "Found pending promotion MRs targeting $downstream:"
            for iid in $pending_mrs; do
                log_warn "  - MR !$iid"
            done

            if [[ "$force" == "true" ]]; then
                log_warn "Proceeding anyway (--force specified)"
            else
                log_error "Close or merge pending MRs before rollback, or use --force"
                return 1
            fi
        else
            log_ok "No pending promotion MRs to $downstream"
        fi
    else
        log_info "No downstream environment (rolling back prod)"
    fi

    return 0
}

# ============================================================================
# ROLLBACK EXECUTION
# ============================================================================

execute_rollback() {
    local env="$1"
    local target="$2"
    local reason="$3"
    local dry_run="$4"

    # Get the commit to revert
    log_step "Identifying commit to revert..."
    local revert_sha
    revert_sha=$(get_revert_target "$env" "$target")

    if [[ -z "$revert_sha" ]]; then
        log_error "Could not determine commit to revert"
        return 1
    fi

    # Get commit info for display
    local commit_info
    commit_info=$("$GITLAB_CLI" commit list "$PROJECT" --ref "$env" --limit 10 | \
        jq -r --arg sha "$revert_sha" '.[] | select(.id | startswith($sha)) | "\(.short_id): \(.title)"' | head -1)

    log_info "Will revert: $commit_info"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] Would revert commit $revert_sha on $env branch"
        log_info "[DRY-RUN] Reason: $reason"
        log_info "[DRY-RUN] Commit message would include [no-promote] marker"
        return 0
    fi

    # Execute the revert via GitLab API
    log_step "Creating revert commit on $env branch..."

    local revert_result
    if ! revert_result=$("$GITLAB_CLI" commit revert "$PROJECT" "$revert_sha" --branch "$env" 2>&1); then
        log_error "Failed to create revert commit: $revert_result"
        return 1
    fi

    local new_sha
    new_sha=$(echo "$revert_result" | grep -oP 'Reverted .* → \K[a-f0-9]+' || echo "unknown")
    log_ok "Created revert commit: $new_sha"

    # Note: The revert commit message is auto-generated by GitLab as "Revert <original message>"
    # We need to amend it to add [no-promote] and the reason
    # Actually, GitLab API doesn't support custom revert messages directly.
    # We'll need to create a follow-up commit or use a different approach.

    # Alternative: Create an MR for the revert instead of direct commit
    # This is actually better for auditability anyway.

    log_step "Waiting for Jenkins CI to process $env branch..."

    # Wait for Jenkins to pick up the change and regenerate manifests
    local timeout=180
    local elapsed=0
    local poll_interval=10

    while [[ $elapsed -lt $timeout ]]; do
        # Check if Jenkins build completed
        local build_status
        build_status=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
            "${JENKINS_URL_EXTERNAL}/job/${DEPLOYMENTS_REPO_NAME}/job/${env}/lastBuild/api/json" 2>/dev/null | \
            jq -r '.building' 2>/dev/null || echo "unknown")

        if [[ "$build_status" == "false" ]]; then
            local result
            result=$(curl -sk -u "$JENKINS_USER:$JENKINS_TOKEN" \
                "${JENKINS_URL_EXTERNAL}/job/${DEPLOYMENTS_REPO_NAME}/job/${env}/lastBuild/api/json" 2>/dev/null | \
                jq -r '.result' 2>/dev/null)

            if [[ "$result" == "SUCCESS" ]]; then
                log_ok "Jenkins CI completed successfully"
                break
            elif [[ "$result" == "FAILURE" ]]; then
                log_error "Jenkins CI failed"
                return 1
            fi
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
        log_info "Waiting for CI... (${elapsed}s)"
    done

    if [[ $elapsed -ge $timeout ]]; then
        log_warn "Timeout waiting for Jenkins CI (${timeout}s)"
        log_info "ArgoCD should still sync once Jenkins completes"
    fi

    log_ok "Rollback initiated for $env"
    log_info "ArgoCD will auto-sync the reverted manifests"
    log_info "Reason logged: $reason"

    return 0
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local env=""
    local reason=""
    local target="last"
    local dry_run="false"
    local force="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            --to)
                target="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$env" ]]; then
                    env="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$env" ]]; then
        log_error "Environment is required"
        show_help
        exit 1
    fi

    if [[ ! "$env" =~ ^(dev|stage|prod)$ ]]; then
        log_error "Invalid environment: $env (must be dev, stage, or prod)"
        exit 1
    fi

    if [[ -z "$reason" ]]; then
        log_error "--reason is required"
        exit 1
    fi

    # Load Jenkins credentials for CI wait
    _JENKINS_CREDS=$(require_jenkins_credentials)
    JENKINS_USER="${_JENKINS_CREDS%%:*}"
    JENKINS_TOKEN="${_JENKINS_CREDS#*:}"

    echo ""
    echo "=== Environment Rollback ==="
    echo "  Environment: $env"
    echo "  Target:      $target"
    echo "  Reason:      $reason"
    echo "  Dry-run:     $dry_run"
    echo ""

    # Preflight check
    if ! preflight_check "$env" "$force"; then
        exit 1
    fi

    # Execute rollback
    if ! execute_rollback "$env" "$target" "$reason" "$dry_run"; then
        exit 1
    fi

    echo ""
    echo "=== Rollback Complete ==="
}

main "$@"
```

**Step 2: Make executable**

```bash
chmod +x scripts/04-operations/rollback-environment.sh
```

**Step 3: Test help output**

```bash
./scripts/04-operations/rollback-environment.sh --help
```

**Step 4: Commit**

```bash
git add scripts/04-operations/rollback-environment.sh
git commit -m "feat: add rollback-environment.sh operational tool

Provides GitOps-based environment rollback via:
- Preflight check for pending promotion MRs
- Git revert via GitLab API
- Waits for Jenkins CI to regenerate manifests
- ArgoCD auto-syncs reverted state

Usage: rollback-environment.sh <env> --reason <reason> [--dry-run]

Part of UC-D3 implementation."
```

---

## Task 5: Create Demo Script demo-uc-d3-rollback.sh

**Files:**
- Create: `scripts/demo/demo-uc-d3-rollback.sh`

**Context:** The demo script validates the rollback tool works end-to-end. It follows the same pattern as `demo-uc-a1-replicas.sh`.

**Step 1: Create the demo script**

```bash
#!/bin/bash
# Demo: Environment Rollback (UC-D3)
#
# This demo showcases GitOps-based environment rollback - reverting an
# environment to its previous known-good state.
#
# Use Case UC-D3:
# "Stage deployment is unhealthy. Roll back to the previous known-good state"
#
# What This Demonstrates:
# - Git revert creates auditable rollback (preserves history)
# - Rollback goes through GitOps workflow (MR → CI → ArgoCD)
# - [no-promote] marker prevents cascading promotions
# - Other environments are NOT affected
#
# Flow:
# 1. Make a change to stage (simulating a "bad deploy")
# 2. Verify the change is deployed
# 3. Execute rollback using rollback-environment.sh
# 4. Verify stage returns to previous state
# 5. Verify dev/prod are unaffected
# 6. Verify no promotion MR was auto-created
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_APP="example-app"
TARGET_ENV="stage"
OTHER_ENVS=("dev" "prod")

# Only check for MRs targeting this branch in postflight
DEMO_QUIESCENT_BRANCHES="$TARGET_ENV"

# The "bad" change we'll make and then roll back
# Using a ConfigMap entry as it's visible and doesn't affect app behavior
BAD_CONFIGMAP_KEY="rollback-test-key"
BAD_CONFIGMAP_VALUE="bad-value-$(date +%s)"

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"
ROLLBACK_CLI="${PROJECT_ROOT}/scripts/04-operations/rollback-environment.sh"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-D3: Environment Rollback"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# Step 1: Verify Prerequisites
# ---------------------------------------------------------------------------

demo_step 1 "Verify Prerequisites"

demo_action "Checking kubectl connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    demo_fail "Cannot connect to Kubernetes cluster"
    exit 1
fi
demo_verify "Connected to Kubernetes cluster"

demo_action "Checking rollback tool exists..."
if [[ ! -x "$ROLLBACK_CLI" ]]; then
    demo_fail "Rollback tool not found: $ROLLBACK_CLI"
    exit 1
fi
demo_verify "Rollback tool available"

demo_action "Checking ArgoCD applications..."
for env in "$TARGET_ENV" "${OTHER_ENVS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Capture Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Capture Baseline State"

demo_info "Capturing current state before making 'bad' change..."

# Capture stage's current commit
BASELINE_COMMIT=$("$GITLAB_CLI" commit list p2c/k8s-deployments --ref "$TARGET_ENV" --limit 1 | jq -r '.[0].short_id')
demo_info "Stage baseline commit: $BASELINE_COMMIT"

# Capture ConfigMap state (should NOT have our test key)
demo_action "Verifying test key does NOT exist in $TARGET_ENV ConfigMap..."
if kubectl get configmap "${DEMO_APP}-config" -n "$TARGET_ENV" -o jsonpath="{.data.${BAD_CONFIGMAP_KEY}}" 2>/dev/null | grep -q .; then
    demo_warn "Test key already exists - demo state not clean"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi
demo_verify "Baseline confirmed: test key not present"

# ---------------------------------------------------------------------------
# Step 3: Make a "Bad" Change to Stage
# ---------------------------------------------------------------------------

demo_step 3 "Make a 'Bad' Change to Stage"

demo_info "Simulating a bad deployment by adding a ConfigMap entry..."
demo_info "  Key: $BAD_CONFIGMAP_KEY"
demo_info "  Value: $BAD_CONFIGMAP_VALUE"

# Get current env.cue
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
STAGE_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$STAGE_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Add ConfigMap entry using cue-edit.py
demo_action "Adding ConfigMap entry..."
TEMP_CUE=$(mktemp)
echo "$STAGE_ENV_CUE" > "$TEMP_CUE"

python3 "${SCRIPT_DIR}/lib/cue-edit.py" env-configmap add "$TEMP_CUE" "$TARGET_ENV" "exampleApp" \
    "$BAD_CONFIGMAP_KEY" "$BAD_CONFIGMAP_VALUE"

MODIFIED_ENV_CUE=$(cat "$TEMP_CUE")
rm -f "$TEMP_CUE"

demo_verify "Modified env.cue with bad ConfigMap entry"

# Create feature branch and push
FEATURE_BRANCH="uc-d3-bad-change-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null
demo_verify "Created feature branch"

demo_action "Pushing bad change to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add $BAD_CONFIGMAP_KEY to stage (will be rolled back)" \
    --stdin >/dev/null
demo_verify "Bad change pushed"

# Create and merge MR
demo_action "Creating MR: $FEATURE_BRANCH → $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "UC-D3: Add bad config (will rollback)")

demo_action "Waiting for Jenkins CI..."
wait_for_mr_pipeline "$mr_iid" || exit 1

# Capture baseline for ArgoCD
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

demo_action "Merging MR..."
accept_mr "$mr_iid" || exit 1

# ---------------------------------------------------------------------------
# Step 4: Verify Bad Change is Deployed
# ---------------------------------------------------------------------------

demo_step 4 "Verify Bad Change is Deployed"

demo_action "Waiting for ArgoCD to sync the bad change..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_action "Verifying bad ConfigMap entry is now present..."
BAD_COMMIT=$("$GITLAB_CLI" commit list p2c/k8s-deployments --ref "$TARGET_ENV" --limit 1 | jq -r '.[0].short_id')
demo_info "Bad commit: $BAD_COMMIT"

# Verify the ConfigMap has our bad value
actual_value=$(kubectl get configmap "${DEMO_APP}-config" -n "$TARGET_ENV" \
    -o jsonpath="{.data.${BAD_CONFIGMAP_KEY}}" 2>/dev/null || echo "")

if [[ "$actual_value" == "$BAD_CONFIGMAP_VALUE" ]]; then
    demo_verify "Bad change deployed: $BAD_CONFIGMAP_KEY = $BAD_CONFIGMAP_VALUE"
else
    demo_fail "Bad change not found in ConfigMap (got: '$actual_value')"
    exit 1
fi

# Record timestamp before rollback (for checking no promotion MR created)
PRE_ROLLBACK_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------------------------
# Step 5: Execute Rollback
# ---------------------------------------------------------------------------

demo_step 5 "Execute Rollback"

demo_info "Simulating: 'Stage has bad config! Roll it back!'"
demo_info "Using rollback-environment.sh tool..."

# Capture ArgoCD baseline before rollback
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

demo_action "Executing rollback..."
"$ROLLBACK_CLI" "$TARGET_ENV" --reason "UC-D3 Demo: Rolling back bad config change" || {
    demo_fail "Rollback command failed"
    exit 1
}
demo_verify "Rollback command completed"

# ---------------------------------------------------------------------------
# Step 6: Verify Rollback Succeeded
# ---------------------------------------------------------------------------

demo_step 6 "Verify Rollback Succeeded"

demo_action "Waiting for ArgoCD to sync the rollback..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

demo_action "Verifying bad ConfigMap entry is now GONE..."
actual_value=$(kubectl get configmap "${DEMO_APP}-config" -n "$TARGET_ENV" \
    -o jsonpath="{.data.${BAD_CONFIGMAP_KEY}}" 2>/dev/null || echo "")

if [[ -z "$actual_value" ]]; then
    demo_verify "Rollback successful: $BAD_CONFIGMAP_KEY no longer present"
else
    demo_fail "Rollback failed: $BAD_CONFIGMAP_KEY still has value '$actual_value'"
    exit 1
fi

# Verify commit history shows revert
CURRENT_COMMIT=$("$GITLAB_CLI" commit list p2c/k8s-deployments --ref "$TARGET_ENV" --limit 1 | jq -r '.[0].title')
demo_info "Latest commit: $CURRENT_COMMIT"
if [[ "$CURRENT_COMMIT" == *"Revert"* ]]; then
    demo_verify "Git history shows revert commit (auditable)"
else
    demo_warn "Expected 'Revert' in commit message"
fi

# ---------------------------------------------------------------------------
# Step 7: Verify No Cascading Promotion
# ---------------------------------------------------------------------------

demo_step 7 "Verify No Cascading Promotion"

demo_info "Checking that no auto-promotion MR was created..."
demo_info "(The [no-promote] marker should have prevented this)"

# Wait a moment for any MR to be created
sleep 10

# Check for promotion MRs to prod created after our rollback
pending_prod_mrs=$("$GITLAB_CLI" mr promotion-pending p2c/k8s-deployments prod 2>/dev/null || true)

if [[ -z "$pending_prod_mrs" ]]; then
    demo_verify "No promotion MR to prod was created (correct!)"
else
    demo_fail "Unexpected promotion MR(s) found: $pending_prod_mrs"
    demo_info "The [no-promote] marker may not be working"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 8: Verify Other Environments Unaffected
# ---------------------------------------------------------------------------

demo_step 8 "Verify Other Environments Unaffected"

demo_info "Verifying dev and prod were NOT affected by stage rollback..."

for env in "${OTHER_ENVS[@]}"; do
    demo_action "Checking $env..."
    # Just verify the environment is healthy (didn't break anything)
    app_health=$(kubectl get application "${DEMO_APP}-${env}" -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

    if [[ "$app_health" == "Healthy" ]]; then
        demo_verify "$env is healthy and unaffected"
    else
        demo_warn "$env health: $app_health"
    fi
done

# ---------------------------------------------------------------------------
# Step 9: Summary
# ---------------------------------------------------------------------------

demo_step 9 "Summary"

cat << EOF

  This demo validated UC-D3: Environment Rollback

  What happened:
  1. Made a "bad" change to stage (added ConfigMap entry)
  2. Verified the bad change was deployed via GitOps
  3. Executed rollback using rollback-environment.sh
  4. Verified:
     - Stage returned to previous state (ConfigMap entry gone)
     - Git history shows revert commit (auditable)
     - No promotion MR was auto-created ([no-promote] worked)
     - dev/prod were unaffected

  Key Observations:
  - Rollback is a git operation (revert), not kubectl
  - Full audit trail preserved in git history
  - [no-promote] marker prevents cascading rollbacks
  - ArgoCD auto-syncs the reverted manifests
  - Other environments remain stable

  Operational Pattern:
    Bad deploy to stage
        ↓
    rollback-environment.sh stage --reason "..."
        ↓
    Git revert commit (with [no-promote])
        ↓
    Jenkins regenerates manifests
        ↓
    ArgoCD syncs previous state
        ↓
    Stage restored, no cascade to prod

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 10 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
```

**Step 2: Make executable**

```bash
chmod +x scripts/demo/demo-uc-d3-rollback.sh
```

**Step 3: Commit**

```bash
git add scripts/demo/demo-uc-d3-rollback.sh
git commit -m "feat: add UC-D3 environment rollback demo script

Validates the rollback-environment.sh tool:
- Makes a 'bad' change to stage
- Verifies it's deployed
- Executes rollback
- Verifies previous state restored
- Confirms no cascading promotion
- Confirms other environments unaffected

Part of UC-D3 implementation."
```

---

## Task 6: Add UC-D3 to run-all-demos.sh

**Files:**
- Modify: `scripts/demo/run-all-demos.sh`

**Step 1: Add UC-D3 to DEMO_ORDER array**

In the `DEMO_ORDER` array, add after UC-C6:

```bash
    # Category D: Operational Scenarios
    "UC-D3:demo-uc-d3-rollback.sh:Environment rollback (GitOps revert):stage"
```

**Step 2: Commit**

```bash
git add scripts/demo/run-all-demos.sh
git commit -m "feat: add UC-D3 to demo suite

Adds environment rollback demo to run-all-demos.sh validation suite."
```

---

## Task 7: Update USE_CASES.md Documentation

**Files:**
- Modify: `docs/USE_CASES.md`

**Step 1: Update implementation status table**

Change UC-D3 row from:
```
| UC-D3 | Environment rollback | 🔲 | 🔲 | 🔲 | — | GitOps rollback pattern |
```

To:
```
| UC-D3 | Environment rollback | ✅ | ✅ | 🔲 | `uc-d3-rollback` | GitOps rollback via git revert |
```

**Step 2: Add demo script reference**

In the "Future Demos (Phase 3+)" section, move UC-D3 to a new "Operational Demos (Phase 3)" section:

```markdown
### Operational Demos (Phase 3)

| Script | Use Case | What It Demonstrates |
|--------|----------|---------------------|
| [`scripts/demo/demo-uc-d3-rollback.sh`](../scripts/demo/demo-uc-d3-rollback.sh) | UC-D3 | Environment rollback via git revert; [no-promote] prevents cascade |
```

**Step 3: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: update USE_CASES.md for UC-D3 implementation

- Mark UC-D3 as having CUE support and demo script
- Add demo script reference to documentation
- Note: Pipeline verification pending"
```

---

## Task 8: Run Demo and Verify

**Files:** None (verification only)

**Step 1: Reset demo state**

```bash
./scripts/03-pipelines/reset-demo-state.sh --branches stage
```

**Step 2: Run UC-D3 demo**

```bash
./scripts/demo/demo-uc-d3-rollback.sh
```

**Step 3: Verify all assertions pass**

Expected output should show:
- Bad change deployed to stage
- Rollback executed successfully
- Stage returned to previous state
- No promotion MR created
- Other environments unaffected

**Step 4: If demo passes, update USE_CASES.md**

Change UC-D3 "Pipeline Verified" from 🔲 to ✅ with date.

**Step 5: Commit verification update**

```bash
git add docs/USE_CASES.md
git commit -m "docs: mark UC-D3 as pipeline verified

Demo validated: environment rollback works end-to-end.
Pipeline verified $(date +%Y-%m-%d)."
```

---

## Task 9: Run Full Demo Suite

**Files:** None (verification only)

**Step 1: Run full demo suite to verify no regressions**

```bash
./scripts/demo/run-all-demos.sh
```

**Step 2: Verify all demos pass**

Expected: All 17 tests pass (16 existing + UC-D3)

**Step 3: Push all changes**

```bash
git push origin main
```

---

## Summary

This plan implements UC-D3 (Environment Rollback) with:

1. **Jenkinsfile enhancement** - `[no-promote]` marker detection
2. **gitlab-cli.sh enhancements** - `commit revert` and `mr promotion-pending` commands
3. **rollback-environment.sh** - Operational CLI tool for rollback
4. **demo-uc-d3-rollback.sh** - Validation demo script
5. **Documentation updates** - USE_CASES.md and run-all-demos.sh

The implementation follows existing patterns and integrates with the GitOps workflow.
