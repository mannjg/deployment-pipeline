# Version Lifecycle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement version lifecycle management (SNAPSHOT → RC → Release) ensuring the same binary is promoted through all environments with appropriate version tagging.

**Architecture:** New `promote-artifact.sh` script handles Maven re-deploy and Docker re-tag. Modified `createPromotionMR()` calls this script before creating the MR, updating env.cue with the new image tag. Validation added to `validate-pipeline.sh` to verify version progression.

**Tech Stack:** Bash, Maven (deploy:deploy-file), Docker CLI, Nexus REST API, Jenkins Groovy

---

### Task 1: Create promote-artifact.sh Script

**Files:**
- Create: `k8s-deployments/scripts/promote-artifact.sh`

**Step 1: Create script skeleton with argument parsing**

```bash
#!/bin/bash
# Promote artifacts from one environment version to another
# Re-deploys Maven JAR with new version, re-tags Docker image
#
# Usage:
#   ./scripts/promote-artifact.sh \
#     --source-env dev \
#     --target-env stage \
#     --app-name example-app \
#     --git-hash abc123

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Parse arguments
SOURCE_ENV=""
TARGET_ENV=""
APP_NAME=""
GIT_HASH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-env) SOURCE_ENV="$2"; shift 2 ;;
        --target-env) TARGET_ENV="$2"; shift 2 ;;
        --app-name) APP_NAME="$2"; shift 2 ;;
        --git-hash) GIT_HASH="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# Validate required arguments
[[ -z "$SOURCE_ENV" ]] && { log_error "--source-env required"; exit 1; }
[[ -z "$TARGET_ENV" ]] && { log_error "--target-env required"; exit 1; }
[[ -z "$APP_NAME" ]] && { log_error "--app-name required"; exit 1; }
[[ -z "$GIT_HASH" ]] && { log_error "--git-hash required"; exit 1; }

# Configuration (from environment or defaults)
NEXUS_URL="${NEXUS_URL:-http://nexus.nexus.svc.cluster.local:8081}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-nexus.nexus.svc.cluster.local:5000}"
MAVEN_GROUP_ID="${MAVEN_GROUP_ID:-com.example}"
```

**Step 2: Add version parsing functions**

```bash
# Extract base version from image tag (e.g., "1.0.0" from "1.0.0-SNAPSHOT-abc123")
extract_base_version() {
    local image_tag="$1"
    # Remove git hash suffix (last component after -)
    # Remove SNAPSHOT or rcN suffix
    echo "$image_tag" | sed -E 's/-[a-f0-9]{6,}$//' | sed -E 's/-(SNAPSHOT|rc[0-9]+)$//'
}

# Extract git hash from image tag (e.g., "abc123" from "1.0.0-SNAPSHOT-abc123")
extract_git_hash() {
    local image_tag="$1"
    echo "$image_tag" | grep -oE '[a-f0-9]{6,}$' || echo ""
}

# Get current image tag from env.cue for a given environment
get_current_image_tag() {
    local env="$1"
    local env_cue_content

    # Fetch env.cue from GitLab for the environment branch
    local encoded_project=$(echo "${GITLAB_PROJECT:-p2c/k8s-deployments}" | sed 's/\//%2F/g')
    env_cue_content=$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${encoded_project}/repository/files/env.cue?ref=${env}" 2>/dev/null | \
        jq -r '.content' | base64 -d)

    # Extract image tag from env.cue
    echo "$env_cue_content" | grep -oP 'image:\s*"\K[^"]+' | head -1
}
```

**Step 3: Add Nexus query functions**

