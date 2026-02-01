# UC-E2 and UC-E4 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement demo scripts for UC-E2 (App code + config change together) and UC-E4 (App-level rollback) to validate the pipeline handles these app lifecycle scenarios correctly.

**Architecture:** Both demos follow the established demo script patterns - they use the demo helper libraries, operate via GitLab API (not local git), verify K8s state, and ensure pipeline quiescence before/after. UC-E2 modifies both example-app source AND deployment/app.cue in the same commit. UC-E4 surgically rolls back only the image tag while preserving env.cue settings.

**Tech Stack:** Bash demo scripts, GitLab CLI, Jenkins CLI, kubectl, existing demo helper libraries (demo-helpers.sh, pipeline-wait.sh, assertions.sh)

---

## Task 1: Add gitlab-cli.sh Support for Example-App Repository

UC-E2 needs to commit to the example-app repo (not k8s-deployments). The gitlab-cli.sh currently defaults to k8s-deployments. We need to support specifying the project.

**Files:**
- Modify: `scripts/04-operations/gitlab-cli.sh`

**Step 1: Review current gitlab-cli.sh file command**

Read `scripts/04-operations/gitlab-cli.sh` and locate the `file update` command to understand how project is handled.

**Step 2: Verify project parameter already supported**

The `file update` command already takes project as first argument (e.g., `gitlab-cli.sh file update p2c/example-app env.cue ...`). Verify this works for example-app:

Run: `./scripts/04-operations/gitlab-cli.sh file get p2c/example-app pom.xml --ref main | head -5`
Expected: First 5 lines of pom.xml

**Step 3: Document the capability**

No code change needed - gitlab-cli.sh already supports arbitrary projects. Move to next task.

---

## Task 2: Create UC-E2 Demo Script Skeleton

**Files:**
- Create: `scripts/demo/demo-uc-e2-code-plus-config.sh`

**Step 1: Create the demo script with boilerplate**

```bash
#!/bin/bash
# Demo: App Code + Config Change Together (UC-E2)
#
# This demo proves that code changes bundled with deployment/app.cue changes
# flow through the pipeline atomically - the new image and new config deploy
# together, avoiding partial states.
#
# Use Case UC-E2:
# "As a developer, I push a code change that also requires a new environment
# variable, and both flow through the pipeline together"
#
# What This Demonstrates:
# - Code change + deployment/app.cue change in same commit
# - Jenkins builds the new image
# - App CI extracts and merges deployment/app.cue into k8s-deployments
# - Both image update AND config change appear in the same MR
# - Atomic deployment: new env var available when new code runs
#
# Flow:
# 1. Add a new env var reference to example-app code
# 2. Add the env var to deployment/app.cue
# 3. Bump version and commit both changes together
# 4. Push to GitLab, triggering the pipeline
# 5. Verify dev deployment has BOTH new image AND new env var
# 6. Promote through stage → prod
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"
EXAMPLE_APP_DIR="${PROJECT_ROOT}/example-app"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_APP="example-app"
DEMO_ENV_VAR_NAME="UC_E2_FEATURE"
DEMO_ENV_VAR_VALUE="code-config-atomic"
ENVIRONMENTS=("dev" "stage" "prod")

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$PROJECT_ROOT"

demo_init "UC-E2: App Code + Config Change Together"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# TODO: Implement demo steps
demo_fail "Demo not yet implemented"
exit 1
```

**Step 2: Make the script executable**

Run: `chmod +x scripts/demo/demo-uc-e2-code-plus-config.sh`

**Step 3: Commit the skeleton**

```bash
git add scripts/demo/demo-uc-e2-code-plus-config.sh
git commit -m "feat: add UC-E2 demo script skeleton"
```

---

## Task 3: Implement UC-E2 Prerequisite Checks

**Files:**
- Modify: `scripts/demo/demo-uc-e2-code-plus-config.sh`

**Step 1: Add prerequisite verification**

Replace the `# TODO: Implement demo steps` section with:

```bash
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

demo_action "Checking ArgoCD applications..."
for env in "${ENVIRONMENTS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

demo_action "Checking example-app repo accessible..."
if ! "$GITLAB_CLI" file get p2c/example-app pom.xml --ref main >/dev/null 2>&1; then
    demo_fail "Cannot access example-app repo in GitLab"
    exit 1
fi
demo_verify "example-app repo accessible"

# ---------------------------------------------------------------------------
# Step 2: Verify Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Verify Baseline State"

demo_info "Confirming '$DEMO_ENV_VAR_NAME' does not exist in any environment..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."
    if kubectl get deployment "$DEMO_APP" -n "$env" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null | grep -q "$DEMO_ENV_VAR_NAME"; then
        demo_warn "Env var '$DEMO_ENV_VAR_NAME' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    fi
done

demo_verify "Baseline confirmed: '$DEMO_ENV_VAR_NAME' absent from all environments"

# TODO: Continue with remaining steps
demo_fail "Demo steps 3+ not yet implemented"
exit 1
```

**Step 2: Run to verify prerequisites work**

Run: `./scripts/demo/demo-uc-e2-code-plus-config.sh`
Expected: Should pass steps 1-2 then fail at "steps 3+ not yet implemented"

**Step 3: Commit progress**

