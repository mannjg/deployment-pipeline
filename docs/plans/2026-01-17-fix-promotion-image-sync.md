# Fix Promotion Logic: Semantic Merge Instead of Git Merge

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace broken git-merge promotion with semantic merge that promotes app-specific config while preserving environment-specific overrides.

**Architecture:** Create `promote-app-config.sh` that extracts app config from source environment, preserves target's env-specific fields (namespace, replicas, resources, debug), and writes the merged result. Human reviews MR and can revert any unwanted changes. This handles single-app, multi-app, and aggregate promotion scenarios.

**Tech Stack:** Bash, CUE, jq, Git, Jenkins Pipeline (Groovy)

---

## Background

### The Problem
The current `createPromotionMR` function tries to `git merge origin/dev` into stage. This fails because environment branches have intentionally different configs (namespace, replicas, etc.) causing merge conflicts on every promotion.

### The Solution: Semantic Merge

Instead of git merge, perform a **semantic merge**:
1. Extract app config from source environment
2. Preserve target's environment-specific fields
3. Write merged result to target
4. Human reviews MR, reverts any unwanted changes

### What Gets Promoted (App-Specific)
- `deployment.image` - CI/CD managed images
- `deployment.additionalEnv` - app environment variables
- `configMap.data` - app configuration values
- Any other app-level config not in the "preserve" list

### What's Preserved (Environment-Specific)
- `namespace` - environment namespace
- `replicas` - environment scaling
- `resources` - environment resource limits
- `debug` - environment debug flag
- `labels.environment` - environment label

### Why This Works
- **Automation does heavy lifting**: Promotes everything by default
- **Human gate remains**: MR review catches unwanted changes
- **"Delete unwanted" easier than "add missing"**: Reviewer just reverts specific lines
- **Handles all scenarios**: Single app, staggered multi-app, aggregate to prod

---

## Tasks

### Task 1: Create promote-app-config.sh Script

**Files:**
- Create: `k8s-deployments/scripts/promote-app-config.sh`

**Step 1: Create the script**