```bash
# Check if artifact exists in Nexus
nexus_artifact_exists() {
    local version="$1"
    local repository="$2"

    local search_url="${NEXUS_URL}/service/rest/v1/search?repository=${repository}&group=${MAVEN_GROUP_ID}&name=${APP_NAME}&version=${version}"
    local result=$(curl -sf "$search_url" 2>/dev/null | jq -r '.items | length')

    [[ "$result" -gt 0 ]]
}

# Get next RC number for a base version
get_next_rc_number() {
    local base_version="$1"

    # Query Nexus for existing RCs of this version
    local search_url="${NEXUS_URL}/service/rest/v1/search?repository=maven-releases&group=${MAVEN_GROUP_ID}&name=${APP_NAME}&version=${base_version}-rc*"
    local existing_rcs=$(curl -sf "$search_url" 2>/dev/null | jq -r '.items[].version' | grep -oP 'rc\K[0-9]+' | sort -n | tail -1)

    if [[ -z "$existing_rcs" ]]; then
        echo "1"
    else
        echo "$((existing_rcs + 1))"
    fi
}

# Download JAR from Nexus
download_jar() {
    local version="$1"
    local repository="$2"
    local output_file="$3"

    local download_url="${NEXUS_URL}/repository/${repository}/${MAVEN_GROUP_ID//./\/}/${APP_NAME}/${version}/${APP_NAME}-${version}.jar"

    log_info "Downloading JAR from: $download_url"
    if ! curl -sf -o "$output_file" "$download_url"; then
        log_error "Failed to download JAR: $download_url"
        return 1
    fi
    log_info "Downloaded to: $output_file"
}

# Deploy JAR to Nexus with new version
deploy_jar() {
    local jar_file="$1"
    local new_version="$2"
    local repository="$3"

    log_info "Deploying JAR as version $new_version to $repository"

    mvn deploy:deploy-file \
        -DgroupId="${MAVEN_GROUP_ID}" \
        -DartifactId="${APP_NAME}" \
        -Dversion="${new_version}" \
        -Dpackaging=jar \
        -Dfile="$jar_file" \
        -DrepositoryId=nexus \
        -Durl="${NEXUS_URL}/repository/${repository}" \
        -DgeneratePom=true \
        -q

    log_info "Successfully deployed ${APP_NAME}:${new_version}"
}
```

**Step 4: Add Docker re-tagging functions**

```bash
# Re-tag and push Docker image
retag_docker_image() {
    local source_tag="$1"
    local target_tag="$2"

    local source_image="${DOCKER_REGISTRY}/p2c/${APP_NAME}:${source_tag}"
    local target_image="${DOCKER_REGISTRY}/p2c/${APP_NAME}:${target_tag}"

    log_info "Re-tagging Docker image: $source_tag -> $target_tag"

    # Pull source image
    if ! docker pull "$source_image" 2>/dev/null; then
        log_error "Failed to pull source image: $source_image"
        return 1
    fi

    # Tag with new version
    docker tag "$source_image" "$target_image"

    # Push new tag
    if ! docker push "$target_image" 2>/dev/null; then
        log_error "Failed to push target image: $target_image"
        return 1
    fi

    log_info "Successfully re-tagged and pushed: $target_image"
}
```

**Step 5: Add main promotion logic**