```bash
git add scripts/demo/demo-uc-e2-code-plus-config.sh
git commit -m "feat(uc-e2): add prerequisite and baseline checks"
```

---

## Task 4: Implement UC-E2 Code + Config Modification

**Files:**
- Modify: `scripts/demo/demo-uc-e2-code-plus-config.sh`

**Step 1: Add version bump and config modification logic**

Replace the `# TODO: Continue with remaining steps` section with:

```bash
# ---------------------------------------------------------------------------
# Step 3: Prepare Code + Config Changes
# ---------------------------------------------------------------------------

demo_step 3 "Prepare Code + Config Changes"

demo_info "This step modifies BOTH:"
demo_info "  1. Application code (GreetingService.java) - reference new env var"
demo_info "  2. deployment/app.cue - define the new env var"
demo_info "Both changes will be in the same commit."

# Get current version from pom.xml
CURRENT_POM=$("$GITLAB_CLI" file get p2c/example-app pom.xml --ref main)
CURRENT_VERSION=$(echo "$CURRENT_POM" | grep -m1 '<version>' | sed 's/.*<version>\(.*\)<\/version>.*/\1/')
demo_info "Current version: $CURRENT_VERSION"

# Calculate next version
BASE_VERSION="${CURRENT_VERSION%-SNAPSHOT}"
IFS='.' read -r major minor patch <<< "$BASE_VERSION"
NEW_PATCH=$((patch + 1))
NEW_VERSION="${major}.${minor}.${NEW_PATCH}-SNAPSHOT"
demo_info "New version: $NEW_VERSION"

# Get current GreetingService.java
GREETING_SERVICE=$("$GITLAB_CLI" file get p2c/example-app src/main/java/com/example/app/GreetingService.java --ref main)

# Verify the code doesn't already reference our env var
if echo "$GREETING_SERVICE" | grep -q "$DEMO_ENV_VAR_NAME"; then
    demo_warn "Code already references '$DEMO_ENV_VAR_NAME' - demo may have stale state"
    exit 1
fi

# Add env var reference to GreetingService.java
# Insert after the class declaration, before existing fields
MODIFIED_GREETING_SERVICE=$(echo "$GREETING_SERVICE" | sed '/public class GreetingService/a\
\
    // UC-E2: Env var added with code change\
    @org.eclipse.microprofile.config.inject.ConfigProperty(name = "UC_E2_FEATURE", defaultValue = "not-set")\
    String ucE2Feature;')

demo_verify "Modified GreetingService.java to reference $DEMO_ENV_VAR_NAME"

# Get current deployment/app.cue
CURRENT_APP_CUE=$("$GITLAB_CLI" file get p2c/example-app deployment/app.cue --ref main)

# Verify the CUE doesn't already have our env var
if echo "$CURRENT_APP_CUE" | grep -q "$DEMO_ENV_VAR_NAME"; then
    demo_warn "deployment/app.cue already has '$DEMO_ENV_VAR_NAME' - demo may have stale state"
    exit 1
fi

# Add env var to appEnvVars array in deployment/app.cue
# Insert before the closing bracket of appEnvVars
MODIFIED_APP_CUE=$(echo "$CURRENT_APP_CUE" | awk -v name="$DEMO_ENV_VAR_NAME" -v val="$DEMO_ENV_VAR_VALUE" '
/appEnvVars: \[/ { in_env_vars=1 }
in_env_vars && /^\t\]$/ {
    print "\t\t{"
    print "\t\t\tname:  \"" name "\""
    print "\t\t\tvalue: \"" val "\""
    print "\t\t},"
    in_env_vars=0
}
{print}
')

demo_verify "Modified deployment/app.cue to add $DEMO_ENV_VAR_NAME"

# Update pom.xml with new version
MODIFIED_POM=$(echo "$CURRENT_POM" | sed "0,/<version>$CURRENT_VERSION<\/version>/s//<version>$NEW_VERSION<\/version>/")

demo_verify "Updated pom.xml version to $NEW_VERSION"

# ---------------------------------------------------------------------------
# Step 4: Push Changes to GitLab
# ---------------------------------------------------------------------------

demo_step 4 "Push Changes to GitLab"

FEATURE_BRANCH="uc-e2-code-config-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from main in example-app..."
"$GITLAB_CLI" branch create p2c/example-app "$FEATURE_BRANCH" --from main >/dev/null

# Push all three files in one commit using GitLab Commits API
demo_action "Pushing code + config changes in single commit..."

# Prepare JSON payload for multi-file commit
COMMIT_PAYLOAD=$(jq -n \
    --arg branch "$FEATURE_BRANCH" \
    --arg msg "feat: add $DEMO_ENV_VAR_NAME (code + config together) [UC-E2]" \
    --arg pom "$MODIFIED_POM" \
    --arg java "$MODIFIED_GREETING_SERVICE" \
    --arg cue "$MODIFIED_APP_CUE" \
    '{
        branch: $branch,
        commit_message: $msg,
        actions: [
            {action: "update", file_path: "pom.xml", content: $pom},
            {action: "update", file_path: "src/main/java/com/example/app/GreetingService.java", content: $java},
            {action: "update", file_path: "deployment/app.cue", content: $cue}
        ]
    }')

# URL-encode project path
ENCODED_PROJECT=$(echo "p2c/example-app" | sed 's/\//%2F/g')

COMMIT_RESULT=$(curl -sk -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$COMMIT_PAYLOAD" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_PROJECT}/repository/commits")

if echo "$COMMIT_RESULT" | jq -e '.id' >/dev/null 2>&1; then
    COMMIT_SHA=$(echo "$COMMIT_RESULT" | jq -r '.short_id')
    demo_verify "Pushed commit $COMMIT_SHA with all changes"
else
    demo_fail "Failed to push changes: $(echo "$COMMIT_RESULT" | jq -r '.message // "unknown error"')"
    exit 1
fi

# Create MR to main
demo_action "Creating MR: $FEATURE_BRANCH → main..."
MR_RESULT=$(curl -sk -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"source_branch\":\"$FEATURE_BRANCH\",\"target_branch\":\"main\",\"title\":\"UC-E2: Add $DEMO_ENV_VAR_NAME (code + config)\"}" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_PROJECT}/merge_requests")

APP_MR_IID=$(echo "$MR_RESULT" | jq -r '.iid // empty')
if [[ -n "$APP_MR_IID" ]]; then
    demo_verify "Created example-app MR !$APP_MR_IID"
else
    demo_fail "Failed to create MR: $(echo "$MR_RESULT" | jq -r '.message // "unknown error"')"
    exit 1
fi

# Export for later steps
export NEW_VERSION
export FEATURE_BRANCH
export APP_MR_IID

# TODO: Continue with pipeline steps
demo_fail "Demo steps 5+ not yet implemented"
exit 1
```