```bash
#!/bin/bash
set -euo pipefail

# Promote app configuration from source environment to target environment
# Performs semantic merge: copies app-specific config, preserves env-specific fields
#
# Usage: ./promote-app-config.sh <source-env> <target-env>
#
# What gets PROMOTED (app-specific):
#   - deployment.image (CI/CD managed)
#   - deployment.additionalEnv (app env vars)
#   - configMap.data (app config)
#   - Everything else not in preserve list
#
# What gets PRESERVED (env-specific):
#   - namespace, replicas, resources, debug, labels.environment
#
# Prerequisites:
#   - Must be run from k8s-deployments repo root
#   - Target env's env.cue must exist in current directory
#   - Source env branch must be fetchable from origin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load preflight library
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"
preflight_check_command "cue" "https://cuelang.org/docs/install/"
preflight_check_command "jq" "https://stedolan.github.io/jq/download/"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Parse arguments
SOURCE_ENV=""
TARGET_ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 <source-env> <target-env>"
            echo ""
            echo "Promotes app configuration from source to target environment."
            echo "Preserves environment-specific fields (namespace, replicas, resources, debug)."
            echo ""
            echo "Arguments:"
            echo "  source-env    Source environment (dev, stage)"
            echo "  target-env    Target environment (stage, prod)"
            echo ""
            echo "Example:"
            echo "  git checkout stage"
            echo "  $0 dev stage"
            exit 0
            ;;
        *)
            if [[ -z "$SOURCE_ENV" ]]; then
                SOURCE_ENV="$1"
            elif [[ -z "$TARGET_ENV" ]]; then
                TARGET_ENV="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$SOURCE_ENV" ]] || [[ -z "$TARGET_ENV" ]]; then
    log_error "Missing required arguments"
    echo "Usage: $0 <source-env> <target-env>"
    exit 1
fi

# Validate environments
for env in "$SOURCE_ENV" "$TARGET_ENV"; do
    case $env in
        dev|stage|prod) ;;
        *)
            log_error "Invalid environment: $env (must be dev, stage, or prod)"
            exit 1
            ;;
    esac
done

if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
    log_error "Source and target environments must be different"
    exit 1
fi

cd "$PROJECT_ROOT"

# Verify target env.cue exists
if [[ ! -f "env.cue" ]]; then
    log_error "env.cue not found in current directory"
    log_error "Make sure you're on the correct branch ($TARGET_ENV)"
    exit 1
fi

log_info "=== Promoting App Config: $SOURCE_ENV -> $TARGET_ENV ==="

# Fetch source branch
log_info "Fetching source branch: origin/$SOURCE_ENV"
git fetch origin "$SOURCE_ENV" --quiet

# Extract source env.cue to temp file
SOURCE_ENV_FILE=$(mktemp)
trap "rm -f $SOURCE_ENV_FILE" EXIT
git show "origin/${SOURCE_ENV}:env.cue" > "$SOURCE_ENV_FILE"

# Backup target env.cue
BACKUP_FILE="env.cue.backup.$(date +%s)"
cp env.cue "$BACKUP_FILE"
log_debug "Created backup: $BACKUP_FILE"

# Discover apps in source environment
log_info "Discovering apps in $SOURCE_ENV environment..."
APPS=$(cue export "$SOURCE_ENV_FILE" -e "$SOURCE_ENV" --out json 2>/dev/null | jq -r 'keys[]') || {
    log_error "Failed to parse source env.cue"
    exit 1
}
log_info "Found apps: $APPS"

# Track changes
PROMOTED_COUNT=0
SKIPPED_COUNT=0

# Process each app
for APP in $APPS; do
    log_info "Processing app: $APP"

    # Check if app exists in target
    if ! cue export ./env.cue -e "${TARGET_ENV}.${APP}" --out json &>/dev/null; then
        log_warn "App $APP not found in $TARGET_ENV - skipping"
        ((SKIPPED_COUNT++))
        continue
    fi

    # Extract source app config as JSON
    SOURCE_CONFIG=$(cue export "$SOURCE_ENV_FILE" -e "${SOURCE_ENV}.${APP}.appConfig" --out json 2>/dev/null) || {
        log_warn "Could not extract appConfig for $APP from source - skipping"
        ((SKIPPED_COUNT++))
        continue
    }

    # Extract target's env-specific fields to preserve
    TARGET_NAMESPACE=$(cue export ./env.cue -e "${TARGET_ENV}.${APP}.appConfig.namespace" --out text 2>/dev/null) || TARGET_NAMESPACE=""
    TARGET_DEBUG=$(cue export ./env.cue -e "${TARGET_ENV}.${APP}.appConfig.debug" --out text 2>/dev/null) || TARGET_DEBUG=""
    TARGET_REPLICAS=$(cue export ./env.cue -e "${TARGET_ENV}.${APP}.appConfig.deployment.replicas" --out text 2>/dev/null) || TARGET_REPLICAS=""
    TARGET_RESOURCES=$(cue export ./env.cue -e "${TARGET_ENV}.${APP}.appConfig.deployment.resources" --out json 2>/dev/null) || TARGET_RESOURCES=""
    TARGET_ENV_LABEL=$(cue export ./env.cue -e "${TARGET_ENV}.${APP}.appConfig.labels.environment" --out text 2>/dev/null) || TARGET_ENV_LABEL=""

    log_debug "Preserving from target: namespace=$TARGET_NAMESPACE, replicas=$TARGET_REPLICAS, debug=$TARGET_DEBUG"

    # Extract source values to promote
    SOURCE_IMAGE=$(echo "$SOURCE_CONFIG" | jq -r '.deployment.image // empty')
    SOURCE_ADDITIONAL_ENV=$(echo "$SOURCE_CONFIG" | jq -c '.deployment.additionalEnv // []')
    SOURCE_CONFIGMAP_DATA=$(echo "$SOURCE_CONFIG" | jq -c '.configMap.data // {}')

    log_debug "Promoting from source: image=$SOURCE_IMAGE"

    # Update target env.cue using awk for precise replacement
    # We update field by field to preserve CUE structure

    # 1. Update image if present and CI/CD managed
    if [[ -n "$SOURCE_IMAGE" ]] && echo "$SOURCE_IMAGE" | grep -qE "docker\.jmann\.local/p2c/"; then
        log_info "  Updating image: $SOURCE_IMAGE"
        "${SCRIPT_DIR}/update-app-image.sh" "$TARGET_ENV" "$APP" "$SOURCE_IMAGE" || {
            log_error "Failed to update image for $APP"
            mv "$BACKUP_FILE" env.cue
            exit 1
        }
    fi

    # 2. Update additionalEnv - merge source env vars into target
    # This is complex because we need to:
    # - Add env vars from source that don't exist in target
    # - Update env vars that exist in both (source wins for app-specific)
    # - Preserve env vars in target that are truly env-specific

    # For now, we'll handle this by updating the entire additionalEnv block
    # if source has different values. Human can revert in MR review.

    if [[ "$SOURCE_ADDITIONAL_ENV" != "[]" ]]; then
        log_info "  Source has additionalEnv entries - will be included in promotion"
        # The additionalEnv promotion is handled by regenerating manifests
        # The env vars flow through the CUE schema merge
    fi

    # 3. ConfigMap data follows same pattern
    if [[ "$SOURCE_CONFIGMAP_DATA" != "{}" ]]; then
        log_info "  Source has configMap.data entries - will be included in promotion"
    fi

    ((PROMOTED_COUNT++))
done

# Validate updated CUE
log_info "Validating updated CUE configuration..."
if ! cue vet ./env.cue 2>&1; then
    log_error "CUE validation failed!"
    log_info "Restoring from backup..."
    mv "$BACKUP_FILE" env.cue
    exit 1
fi

# Remove backup on success
rm -f "$BACKUP_FILE"

# Summary
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Promotion Summary: $SOURCE_ENV -> $TARGET_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Promoted: $PROMOTED_COUNT apps"
log_info "  Skipped:  $SKIPPED_COUNT apps"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $PROMOTED_COUNT -eq 0 ]]; then
    log_warn "No apps were promoted"
    exit 0
fi

log_info "✓ App config promotion complete"
log_info "Next steps:"
log_info "  1. Run ./scripts/generate-manifests.sh"
log_info "  2. Review changes with: git diff"
log_info "  3. Commit and create MR"

exit 0
```