```bash
# Main promotion logic
main() {
    log_info "=== Artifact Promotion: $SOURCE_ENV -> $TARGET_ENV ==="
    log_info "App: $APP_NAME, Git Hash: $GIT_HASH"

    # Get source image tag
    local source_image_tag=$(get_current_image_tag "$SOURCE_ENV")
    if [[ -z "$source_image_tag" ]]; then
        log_error "Could not determine source image tag from $SOURCE_ENV env.cue"
        exit 1
    fi
    log_info "Source image tag: $source_image_tag"

    # Extract base version
    local base_version=$(extract_base_version "$source_image_tag")
    log_info "Base version: $base_version"

    # Determine source and target versions
    local source_version=""
    local target_version=""
    local target_image_tag=""
    local source_repo=""
    local target_repo="maven-releases"

    case "$SOURCE_ENV-$TARGET_ENV" in
        dev-stage)
            source_version="${base_version}-SNAPSHOT"
            source_repo="maven-snapshots"

            # Check if same git hash already promoted (skip if so)
            local current_stage_tag=$(get_current_image_tag "stage" 2>/dev/null || echo "")
            local current_stage_hash=$(extract_git_hash "$current_stage_tag")

            if [[ "$current_stage_hash" == "$GIT_HASH" ]]; then
                log_info "Same git hash already in stage - skipping promotion"
                echo "$current_stage_tag"
                exit 0
            fi

            local rc_num=$(get_next_rc_number "$base_version")
            target_version="${base_version}-rc${rc_num}"
            target_image_tag="${target_version}-${GIT_HASH}"
            ;;
        stage-prod)
            # Get RC version from stage
            source_version=$(echo "$source_image_tag" | sed -E "s/-${GIT_HASH}$//")
            source_repo="maven-releases"
            target_version="${base_version}"
            target_image_tag="${target_version}-${GIT_HASH}"

            # Check if release already exists
            if nexus_artifact_exists "$target_version" "maven-releases"; then
                log_error "Release version $target_version already exists in Nexus"
                log_error "Cannot promote to prod with existing release version."
                log_error "Bump the base version in pom.xml (e.g., ${base_version}-SNAPSHOT -> next version)"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported promotion path: $SOURCE_ENV -> $TARGET_ENV"
            exit 1
            ;;
    esac

    log_info "Source version: $source_version ($source_repo)"
    log_info "Target version: $target_version ($target_repo)"
    log_info "Target image tag: $target_image_tag"

    # Create temp directory for JAR
    local tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    # Download source JAR
    local jar_file="$tmp_dir/${APP_NAME}.jar"
    download_jar "$source_version" "$source_repo" "$jar_file"

    # Deploy with new version
    deploy_jar "$jar_file" "$target_version" "$target_repo"

    # Re-tag Docker image
    local source_docker_tag="${source_version}-${GIT_HASH}"
    retag_docker_image "$source_docker_tag" "$target_image_tag"

    log_info "=== Promotion Complete ==="
    log_info "New image tag: $target_image_tag"

    # Output the new image tag (for caller to capture)
    echo "$target_image_tag"
}

main
```

**Step 6: Make script executable and test argument parsing**

Run:
```bash
chmod +x k8s-deployments/scripts/promote-artifact.sh
./k8s-deployments/scripts/promote-artifact.sh --help 2>&1 || true
./k8s-deployments/scripts/promote-artifact.sh --source-env dev --target-env stage --app-name example-app --git-hash abc123 2>&1 | head -5
```

Expected: Script runs, shows "Unknown argument: --help" for first, shows initialization messages for second (will fail later without real Nexus)

**Step 7: Commit**

```bash
git add k8s-deployments/scripts/promote-artifact.sh
git commit -m "feat: add promote-artifact.sh for version lifecycle management

Handles SNAPSHOT → RC → Release version progression:
- Downloads JAR from source version in Nexus
- Re-deploys with new version coordinates
- Re-tags Docker image with new version
- Outputs new image tag for pipeline integration

Supports: dev→stage (SNAPSHOT→RC), stage→prod (RC→Release)"
```

---

### Task 2: Modify createPromotionMR() in Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile:257-374`

**Step 1: Add git hash capture before promotion**

In `createPromotionMR()`, after the credential setup and before the main shell block, add:

```groovy
// Get git hash from source environment's current image
def sourceImageTag = sh(
    script: """
        curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
            "${env.GITLAB_URL}/api/v4/projects/${encodedProject}/repository/files/env.cue?ref=${sourceEnv}" \
            2>/dev/null | jq -r '.content' | base64 -d | grep -oP 'image:\\s*"\\K[^"]+' | head -1
    """,
    returnStdout: true
).trim()

def gitHash = sh(
    script: "echo '${sourceImageTag}' | grep -oE '[a-f0-9]{6,}\$' || echo ''",
    returnStdout: true
).trim()

if (!gitHash) {
    echo "WARNING: Could not extract git hash from source image tag: ${sourceImageTag}"
    echo "Skipping artifact promotion"
    return
}

echo "Source image tag: ${sourceImageTag}"
echo "Git hash: ${gitHash}"
```

**Step 2: Call promote-artifact.sh and capture new image tag**

Add after git hash capture, before the main shell block:

```groovy
// Promote artifacts (Maven + Docker) and get new image tag
def newImageTag = sh(
    script: """
        ./scripts/promote-artifact.sh \
            --source-env ${sourceEnv} \
            --target-env ${targetEnv} \
            --app-name example-app \
            --git-hash ${gitHash} \
            | tail -1
    """,
    returnStdout: true
).trim()

if (!newImageTag || newImageTag.contains("ERROR")) {
    echo "Artifact promotion failed or returned no image tag"
    return
}

echo "New image tag for ${targetEnv}: ${newImageTag}"
```

**Step 3: Update env.cue with new image tag in the shell block**

In the existing shell block, after `promote-app-config.sh` but before `generate-manifests.sh`, add:

```bash
# Update image tag in env.cue with promoted version
NEW_IMAGE_TAG="${newImageTag}"
REGISTRY="${DOCKER_REGISTRY:-nexus.nexus.svc.cluster.local:5000}"
NEW_IMAGE="${REGISTRY}/p2c/example-app:${NEW_IMAGE_TAG}"

echo "Updating env.cue with new image: ${NEW_IMAGE}"

# Use sed to update the image field
sed -i "s|image:.*example-app:.*\"|image: \"${NEW_IMAGE}\"|" env.cue

# Verify the update
grep "image:" env.cue
```

**Step 4: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "feat: integrate version lifecycle into createPromotionMR()

- Extract git hash from source environment's image tag
- Call promote-artifact.sh to create RC/Release artifacts
- Update env.cue with new versioned image tag before manifest generation
- MR now shows exact version that will be deployed"
```

---

### Task 3: Add Version Assertion Helpers to assertions.sh

**Files:**
- Modify: `scripts/demo/lib/assertions.sh`

**Step 1: Add image tag pattern matching assertion**

Add after the existing `assert_image_contains` function (~line 332):

```bash
# Assert image tag matches a glob pattern
# Usage: assert_image_tag_matches <namespace> <deployment_name> <pattern> [description]
# Pattern examples: "*-SNAPSHOT-*", "*-rc[0-9]*-*", "!*-SNAPSHOT-*" (negation with !)
assert_image_tag_matches() {
    local namespace="$1"
    local deployment="$2"
    local pattern="$3"
    local description="${4:-Image tag matches pattern}"

    local actual=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    local tag=$(echo "$actual" | sed 's/.*://')

    local negate=false
    if [[ "$pattern" == !* ]]; then
        negate=true
        pattern="${pattern:1}"
    fi

    # Use bash pattern matching
    if [[ "$tag" == $pattern ]]; then
        if $negate; then
            demo_fail "$description: tag '$tag' should NOT match '$pattern'"
            return 1
        else
            demo_verify "$description: tag '$tag' matches '$pattern'"
            return 0
        fi
    else
        if $negate; then
            demo_verify "$description: tag '$tag' does not match '$pattern' (expected)"
            return 0
        else
            demo_fail "$description: tag '$tag' does not match '$pattern'"
            return 1
        fi
    fi
}
```

**Step 2: Add git hash extraction and comparison assertion**

```bash
# Extract git hash from image tag
# Usage: extract_git_hash_from_image <image_or_tag>
extract_git_hash_from_image() {
    local input="$1"
    # Extract last component that looks like a git hash (6+ hex chars)
    echo "$input" | grep -oE '[a-f0-9]{6,}$' || echo ""
}