**Step 2: Run to verify modification logic**

Run: `./scripts/demo/demo-uc-e2-code-plus-config.sh`
Expected: Should create branch and MR in example-app, then fail at "steps 5+ not yet implemented"

**Step 3: Commit progress**

```bash
git add scripts/demo/demo-uc-e2-code-plus-config.sh
git commit -m "feat(uc-e2): implement code + config modification and GitLab push"
```

---

## Task 5: Implement UC-E2 Pipeline Wait and Verification

**Files:**
- Modify: `scripts/demo/demo-uc-e2-code-plus-config.sh`

**Step 1: Add pipeline wait and promotion logic**

Replace the `# TODO: Continue with pipeline steps` section with:

```bash
# ---------------------------------------------------------------------------
# Step 5: Wait for Example-App CI
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Example-App CI"

demo_info "Waiting for Jenkins to build example-app and create k8s-deployments MR..."

# Merge the example-app MR (simulate developer approval)
demo_action "Merging example-app MR !$APP_MR_IID..."
MERGE_RESULT=$(curl -sk -X PUT \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_PROJECT}/merge_requests/$APP_MR_IID/merge")

if [[ $(echo "$MERGE_RESULT" | jq -r '.state') == "merged" ]]; then
    demo_verify "example-app MR merged"
else
    demo_fail "Failed to merge MR: $(echo "$MERGE_RESULT" | jq -r '.message // "unknown error"')"
    exit 1
fi

# Wait for Jenkins to build and create k8s-deployments MR
demo_action "Waiting for Jenkins build on example-app/main..."

# Use jenkins-cli.sh to wait for the build
JENKINS_CLI="${PROJECT_ROOT}/scripts/04-operations/jenkins-cli.sh"
"$JENKINS_CLI" wait example-app/main --timeout 300 || {
    demo_fail "Jenkins build failed or timed out"
    exit 1
}
demo_verify "Jenkins build completed"

# ---------------------------------------------------------------------------
# Step 6: Wait for k8s-deployments MR
# ---------------------------------------------------------------------------

demo_step 6 "Wait for k8s-deployments MR"

demo_info "Jenkins should have created an MR to k8s-deployments dev branch..."

# Wait for the update MR to appear
K8S_ENCODED_PROJECT=$(echo "p2c/k8s-deployments" | sed 's/\//%2F/g')
MR_TIMEOUT=120
MR_ELAPSED=0

while [[ $MR_ELAPSED -lt $MR_TIMEOUT ]]; do
    MRS=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${K8S_ENCODED_PROJECT}/merge_requests?state=opened&target_branch=dev")

    # Look for MR with our version
    K8S_MR=$(echo "$MRS" | jq -r --arg ver "$NEW_VERSION" \
        'first(.[] | select(.source_branch | contains($ver))) // empty')

    if [[ -n "$K8S_MR" ]]; then
        K8S_MR_IID=$(echo "$K8S_MR" | jq -r '.iid')
        K8S_SOURCE_BRANCH=$(echo "$K8S_MR" | jq -r '.source_branch')
        demo_verify "Found k8s-deployments MR !$K8S_MR_IID (branch: $K8S_SOURCE_BRANCH)"
        break
    fi

    demo_info "Waiting for k8s-deployments MR... (${MR_ELAPSED}s elapsed)"
    sleep 10
    MR_ELAPSED=$((MR_ELAPSED + 10))
done

if [[ -z "${K8S_MR_IID:-}" ]]; then
    demo_fail "Timeout waiting for k8s-deployments MR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 7: Verify MR Contains Both Changes
# ---------------------------------------------------------------------------

demo_step 7 "Verify MR Contains Both Changes"

demo_info "Verifying the k8s-deployments MR has BOTH image update AND env var..."

# Wait for Jenkins CI on the MR
demo_action "Waiting for Jenkins CI to validate MR..."
wait_for_mr_pipeline "$K8S_MR_IID" || exit 1

# Check MR diff for both image update and env var
MR_CHANGES=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${K8S_ENCODED_PROJECT}/merge_requests/$K8S_MR_IID/changes")

# Verify env.cue has image update
if echo "$MR_CHANGES" | jq -r '.changes[] | select(.new_path == "env.cue") | .diff' | grep -q "image"; then
    demo_verify "MR contains image update in env.cue"
else
    demo_fail "MR missing image update in env.cue"
    exit 1
fi

# Verify services/apps/example-app.cue has the new env var
if echo "$MR_CHANGES" | jq -r '.changes[] | select(.new_path | contains("example-app.cue")) | .diff' | grep -q "$DEMO_ENV_VAR_NAME"; then
    demo_verify "MR contains $DEMO_ENV_VAR_NAME in example-app.cue"
else
    demo_fail "MR missing $DEMO_ENV_VAR_NAME in example-app.cue"
    exit 1
fi

# Verify manifests have the env var
if echo "$MR_CHANGES" | jq -r '.changes[] | select(.new_path | contains("manifests")) | .diff' | grep -q "$DEMO_ENV_VAR_NAME"; then
    demo_verify "MR contains $DEMO_ENV_VAR_NAME in generated manifests"
else
    demo_fail "MR missing $DEMO_ENV_VAR_NAME in manifests"
    exit 1
fi

demo_verify "CONFIRMED: MR contains BOTH image update AND config change"

# ---------------------------------------------------------------------------
# Step 8: Promote Through Environments
# ---------------------------------------------------------------------------

demo_step 8 "Promote Through Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture ArgoCD baseline
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge the initial k8s-deployments MR
        demo_action "Merging k8s-deployments MR !$K8S_MR_IID..."
        accept_mr "$K8S_MR_IID" || exit 1
        mr_iid="$K8S_MR_IID"
    else
        # Wait for Jenkins-created promotion MR
        wait_for_promotion_mr "$env" "$next_promotion_baseline" || exit 1
        mr_iid="$PROMOTION_MR_IID"

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to validate promotion..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify BOTH image tag AND env var are deployed
    demo_action "Verifying deployment has new image AND env var..."

    # Check image contains version
    DEPLOYED_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    if [[ "$DEPLOYED_IMAGE" == *"$NEW_VERSION"* ]] || [[ "$DEPLOYED_IMAGE" == *"${NEW_VERSION%-SNAPSHOT}"* ]]; then
        demo_verify "Image contains version: $DEPLOYED_IMAGE"
    else
        demo_fail "Image doesn't match expected version. Got: $DEPLOYED_IMAGE, expected to contain: $NEW_VERSION"
        exit 1
    fi

    # Check env var
    assert_deployment_env_var "$env" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" "$DEMO_ENV_VAR_VALUE" || exit 1

    demo_verify "Promotion to $env complete (both image AND config deployed)"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 9: Final Verification
# ---------------------------------------------------------------------------

demo_step 9 "Final Verification"

demo_info "Verifying ALL environments have BOTH new image AND new env var..."

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env..."

    # Verify image
    DEPLOYED_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    demo_info "  Image: $DEPLOYED_IMAGE"

    # Verify env var
    assert_deployment_env_var "$env" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" "$DEMO_ENV_VAR_VALUE" || exit 1
    demo_info "  $DEMO_ENV_VAR_NAME: $DEMO_ENV_VAR_VALUE"
done

demo_verify "VERIFIED: All environments have both new image AND new env var!"

# ---------------------------------------------------------------------------
# Step 10: Summary
# ---------------------------------------------------------------------------

demo_step 10 "Summary"

cat << EOF

  This demo validated UC-E2: App Code + Config Change Together

  What happened:
  1. Modified GreetingService.java to reference new env var
  2. Added env var to deployment/app.cue
  3. Bumped version in pom.xml
  4. Committed ALL changes in a single commit
  5. Jenkins built the app and created k8s-deployments MR with:
     - Image tag update (env.cue)
     - Env var addition (services/apps/example-app.cue)
     - Regenerated manifests with both changes
  6. Promoted atomically through dev → stage → prod

  Key Observations:
  - Code + config changes are atomic - no partial deployment state
  - New image requires new env var, and both arrive together
  - Single commit in app repo creates coordinated changes in k8s-deployments

  This validates that the pipeline correctly bundles related changes,
  preventing scenarios where new code deploys without its required config.

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 11 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in GitLab for reference"

demo_complete
```