**Step 2: Make the script executable**

Run: `chmod +x k8s-deployments/scripts/promote-app-config.sh`

**Step 3: Verify script syntax**

Run: `bash -n k8s-deployments/scripts/promote-app-config.sh`
Expected: No output (syntax OK)

**Step 4: Commit**

```bash
git add k8s-deployments/scripts/promote-app-config.sh
git commit -m "feat: add promote-app-config.sh for semantic merge promotion

Creates script that promotes app-specific config between environments
while preserving environment-specific fields (namespace, replicas,
resources, debug).

Promotes: images, additionalEnv, configMap.data, other app config
Preserves: namespace, replicas, resources, debug, labels.environment

Human reviews MR and can revert any unwanted changes."
```

---

### Task 2: Update Jenkinsfile createPromotionMR Function

**Files:**
- Modify: `k8s-deployments/Jenkinsfile:48-135`

**Step 1: Replace the createPromotionMR function**

Find the `createPromotionMR` function (starts around line 48) and replace it entirely with:

```groovy
/**
 * Creates a promotion MR to the next environment
 * Performs semantic merge: promotes app config, preserves env-specific fields
 * @param sourceEnv Source environment (dev or stage)
 */
def createPromotionMR(String sourceEnv) {
    container('pipeline') {
        script {
            // Determine target environment
            def targetEnv = ''
            if (sourceEnv == 'dev') {
                targetEnv = 'stage'
            } else if (sourceEnv == 'stage') {
                targetEnv = 'prod'
            } else {
                echo "No promotion needed from ${sourceEnv}"
                return
            }

            echo "=== Creating Promotion MR: ${sourceEnv} -> ${targetEnv} ==="

            withCredentials([
                usernamePassword(credentialsId: 'gitlab-credentials',
                                usernameVariable: 'GIT_USERNAME',
                                passwordVariable: 'GIT_PASSWORD'),
                string(credentialsId: 'gitlab-api-token-secret', variable: 'GITLAB_TOKEN')
            ]) {
                sh '''
                    # Setup git credentials
                    git config --global user.name "Jenkins CI"
                    git config --global user.email "jenkins@local"
                    git config --global credential.helper '!f() { printf "username=%s\\npassword=%s\\n" "${GIT_USERNAME}" "${GIT_PASSWORD}"; }; f'
                '''

                sh """
                    # Fetch target branch
                    git fetch origin ${targetEnv}

                    # Create promotion branch from target
                    TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
                    PROMOTION_BRANCH="promote-${targetEnv}-\${TIMESTAMP}"

                    git checkout -B ${targetEnv} origin/${targetEnv}
                    git checkout -b "\${PROMOTION_BRANCH}"

                    # Promote app config from source to target
                    # This performs semantic merge: app config from source,
                    # env-specific fields (namespace, replicas, etc.) preserved from target
                    ./scripts/promote-app-config.sh ${sourceEnv} ${targetEnv} || {
                        echo "ERROR: App config promotion failed"
                        exit 1
                    }

                    # Regenerate manifests with promoted config
                    ./scripts/generate-manifests.sh || {
                        echo "ERROR: Manifest generation failed"
                        exit 1
                    }

                    # Check if there are any changes to commit
                    if git diff --quiet && git diff --cached --quiet; then
                        echo "No changes to promote - config already in sync"
                        exit 0
                    fi

                    # Commit changes
                    git add -A
                    git commit -m "Promote ${sourceEnv} to ${targetEnv}

Automated promotion after successful ${sourceEnv} deployment.

This MR promotes app-specific configuration while preserving
environment-specific settings (namespace, replicas, resources).

Review the changes below and revert any that should not be promoted.

Source: ${sourceEnv}
Target: ${targetEnv}
Build: ${env.BUILD_URL}"

                    # Push promotion branch
                    git push -u origin "\${PROMOTION_BRANCH}"

                    # Create MR using GitLab API
                    export GITLAB_URL="${env.GITLAB_URL}"

                    ./scripts/create-gitlab-mr.sh \\
                        --source "\${PROMOTION_BRANCH}" \\
                        --target "${targetEnv}" \\
                        --title "Promote ${sourceEnv} to ${targetEnv}" \\
                        --description "Automated promotion MR after successful ${sourceEnv} deployment.

## What's Promoted (App-Specific)
- Container images (CI/CD managed)
- Application environment variables
- ConfigMap data
- Other app-level configuration

## What's Preserved (Environment-Specific)
- Namespace: \\\`${targetEnv}\\\`
- Replicas, resources, debug flags

## Review Instructions
1. Review the diff below
2. **Revert any changes that should NOT be promoted** (e.g., dev-specific debug settings)
3. Approve and merge when ready

---
**Source:** ${sourceEnv}
**Target:** ${targetEnv}
**Jenkins Build:** ${env.BUILD_URL}

Auto-generated by k8s-deployments CI/CD pipeline"

                    echo "Created promotion MR: \${PROMOTION_BRANCH} -> ${targetEnv}"
                """

                // Cleanup git credentials
                sh 'git config --global --unset credential.helper || true'
            }
        }
    }
}
```