# Assert all environments have the same git hash (same binary)
# Usage: assert_same_git_hash_across_envs <env1> <env2> [env3...]
assert_same_git_hash_across_envs() {
    local deployment="example-app"
    local first_hash=""
    local first_env=""

    for env in "$@"; do
        local image=$(kubectl get deployment "$deployment" -n "$env" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
        local hash=$(extract_git_hash_from_image "$image")

        if [[ -z "$hash" ]]; then
            demo_fail "Could not extract git hash from $env image: $image"
            return 1
        fi

        if [[ -z "$first_hash" ]]; then
            first_hash="$hash"
            first_env="$env"
        elif [[ "$hash" != "$first_hash" ]]; then
            demo_fail "Git hash mismatch: $first_env=$first_hash, $env=$hash"
            return 1
        fi
    done

    demo_verify "Same git hash ($first_hash) across all environments: $*"
    return 0
}
```

**Step 3: Add Nexus artifact existence assertion**

```bash
# Assert artifact exists in Nexus repository
# Usage: assert_nexus_artifact_exists <app_name> <version> <repository>
assert_nexus_artifact_exists() {
    local app_name="$1"
    local version="$2"
    local repository="$3"

    local nexus_url="${NEXUS_URL:-http://nexus.nexus.svc.cluster.local:8081}"
    local group_id="${MAVEN_GROUP_ID:-com.example}"

    local search_url="${nexus_url}/service/rest/v1/search?repository=${repository}&group=${group_id}&name=${app_name}&version=${version}"
    local result=$(curl -sf "$search_url" 2>/dev/null | jq -r '.items | length')

    if [[ "$result" -gt 0 ]]; then
        demo_verify "Nexus artifact exists: ${app_name}:${version} in ${repository}"
        return 0
    else
        demo_fail "Nexus artifact not found: ${app_name}:${version} in ${repository}"
        return 1
    fi
}
```

**Step 4: Commit**

```bash
git add scripts/demo/lib/assertions.sh
git commit -m "feat: add version lifecycle assertion helpers

- assert_image_tag_matches: glob pattern matching for image tags
- extract_git_hash_from_image: extract git hash suffix from tags
- assert_same_git_hash_across_envs: verify same binary across environments
- assert_nexus_artifact_exists: verify Maven artifacts in Nexus"
```

---

### Task 4: Add Version Lifecycle Validation to validate-pipeline.sh

**Files:**
- Modify: `scripts/test/validate-pipeline.sh`

**Step 1: Add verify_version_lifecycle function**

Add after the existing validation functions (before main execution):

```bash
# -----------------------------------------------------------------------------
# Version Lifecycle Validation
# -----------------------------------------------------------------------------
verify_version_lifecycle() {
    log_step "Verifying version lifecycle across environments..."

    local deployment="example-app"

    # Get image tags from each environment
    local dev_image=$(kubectl get deployment "$deployment" -n dev \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    local stage_image=$(kubectl get deployment "$deployment" -n stage \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    local prod_image=$(kubectl get deployment "$deployment" -n prod \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

    local dev_tag=$(echo "$dev_image" | sed 's/.*://')
    local stage_tag=$(echo "$stage_image" | sed 's/.*://')
    local prod_tag=$(echo "$prod_image" | sed 's/.*://')

    log_info "Dev tag:   $dev_tag"
    log_info "Stage tag: $stage_tag"
    log_info "Prod tag:  $prod_tag"

    # 1. Verify dev has SNAPSHOT version
    if [[ "$dev_tag" == *-SNAPSHOT-* ]]; then
        log_pass "Dev has SNAPSHOT version"
    else
        log_fail "Dev should have SNAPSHOT version, got: $dev_tag"
        return 1
    fi

    # 2. Verify stage has RC version
    if [[ "$stage_tag" == *-rc[0-9]*-* ]]; then
        log_pass "Stage has RC version"
    else
        log_fail "Stage should have RC version, got: $stage_tag"
        return 1
    fi

    # 3. Verify prod has release version (no SNAPSHOT, no RC)
    if [[ "$prod_tag" != *-SNAPSHOT-* ]] && [[ "$prod_tag" != *-rc[0-9]*-* ]]; then
        log_pass "Prod has release version (no SNAPSHOT, no RC)"
    else
        log_fail "Prod should have release version, got: $prod_tag"
        return 1
    fi

    # 4. Verify same git hash across all environments
    local dev_hash=$(echo "$dev_tag" | grep -oE '[a-f0-9]{6,}$' || echo "")
    local stage_hash=$(echo "$stage_tag" | grep -oE '[a-f0-9]{6,}$' || echo "")
    local prod_hash=$(echo "$prod_tag" | grep -oE '[a-f0-9]{6,}$' || echo "")

    if [[ "$dev_hash" == "$stage_hash" ]] && [[ "$stage_hash" == "$prod_hash" ]]; then
        log_pass "Same git hash ($dev_hash) across all environments"
    else
        log_fail "Git hash mismatch: dev=$dev_hash, stage=$stage_hash, prod=$prod_hash"
        return 1
    fi

    # 5. Extract versions for Nexus verification
    local base_version=$(echo "$dev_tag" | sed -E 's/-SNAPSHOT-[a-f0-9]+$//' | sed 's/-SNAPSHOT$//')
    local dev_version="${base_version}-SNAPSHOT"
    local stage_version=$(echo "$stage_tag" | sed -E "s/-${stage_hash}$//")
    local prod_version="${base_version}"

    log_info "Verifying Nexus artifacts..."
    log_info "  Dev version:   $dev_version (maven-snapshots)"
    log_info "  Stage version: $stage_version (maven-releases)"
    log_info "  Prod version:  $prod_version (maven-releases)"

    # 6. Verify artifacts exist in Nexus
    local nexus_url="${NEXUS_URL_INTERNAL:-http://nexus.nexus.svc.cluster.local:8081}"
    local group_id="com.example"
    local app_name="example-app"

    # Check SNAPSHOT
    local snapshot_check=$(curl -sf "${nexus_url}/service/rest/v1/search?repository=maven-snapshots&group=${group_id}&name=${app_name}&version=${dev_version}" 2>/dev/null | jq -r '.items | length')
    if [[ "$snapshot_check" -gt 0 ]]; then
        log_pass "SNAPSHOT artifact exists in Nexus"
    else
        log_fail "SNAPSHOT artifact not found in Nexus: ${dev_version}"
        return 1
    fi

    # Check RC
    local rc_check=$(curl -sf "${nexus_url}/service/rest/v1/search?repository=maven-releases&group=${group_id}&name=${app_name}&version=${stage_version}" 2>/dev/null | jq -r '.items | length')
    if [[ "$rc_check" -gt 0 ]]; then
        log_pass "RC artifact exists in Nexus"
    else
        log_fail "RC artifact not found in Nexus: ${stage_version}"
        return 1
    fi

    # Check Release
    local release_check=$(curl -sf "${nexus_url}/service/rest/v1/search?repository=maven-releases&group=${group_id}&name=${app_name}&version=${prod_version}" 2>/dev/null | jq -r '.items | length')
    if [[ "$release_check" -gt 0 ]]; then
        log_pass "Release artifact exists in Nexus"
    else
        log_fail "Release artifact not found in Nexus: ${prod_version}"
        return 1
    fi

    log_pass "Version lifecycle verification complete"
    return 0
}
```

**Step 2: Call verify_version_lifecycle at end of main validation**

Find the section near the end of the script where all validations are complete (after prod deployment verification), and add:

```bash
# Verify version lifecycle
verify_version_lifecycle
```

**Step 3: Commit**

```bash
git add scripts/test/validate-pipeline.sh
git commit -m "feat: add version lifecycle validation to validate-pipeline.sh

Verifies after full pipeline run:
- Dev has SNAPSHOT version
- Stage has RC version
- Prod has release version (no SNAPSHOT, no RC)
- Same git hash across all environments (same binary)
- Artifacts exist in Nexus with correct versions"
```

---

### Task 5: Sync and Test

**Step 1: Push changes to GitHub**

```bash
git push origin main
```

**Step 2: Sync to GitLab**

```bash
./scripts/04-operations/sync-to-gitlab.sh main
```

**Step 3: Reset demo state and sync Jenkinsfile to env branches**

```bash
./scripts/03-pipelines/reset-demo-state.sh
```

**Step 4: Run validate-pipeline.sh to test full lifecycle**

```bash
./scripts/test/validate-pipeline.sh
```

Expected: Pipeline runs through dev → stage → prod with version progression visible.

**Step 5: Commit any final adjustments**

```bash
git add -A
git commit -m "fix: adjustments from version lifecycle testing"
```

---

## Summary of Files

| File | Action |
|------|--------|
| `k8s-deployments/scripts/promote-artifact.sh` | Create (~200 lines) |
| `k8s-deployments/Jenkinsfile` | Modify `createPromotionMR()` (~30 lines added) |
| `scripts/demo/lib/assertions.sh` | Add assertion helpers (~80 lines) |
| `scripts/test/validate-pipeline.sh` | Add `verify_version_lifecycle()` (~100 lines) |