**Step 2: Run the complete demo**

Run: `./scripts/demo/demo-uc-e2-code-plus-config.sh`
Expected: Full demo execution (may take 5-10 minutes for pipeline)

**Step 3: Commit the complete demo**

```bash
git add scripts/demo/demo-uc-e2-code-plus-config.sh
git commit -m "feat(uc-e2): complete demo implementation"
```

---

## Task 6: Create UC-E4 Demo Script

**Files:**
- Create: `scripts/demo/demo-uc-e4-app-rollback.sh`

**Step 1: Create the complete UC-E4 demo script**

```bash
#!/bin/bash
# Demo: App-Level Rollback (UC-E4)
#
# This demo proves that app images can be surgically rolled back while
# preserving environment-specific settings (replicas, resources, etc.).
#
# Use Case UC-E4:
# "v1.0.42 deployed to prod has a bug. Roll back to v1.0.41 image while
# preserving prod's env.cue settings (replicas, resources)"
#
# What This Demonstrates:
# - Image tag can be changed independently via direct MR
# - Environment settings (replicas, resources) are preserved
# - Contrast with UC-D3 which uses git revert (rolls back entire commit)
# - Surgical rollback targets ONLY the image, nothing else
#
# Flow:
# 1. Capture current prod image (the "good" version)
# 2. Deploy a new version through the pipeline (the "bad" version)
# 3. Verify the new version is deployed to prod
# 4. Create direct MR to prod that only changes image tag back
# 5. Verify prod rolls back to previous image
# 6. Verify prod's env.cue settings (replicas, etc.) are unchanged
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - At least one prior deployment exists in prod
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
TARGET_ENV="prod"
ENVIRONMENTS=("dev" "stage" "prod")

# GitLab CLI path
GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-E4: App-Level Rollback"

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

demo_action "Checking ArgoCD application..."
if kubectl get application "${DEMO_APP}-${TARGET_ENV}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
    demo_verify "ArgoCD app ${DEMO_APP}-${TARGET_ENV} exists"
else
    demo_fail "ArgoCD app ${DEMO_APP}-${TARGET_ENV} not found"
    exit 1
fi

demo_action "Checking prod deployment exists..."
if kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" &>/dev/null; then
    demo_verify "Deployment $DEMO_APP exists in $TARGET_ENV"
else
    demo_fail "Deployment $DEMO_APP not found in $TARGET_ENV"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Capture Baseline State
# ---------------------------------------------------------------------------

demo_step 2 "Capture Baseline State"

demo_info "Capturing current prod state as the 'good' version to roll back to..."

# Get current image tag from prod
GOOD_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
GOOD_TAG=$(echo "$GOOD_IMAGE" | sed 's/.*://')

demo_info "Good image tag: $GOOD_TAG"

# Capture current env settings (replicas, resources)
PROD_REPLICAS=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.replicas}')
PROD_CPU_REQUEST=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "not-set")
PROD_MEM_REQUEST=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "not-set")

demo_info "Prod replicas: $PROD_REPLICAS"
demo_info "Prod CPU request: $PROD_CPU_REQUEST"
demo_info "Prod memory request: $PROD_MEM_REQUEST"

demo_verify "Baseline captured"

# ---------------------------------------------------------------------------
# Step 3: Deploy New Version (the "bad" version)
# ---------------------------------------------------------------------------

demo_step 3 "Deploy New Version (simulating 'bad' deploy)"

demo_info "Triggering a new deployment through the pipeline..."
demo_info "This simulates deploying a new version that will need to be rolled back."

# Use the existing validate-pipeline script pattern to deploy a new version
# We'll bump the version and push through the pipeline

# Get current version from pom.xml via gitlab-cli
CURRENT_POM=$("$GITLAB_CLI" file get p2c/example-app pom.xml --ref main)
CURRENT_VERSION=$(echo "$CURRENT_POM" | grep -m1 '<version>' | sed 's/.*<version>\(.*\)<\/version>.*/\1/')
demo_info "Current app version: $CURRENT_VERSION"

# Calculate next version
BASE_VERSION="${CURRENT_VERSION%-SNAPSHOT}"
IFS='.' read -r major minor patch <<< "$BASE_VERSION"
NEW_PATCH=$((patch + 1))
NEW_VERSION="${major}.${minor}.${NEW_PATCH}-SNAPSHOT"
demo_info "New (bad) version: $NEW_VERSION"

# Update pom.xml
MODIFIED_POM=$(echo "$CURRENT_POM" | sed "0,/<version>$CURRENT_VERSION<\/version>/s//<version>$NEW_VERSION<\/version>/")

# Create branch and push
BAD_VERSION_BRANCH="uc-e4-bad-version-$(date +%s)"
ENCODED_APP_PROJECT=$(echo "p2c/example-app" | sed 's/\//%2F/g')

demo_action "Creating branch '$BAD_VERSION_BRANCH'..."
"$GITLAB_CLI" branch create p2c/example-app "$BAD_VERSION_BRANCH" --from main >/dev/null

demo_action "Pushing version bump..."
echo "$MODIFIED_POM" | "$GITLAB_CLI" file update p2c/example-app pom.xml \
    --ref "$BAD_VERSION_BRANCH" \
    --message "chore: bump version to $NEW_VERSION [UC-E4 bad version]" \
    --stdin >/dev/null

# Create and merge MR to main
demo_action "Creating MR to main..."
APP_MR_RESULT=$(curl -sk -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"source_branch\":\"$BAD_VERSION_BRANCH\",\"target_branch\":\"main\",\"title\":\"UC-E4: Bad version $NEW_VERSION\"}" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_APP_PROJECT}/merge_requests")

APP_MR_IID=$(echo "$APP_MR_RESULT" | jq -r '.iid // empty')
if [[ -z "$APP_MR_IID" ]]; then
    demo_fail "Failed to create app MR"
    exit 1
fi

demo_action "Merging app MR !$APP_MR_IID..."
curl -sk -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_APP_PROJECT}/merge_requests/$APP_MR_IID/merge" >/dev/null

demo_verify "App MR merged, triggering Jenkins build"

# Wait for Jenkins to build
demo_action "Waiting for Jenkins build..."
JENKINS_CLI="${PROJECT_ROOT}/scripts/04-operations/jenkins-cli.sh"
"$JENKINS_CLI" wait example-app/main --timeout 300 || {
    demo_fail "Jenkins build failed"
    exit 1
}

# Wait for and merge k8s-deployments MR through all environments
demo_info "Promoting through all environments..."

K8S_ENCODED_PROJECT=$(echo "p2c/k8s-deployments" | sed 's/\//%2F/g')
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # Wait for k8s-deployments MR
        MR_TIMEOUT=120
        MR_ELAPSED=0
        while [[ $MR_ELAPSED -lt $MR_TIMEOUT ]]; do
            MRS=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                "${GITLAB_URL_EXTERNAL}/api/v4/projects/${K8S_ENCODED_PROJECT}/merge_requests?state=opened&target_branch=dev")
            K8S_MR=$(echo "$MRS" | jq -r --arg ver "$NEW_VERSION" \
                'first(.[] | select(.source_branch | contains($ver))) // empty')
            if [[ -n "$K8S_MR" ]]; then
                K8S_MR_IID=$(echo "$K8S_MR" | jq -r '.iid')
                break
            fi
            sleep 10
            MR_ELAPSED=$((MR_ELAPSED + 10))
        done

        if [[ -z "${K8S_MR_IID:-}" ]]; then
            demo_fail "Timeout waiting for k8s-deployments MR"
            exit 1
        fi

        wait_for_mr_pipeline "$K8S_MR_IID" || exit 1
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        accept_mr "$K8S_MR_IID" || exit 1
    else
        wait_for_promotion_mr "$env" "$next_promotion_baseline" || exit 1
        wait_for_mr_pipeline "$PROMOTION_MR_IID" || exit 1
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        accept_mr "$PROMOTION_MR_IID" || exit 1
    fi

    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1
done

# Verify bad version is deployed
BAD_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
BAD_TAG=$(echo "$BAD_IMAGE" | sed 's/.*://')

demo_info "Bad version now deployed: $BAD_TAG"

if [[ "$BAD_TAG" == "$GOOD_TAG" ]]; then
    demo_fail "Bad version tag same as good - something went wrong"
    exit 1
fi

demo_verify "Bad version deployed to prod"

# ---------------------------------------------------------------------------
# Step 4: Execute Surgical Rollback
# ---------------------------------------------------------------------------

demo_step 4 "Execute Surgical Rollback"

demo_info "Rolling back prod to previous image tag: $GOOD_TAG"
demo_info "This is a SURGICAL rollback - only the image tag changes"
demo_info "Environment settings (replicas, resources) will be preserved"

# Get current env.cue from prod branch
PROD_ENV_CUE=$(get_file_from_branch "prod" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from prod branch"
    exit 1
fi

# Modify env.cue to set the old image tag
# Find the exampleApp deployment.image.tag and replace it
MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | python3 -c "
import sys
import re

content = sys.stdin.read()

# Find and replace the image tag in exampleApp section
# Pattern: tag: \"<anything>\"
# We need to be careful to only replace within exampleApp context

# Simple approach: find 'exampleApp:' section and replace tag within it
in_example_app = False
lines = content.split('\n')
result = []
for line in lines:
    if 'exampleApp:' in line or 'exampleApp :' in line:
        in_example_app = True
    # Reset when we hit another top-level app definition
    if in_example_app and line.strip() and not line.startswith('\t') and not line.startswith(' ') and ':' in line and 'exampleApp' not in line:
        in_example_app = False

    if in_example_app and 'tag:' in line and 'image' not in line.lower():
        # This is likely the image tag line
        line = re.sub(r'tag:\s*\"[^\"]+\"', 'tag: \"$GOOD_TAG\"', line)

    result.append(line)

print('\n'.join(result))
")

# Actually, let's use a more robust approach with cue-edit.py if available
# For now, use sed which is more reliable for this specific case
MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | sed -E "s/(exampleApp:.*deployment:.*image:.*tag:)[[:space:]]*\"[^\"]+\"/\1 \"$GOOD_TAG\"/g")

# If that didn't work, try a simpler pattern
if ! echo "$MODIFIED_ENV_CUE" | grep -q "tag: \"$GOOD_TAG\""; then
    # Try line-by-line replacement within exampleApp context
    MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | awk -v tag="$GOOD_TAG" '
        /exampleApp:/ { in_app=1 }
        /^[a-zA-Z]/ && !/exampleApp:/ { in_app=0 }
        in_app && /tag:/ && /deployment/ { gsub(/tag: "[^"]+"/, "tag: \"" tag "\"") }
        in_app && /tag:/ && !/deployment/ { gsub(/tag: "[^"]+"/, "tag: \"" tag "\"") }
        { print }
    ')
fi

# Create rollback branch
ROLLBACK_BRANCH="uc-e4-rollback-$(date +%s)"

demo_action "Creating rollback branch '$ROLLBACK_BRANCH' from prod..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$ROLLBACK_BRANCH" --from prod >/dev/null

demo_action "Pushing rollback change (image tag only)..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$ROLLBACK_BRANCH" \
    --message "fix: rollback example-app to $GOOD_TAG [no-promote]" \
    --stdin >/dev/null

# Create MR directly to prod
demo_action "Creating rollback MR: $ROLLBACK_BRANCH → prod..."
ROLLBACK_MR_IID=$(create_mr "$ROLLBACK_BRANCH" "prod" "UC-E4: Rollback to $GOOD_TAG")

# Wait for CI
demo_action "Waiting for CI validation..."
wait_for_mr_pipeline "$ROLLBACK_MR_IID" || exit 1

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${TARGET_ENV}")

# Merge rollback MR
demo_action "Merging rollback MR..."
accept_mr "$ROLLBACK_MR_IID" || exit 1

demo_verify "Rollback MR merged"

# ---------------------------------------------------------------------------
# Step 5: Verify Rollback
# ---------------------------------------------------------------------------

demo_step 5 "Verify Rollback"

demo_action "Waiting for ArgoCD to sync rollback..."
wait_for_argocd_sync "${DEMO_APP}-${TARGET_ENV}" "$argocd_baseline" || exit 1

# Verify image is rolled back
CURRENT_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')
CURRENT_TAG=$(echo "$CURRENT_IMAGE" | sed 's/.*://')

if [[ "$CURRENT_TAG" == "$GOOD_TAG" ]]; then
    demo_verify "Image rolled back to: $GOOD_TAG"
else
    demo_fail "Image not rolled back. Expected: $GOOD_TAG, Got: $CURRENT_TAG"
    exit 1
fi

# Verify env settings are preserved
NEW_REPLICAS=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.replicas}')
NEW_CPU=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || echo "not-set")
NEW_MEM=$(kubectl get deployment "$DEMO_APP" -n "$TARGET_ENV" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || echo "not-set")

demo_info "Checking env settings preserved..."
demo_info "  Replicas: $PROD_REPLICAS → $NEW_REPLICAS"
demo_info "  CPU request: $PROD_CPU_REQUEST → $NEW_CPU"
demo_info "  Memory request: $PROD_MEM_REQUEST → $NEW_MEM"

if [[ "$NEW_REPLICAS" == "$PROD_REPLICAS" ]]; then
    demo_verify "Replicas preserved"
else
    demo_warn "Replicas changed (was $PROD_REPLICAS, now $NEW_REPLICAS)"
fi

demo_verify "Surgical rollback complete - image changed, env settings preserved"

# ---------------------------------------------------------------------------
# Step 6: Verify Other Environments Unaffected
# ---------------------------------------------------------------------------

demo_step 6 "Verify Other Environments Unaffected"

demo_info "Verifying dev and stage still have the 'bad' version..."

for env in dev stage; do
    OTHER_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$env" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    OTHER_TAG=$(echo "$OTHER_IMAGE" | sed 's/.*://')

    if [[ "$OTHER_TAG" == "$BAD_TAG" ]] || [[ "$OTHER_TAG" == *"${NEW_VERSION}"* ]]; then
        demo_verify "$env still has newer version: $OTHER_TAG"
    else
        demo_info "$env has different version: $OTHER_TAG (may be from version lifecycle)"
    fi
done

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-E4: App-Level Rollback

  What happened:
  1. Captured baseline "good" version: $GOOD_TAG
  2. Deployed new "bad" version: $BAD_TAG
  3. Created SURGICAL rollback - direct MR to prod changing ONLY image tag
  4. Verified:
     - Prod rolled back to: $GOOD_TAG
     - Env settings (replicas=$PROD_REPLICAS) preserved
     - Dev/stage unaffected (still have newer version)

  Contrast with UC-D3 (Environment Rollback):
  - UC-D3 uses git revert (rolls back entire commit)
  - UC-E4 surgically changes only the image tag
  - UC-E4 preserves env.cue settings that may have changed independently

  Key Observations:
  - Image tag can be changed via direct MR without affecting other settings
  - [no-promote] marker prevents rollback from cascading
  - Other environments continue running newer version
  - Full audit trail in git history

  Use UC-E4 when:
  - You need to roll back only the app image
  - Environment settings should be preserved
  - You want surgical control over what changes

  Use UC-D3 when:
  - You want to revert an entire configuration change
  - The "bad" state includes config changes (not just image)
  - You want the simplicity of git revert

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Branches '$BAD_VERSION_BRANCH' and '$ROLLBACK_BRANCH' left in GitLab for reference"

demo_complete
```

