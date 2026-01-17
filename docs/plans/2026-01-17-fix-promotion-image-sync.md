# Fix Promotion Logic: Image Sync Instead of Git Merge

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace broken git-merge promotion with targeted CI/CD image sync that preserves environment-specific configuration.

**Architecture:** Create `promote-images.sh` that extracts CI/CD-managed images (matching `docker.jmann.local/p2c/*`) from source environment and applies them to target environment using existing `update-app-image.sh`. Update Jenkinsfile's `createPromotionMR` to use this script instead of git merge. This handles single-app promotion, staggered multi-app promotion, and aggregate promotion to prod.

**Tech Stack:** Bash, CUE, Git, Jenkins Pipeline (Groovy)

---

## Background

### The Problem
The current `createPromotionMR` function in the Jenkinsfile tries to `git merge origin/dev` into stage. This fails because:
- dev branch has `env.cue` with `namespace: "dev"`, `replicas: 1`
- stage branch has `env.cue` with `namespace: "stage"`, `replicas: 2`
- Git sees these as merge conflicts on every promotion attempt

### The Solution
Instead of merging branches, sync only the CI/CD-managed image tags:
1. Identify CI/CD-managed images by registry prefix: `docker.jmann.local/p2c/*`
2. Extract those image tags from source environment
3. Update only those image tags in target environment (preserving all other config)
4. Regenerate manifests and create MR

### What Gets Promoted
- Image tags for apps matching `docker.jmann.local/p2c/*` pattern (CI/CD-managed)

### What Stays Environment-Specific (NOT promoted)
- `namespace`, `replicas`, `resources`, `debug` flags
- Infrastructure images (`postgres:16-alpine`, `redis:7-alpine`, etc.)
- Environment-specific env vars and ConfigMap values

---

## Tasks

### Task 1: Create promote-images.sh Script

**Files:**
- Create: `k8s-deployments/scripts/promote-images.sh`

**Step 1: Create the script with argument parsing and validation**

```bash
#!/bin/bash
set -euo pipefail

# Promote CI/CD-managed images from source environment to target environment
# This script extracts all images matching the CI/CD registry pattern from
# the source env.cue and applies them to the current branch's env.cue
#
# Usage: ./promote-images.sh <source-env> <target-env> [--registry-pattern <pattern>]
#
# Prerequisites:
#   - Must be run from k8s-deployments repo root
#   - Target env's env.cue must exist in current directory
#   - Source env branch must be fetchable from origin
#
# Example:
#   git checkout stage
#   ./scripts/promote-images.sh dev stage

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

# Default CI/CD registry pattern
REGISTRY_PATTERN="${REGISTRY_PATTERN:-docker\.jmann\.local/p2c/}"

# Parse arguments
SOURCE_ENV=""
TARGET_ENV=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --registry-pattern)
            REGISTRY_PATTERN="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <source-env> <target-env> [--registry-pattern <pattern>]"
            echo ""
            echo "Promotes CI/CD-managed images from source to target environment."
            echo ""
            echo "Arguments:"
            echo "  source-env         Source environment (dev, stage)"
            echo "  target-env         Target environment (stage, prod)"
            echo "  --registry-pattern Regex pattern for CI/CD images (default: docker\\.jmann\\.local/p2c/)"
            echo ""
            echo "Example:"
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

log_info "=== Promoting CI/CD Images: $SOURCE_ENV -> $TARGET_ENV ==="
log_info "Registry pattern: $REGISTRY_PATTERN"

# Fetch source branch to get latest env.cue
log_info "Fetching source branch: origin/$SOURCE_ENV"
git fetch origin "$SOURCE_ENV" --quiet

# Extract source env.cue to temp file
SOURCE_ENV_FILE=$(mktemp)
trap "rm -f $SOURCE_ENV_FILE" EXIT

git show "origin/${SOURCE_ENV}:env.cue" > "$SOURCE_ENV_FILE"

# Extract all apps from source environment
log_info "Discovering apps in $SOURCE_ENV environment..."
APPS=$(cue export "$SOURCE_ENV_FILE" -e "$SOURCE_ENV" --out json 2>/dev/null | jq -r 'keys[]') || {
    log_error "Failed to parse source env.cue"
    exit 1
}

log_info "Found apps: $APPS"

# Track what we promoted
PROMOTED_COUNT=0
SKIPPED_COUNT=0

# For each app, check if it has a CI/CD-managed image
for app in $APPS; do
    log_debug "Checking app: $app"

    # Get the image from source env
    SOURCE_IMAGE=$(cue export "$SOURCE_ENV_FILE" \
        -e "${SOURCE_ENV}.${app}.appConfig.deployment.image" \
        --out text 2>/dev/null) || {
        log_warn "Could not extract image for $app - skipping"
        continue
    }

    # Check if this is a CI/CD-managed image
    if echo "$SOURCE_IMAGE" | grep -qE "$REGISTRY_PATTERN"; then
        log_info "Promoting $app: $SOURCE_IMAGE"

        # Use update-app-image.sh to update the target env
        if "${SCRIPT_DIR}/update-app-image.sh" "$TARGET_ENV" "$app" "$SOURCE_IMAGE"; then
            ((PROMOTED_COUNT++))
        else
            log_error "Failed to update $app image"
            exit 1
        fi
    else
        log_debug "Skipping $app (not CI/CD-managed): $SOURCE_IMAGE"
        ((SKIPPED_COUNT++))
    fi
done

# Summary
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Promotion Summary: $SOURCE_ENV -> $TARGET_ENV"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Promoted: $PROMOTED_COUNT apps"
log_info "  Skipped:  $SKIPPED_COUNT apps (infrastructure)"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $PROMOTED_COUNT -eq 0 ]]; then
    log_warn "No CI/CD-managed images found to promote"
    log_warn "This may indicate images are already in sync or pattern doesn't match"
    exit 0
fi

log_info "✓ Image promotion complete"
log_info "Next: Run ./scripts/generate-manifests.sh to regenerate manifests"

exit 0
```