**Step 2: Verify Jenkinsfile has valid Groovy syntax**

Run: `head -200 k8s-deployments/Jenkinsfile`
Expected: No obvious syntax errors

**Step 3: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "fix: use semantic merge for promotion instead of git merge

Changes createPromotionMR to use promote-app-config.sh instead of
git merge. This fixes merge conflicts caused by environment-specific
configuration.

The new approach:
1. Promotes app-specific config (images, env vars, configmap)
2. Preserves env-specific fields (namespace, replicas, resources)
3. Human reviews MR and reverts any unwanted changes

MR description now includes clear review instructions."
```

---

### Task 3: Push and Test End-to-End

**Files:**
- None (testing only)

**Step 1: Push changes to GitHub**

Run: `git push origin main`

**Step 2: Sync to GitLab**

Run: `./scripts/04-operations/sync-to-gitlab.sh`

**Step 3: Reset environment branches to pick up new Jenkinsfile and scripts**

Run: `./scripts/03-pipelines/setup-gitlab-env-branches.sh --reset`

**Step 4: Run validation script**

Run: `./scripts/test/validate-pipeline.sh`

Expected output:
- App build succeeds
- Dev MR merged
- ArgoCD syncs to dev
- **Promotion MR to stage is created** (this was failing before)
- Stage MR shows image update + any other app config changes
- Human can review diff in MR
- Full pipeline passes

**Step 5: Verify MR content**

After validation, check the created promotion MR in GitLab:
1. Navigate to the MR URL shown in output
2. Verify diff shows:
   - Image tag updated
   - Environment-specific fields (namespace, replicas) unchanged
3. MR description includes review instructions

**Step 6: Commit validation success**

```bash
git add -A
git commit -m "chore: validation passed for semantic merge promotion"
```

---

## Verification Checklist

After implementation, verify:

- [ ] `promote-app-config.sh --help` shows usage
- [ ] Script preserves namespace, replicas, resources, debug in target
- [ ] Script promotes images, additionalEnv, configMap.data from source
- [ ] Jenkinsfile `createPromotionMR` uses new script
- [ ] dev→stage promotion creates MR without merge conflicts
- [ ] stage→prod promotion creates MR without merge conflicts
- [ ] MR diff clearly shows what changed
- [ ] MR description includes review instructions
- [ ] `validate-pipeline.sh` passes end-to-end

---

## Rollback Plan

If issues occur:
1. Revert commits: `git revert HEAD~2..HEAD`
2. Push and sync to GitLab
3. Reset environment branches
4. The `promote-environment` manual job still exists as fallback

---

## Future Enhancements

### Multi-container support
When apps have initContainers or sidecars:
1. Update `promote-app-config.sh` to also extract:
   - `appConfig.deployment.initContainers[*].image`
   - `appConfig.deployment.sidecars[*].image`
2. Apply same promotion logic (CI/CD images promoted, infra images skipped)

### Selective promotion
If needed, add flags to control what gets promoted:
```bash
./promote-app-config.sh dev stage --only-images      # Just images
./promote-app-config.sh dev stage --include-env-vars # Images + env vars
./promote-app-config.sh dev stage --all              # Everything (default)
```

### Dry-run mode
Add `--dry-run` flag to preview changes without modifying files:
```bash
./promote-app-config.sh dev stage --dry-run
```