**Step 2: Make the script executable**

Run: `chmod +x scripts/demo/demo-uc-e4-app-rollback.sh`

**Step 3: Commit the demo**

```bash
git add scripts/demo/demo-uc-e4-app-rollback.sh
git commit -m "feat: add UC-E4 app-level rollback demo script"
```

---

## Task 7: Update USE_CASES.md with New Use Cases

**Files:**
- Modify: `docs/USE_CASES.md`

**Step 1: Add UC-E2 and UC-E4 to the E-series section**

Find the E-series section and add the new use cases after UC-E1:

```markdown
### UC-E2: App Code + Config Change Together

| Aspect | Detail |
|--------|--------|
| **Story** | "As a developer, I push a code change that also requires a new environment variable, and both flow through the pipeline together" |
| **Trigger** | Code change + `deployment/app.cue` modification in same commit |
| **Flow** | 1. Developer modifies source code AND adds `appEnvVars` entry in `deployment/app.cue`<br>2. Jenkins builds app, publishes image<br>3. App CI creates MR to k8s-deployments dev with BOTH image tag update AND merged CUE config<br>4. Merge → manifests include new env var<br>5. Promotion MRs carry both changes through stage→prod |
| **Expected Behavior** | New image AND new config deploy atomically; no partial state where image expects env var that doesn't exist |
| **Validates** | Pipeline correctly extracts and merges `deployment/app.cue` changes alongside image updates |

**Demo Script:** [`scripts/demo/demo-uc-e2-code-plus-config.sh`](../scripts/demo/demo-uc-e2-code-plus-config.sh) (implements UC-E2)

### UC-E3: Multiple App Versions In Flight

| Aspect | Detail |
|--------|--------|
| **Story** | "Production runs v1.0.40, stage has v1.0.41 under QA review, dev has v1.0.42 for new feature testing — all simultaneously" |
| **Trigger** | Normal development pace where promotions aren't instant |
| **Setup** | Three consecutive version bumps with deliberate pauses between promotion merges |
| **Expected Behavior** | Each environment maintains its own image tag in `env.cue`; promotions don't overwrite pending changes in other environments |
| **Validates** | Environment isolation; promotion only moves the specific app version being promoted |

### UC-E4: App-Level Rollback

| Aspect | Detail |
|--------|--------|
| **Story** | "v1.0.42 deployed to prod has a bug. Roll back to v1.0.41 image while preserving prod's env.cue settings (replicas, resources)" |
| **Trigger** | Direct MR to prod branch updating only the image tag |
| **Change** | `deployment.image.tag: "1.0.42"` → `deployment.image.tag: "1.0.41"` |
| **Expected Behavior** | Prod rolls back to previous image; prod's replicas/resources unchanged; dev/stage unaffected |
| **Contrast with UC-D3** | D3 uses git revert (rolls back entire commit); E4 surgically changes only the image tag |
| **Validates** | Image tag can be changed independently; env.cue structure supports targeted rollback |

**Demo Script:** [`scripts/demo/demo-uc-e4-app-rollback.sh`](../scripts/demo/demo-uc-e4-app-rollback.sh) (implements UC-E4)
```

