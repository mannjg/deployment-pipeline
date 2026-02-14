#!/usr/bin/env bash
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
    if kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null | grep -q "$DEMO_ENV_VAR_NAME"; then
        demo_warn "Env var '$DEMO_ENV_VAR_NAME' already exists in $env - demo may have stale state"
        demo_info "Run reset-demo-state.sh to clean up"
        exit 1
    fi
done

demo_verify "Baseline confirmed: '$DEMO_ENV_VAR_NAME' absent from all environments"

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

# Use feature/ prefix to match Jenkins branch discovery pattern
FEATURE_BRANCH="feature/uc-e2-code-config-$(date +%s)"

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

# ---------------------------------------------------------------------------
# Step 5: Wait for Example-App CI
# ---------------------------------------------------------------------------

demo_step 5 "Wait for Example-App CI"

demo_info "Waiting for Jenkins to build and test the MR branch..."
demo_info "Per WORKFLOWS.md: MR creation triggers Unit + Integration tests"

# Trigger Jenkins scan to discover the new feature branch
demo_action "Triggering Jenkins branch scan for example-app..."
trigger_jenkins_scan "example-app"

# Wait for MR pipeline to complete (tests on feature branch)
demo_action "Waiting for MR pipeline (tests) to complete..."

MR_PIPELINE_TIMEOUT=180
MR_ELAPSED=0
while [[ $MR_ELAPSED -lt $MR_PIPELINE_TIMEOUT ]]; do
    MR_INFO=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_PROJECT}/merge_requests/$APP_MR_IID")

    PIPELINE_STATUS=$(echo "$MR_INFO" | jq -r '.head_pipeline.status // empty')

    case "$PIPELINE_STATUS" in
        success)
            demo_verify "MR pipeline passed (tests successful)"
            break
            ;;
        failed)
            demo_fail "MR pipeline failed - tests did not pass"
            exit 1
            ;;
        running|pending|created)
            demo_info "Pipeline: $PIPELINE_STATUS (${MR_ELAPSED}s)"
            ;;
        *)
            # Re-trigger scan periodically if pipeline not started
            if [[ $((MR_ELAPSED % 30)) -eq 0 ]] && [[ $MR_ELAPSED -gt 0 ]]; then
                demo_info "Re-triggering Jenkins scan..."
                trigger_jenkins_scan "example-app" >/dev/null 2>&1
            fi
            demo_info "Waiting for pipeline to start... (${MR_ELAPSED}s)"
            ;;
    esac

    sleep 10
    MR_ELAPSED=$((MR_ELAPSED + 10))
done

if [[ $MR_ELAPSED -ge $MR_PIPELINE_TIMEOUT ]]; then
    demo_warn "Timeout waiting for MR pipeline - proceeding with merge"
    demo_info "(Jenkins may not be configured to build feature branches)"
fi

# Capture current timestamp BEFORE merge to wait for builds triggered AFTER this point
# Jenkins uses milliseconds for timestamps
PRE_MERGE_TIMESTAMP=$(($(date +%s) * 1000))

# Merge the example-app MR (simulate developer approval after tests pass)
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

# Wait for Jenkins to build main branch and create k8s-deployments MR
# IMPORTANT: Use --after to wait for a NEW build triggered by the merge,
# not just any existing completed build
demo_action "Waiting for Jenkins build on example-app/main (after merge)..."

JENKINS_CLI="${PROJECT_ROOT}/scripts/04-operations/jenkins-cli.sh"
"$JENKINS_CLI" wait example-app/main --timeout 300 --after "$PRE_MERGE_TIMESTAMP" || {
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

# Verify templates/apps/example-app.cue has the new env var
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
    DEPLOYED_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    if [[ "$DEPLOYED_IMAGE" == *"$NEW_VERSION"* ]] || [[ "$DEPLOYED_IMAGE" == *"${NEW_VERSION%-SNAPSHOT}"* ]]; then
        demo_verify "Image contains version: $DEPLOYED_IMAGE"
    else
        demo_fail "Image doesn't match expected version. Got: $DEPLOYED_IMAGE, expected to contain: $NEW_VERSION"
        exit 1
    fi

    # Check env var
    assert_deployment_env_var "$(get_namespace "$env")" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" "$DEMO_ENV_VAR_VALUE" || exit 1

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
    DEPLOYED_IMAGE=$(kubectl get deployment "$DEMO_APP" -n "$(get_namespace "$env")" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')
    demo_info "  Image: $DEPLOYED_IMAGE"

    # Verify env var
    assert_deployment_env_var "$(get_namespace "$env")" "$DEMO_APP" "$DEMO_ENV_VAR_NAME" "$DEMO_ENV_VAR_VALUE" || exit 1
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
     - Env var addition (templates/apps/example-app.cue)
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