**Step 2: Make the script executable**

Run: `chmod +x k8s-deployments/scripts/promote-images.sh`

**Step 3: Verify script syntax**

Run: `bash -n k8s-deployments/scripts/promote-images.sh`
Expected: No output (syntax OK)

**Step 4: Commit**

```bash
git add k8s-deployments/scripts/promote-images.sh
git commit -m "feat: add promote-images.sh for CI/CD image sync

Creates script that promotes CI/CD-managed images between environments
without merging branches. Identifies CI/CD images by registry pattern
(docker.jmann.local/p2c/*) and uses update-app-image.sh to apply them.

Handles:
- Single app promotion
- Multiple apps (aggregate promotion)
- Skips infrastructure images (postgres, redis, etc.)"
```

---

### Task 2: Update Jenkinsfile createPromotionMR Function

**Files:**
- Modify: `k8s-deployments/Jenkinsfile:48-135`

**Step 1: Replace the createPromotionMR function**

Replace the entire `createPromotionMR` function (lines 48-135) with:

```groovy
/**
 * Creates a promotion MR to the next environment
 * Syncs CI/CD-managed images from source to target (no git merge)
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

                    # Promote CI/CD-managed images from source to target
                    # This syncs images matching docker.jmann.local/p2c/* pattern
                    ./scripts/promote-images.sh ${sourceEnv} ${targetEnv} || {
                        echo "ERROR: Image promotion failed"
                        exit 1
                    }

                    # Regenerate manifests with updated images
                    ./scripts/generate-manifests.sh || {
                        echo "ERROR: Manifest generation failed"
                        exit 1
                    }

                    # Check if there are any changes to commit
                    if git diff --quiet && git diff --cached --quiet; then
                        echo "No changes to promote - images already in sync"
                        exit 0
                    fi

                    # Commit changes
                    git add -A
                    git commit -m "Promote ${sourceEnv} to ${targetEnv}

Automated promotion of CI/CD-managed images after successful ${sourceEnv} deployment.

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
                        --description "Automated promotion MR created after successful ${sourceEnv} deployment.

**Source Environment:** ${sourceEnv}
**Target Environment:** ${targetEnv}

CI/CD-managed images have been synced from ${sourceEnv} to ${targetEnv}.
Environment-specific configuration (replicas, resources, namespace) preserved.

**Jenkins Build:** ${env.BUILD_URL}

---
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

**Step 2: Verify Jenkinsfile syntax**

Run: `cd k8s-deployments && cat Jenkinsfile | head -200`
Expected: Valid Groovy syntax, no obvious errors

**Step 3: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "fix: replace git merge with image sync in promotion

Changes createPromotionMR to use promote-images.sh instead of
git merge. This fixes merge conflicts caused by environment-specific
configuration (namespace, replicas, etc.).

The new approach:
1. Extracts CI/CD-managed images from source env
2. Updates only those images in target env
3. Regenerates manifests
4. Creates MR with changes

Handles aggregate promotion (multiple apps accumulated in stage
all get promoted to prod together)."
```

---

### Task 3: Test Locally with Dry Run

**Files:**
- None (testing only)

**Step 1: Push changes to GitHub**

Run: `git push origin main`

**Step 2: Sync to GitLab**

Run: `./scripts/04-operations/sync-to-gitlab.sh`

**Step 3: Reset environment branches to pick up new Jenkinsfile**

Run: `./scripts/03-pipelines/setup-gitlab-env-branches.sh --reset`

**Step 4: Run validation script**

Run: `./scripts/test/validate-pipeline.sh`

Expected:
- App build succeeds
- Dev MR merged
- ArgoCD syncs
- **Promotion MR to stage is created** (this was failing before)
- Stage deployment succeeds
- Promotion MR to prod is created
- Full pipeline passes

**Step 5: If validation passes, commit any remaining changes**

```bash
git add -A
git commit -m "chore: validation passed for image-sync promotion"
```

---

## Verification Checklist

After implementation, verify:

1. [ ] `promote-images.sh --help` shows usage
2. [ ] Script correctly identifies CI/CD images (docker.jmann.local/p2c/*)
3. [ ] Script skips infrastructure images (postgres:16-alpine)
4. [ ] Jenkinsfile `createPromotionMR` uses new script
5. [ ] dev→stage promotion creates MR without merge conflicts
6. [ ] stage→prod promotion creates MR without merge conflicts
7. [ ] `validate-pipeline.sh` passes end-to-end

---

## Rollback Plan

If issues occur:
1. Revert Jenkinsfile changes: `git revert HEAD~2`
2. Push and sync to GitLab
3. Reset environment branches
4. The `promote-environment` manual job still exists as fallback

---

## Future Enhancements

When multi-container support is needed:
1. Update `promote-images.sh` to also extract:
   - `appConfig.deployment.initContainers[*].image`
   - `appConfig.deployment.sidecars[*].image`
2. Update `update-app-image.sh` to handle these additional image paths
3. The registry pattern matching ensures only CI/CD images are promoted