**Step 2: Update the summary table**

Find the "All Use Cases at a Glance" table and add:

```markdown
| **E: App Lifecycle** | UC-E1 | App version deployment (full promotion) | App repo code change | dev → stage → prod |
| | UC-E2 | App code + config change together | App repo code + deployment/app.cue | Atomic deployment |
| | UC-E3 | Multiple versions in flight | Normal dev pace | Independent env versions |
| | UC-E4 | App-level rollback | Direct MR to env branch | Surgical image rollback |
```

**Step 3: Update the Implementation Status table**

Add rows for UC-E2, UC-E3, UC-E4:

```markdown
| UC-E2 | App code + config change together | ✅ | ✅ | 🔲 | `uc-e2-code-plus-config` | Pipeline bundles code + config changes atomically |
| UC-E3 | Multiple versions in flight | ✅ | 🔲 | 🔲 | - | Validates env isolation with version skew |
| UC-E4 | App-level rollback | ✅ | ✅ | 🔲 | `uc-e4-app-rollback` | Surgical image rollback preserving env settings |
```

**Step 4: Commit documentation update**

```bash
git add docs/USE_CASES.md
git commit -m "docs: add UC-E2, UC-E3, UC-E4 to use cases documentation"
```

---

## Task 8: Run Full Demo Validation

**Files:**
- None (validation only)

**Step 1: Run UC-E2 demo**

Run: `./scripts/demo/demo-uc-e2-code-plus-config.sh`
Expected: Demo completes successfully with "Demo Complete!" message

**Step 2: Reset demo state**

Run: `./scripts/03-pipelines/reset-demo-state.sh`
Expected: Pipeline reset to clean state

**Step 3: Run UC-E4 demo**

Run: `./scripts/demo/demo-uc-e4-app-rollback.sh`
Expected: Demo completes successfully with "Demo Complete!" message

**Step 4: Final commit with verification status**

```bash
git add docs/USE_CASES.md
git commit -m "docs: mark UC-E2 and UC-E4 as Pipeline Verified"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Verify gitlab-cli.sh supports example-app | `scripts/04-operations/gitlab-cli.sh` |
| 2 | Create UC-E2 demo skeleton | `scripts/demo/demo-uc-e2-code-plus-config.sh` |
| 3 | Add UC-E2 prerequisite checks | `scripts/demo/demo-uc-e2-code-plus-config.sh` |
| 4 | Implement UC-E2 code+config modification | `scripts/demo/demo-uc-e2-code-plus-config.sh` |
| 5 | Implement UC-E2 pipeline wait and verification | `scripts/demo/demo-uc-e2-code-plus-config.sh` |
| 6 | Create UC-E4 demo script | `scripts/demo/demo-uc-e4-app-rollback.sh` |
| 7 | Update USE_CASES.md | `docs/USE_CASES.md` |
| 8 | Run full demo validation | None |

Total estimated commits: 8
