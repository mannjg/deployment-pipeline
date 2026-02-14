#!/usr/bin/env bash
set -euo pipefail

# Promote configuration from source environment to target environment
# Syncs platform/app layers and promotes all app image tags.
#
# Usage: ./promote-app-config.sh <source-env> <target-env>
#
# What gets SYNCED (from source to target):
#   - templates/base/  - Base defaults and schemas
#   - templates/core/  - Shared templates (defaultLabels, #App)
#   - templates/apps/  - App definitions
#   - deployment.image in env.cue (all apps, including 3rd party)
#
# What gets PRESERVED (via CUE unification):
#   - Target's env.cue values: namespace, replicas, resources, debug, labels.environment
#   - CUE's layering ensures env-specific overrides "win" when manifests are generated
#
# Prerequisites:
#   - Must be run from k8s-deployments repo root
#   - Target env's env.cue must exist in current directory
#   - Source env branch must be fetchable from origin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load preflight library
source "${SCRIPT_DIR}/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR/.."
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

# Convert kebab-case app name to camelCase CUE identifier
# e.g., example-app -> exampleApp, my-service -> myService
# Duplicated from update-app-image.sh for standalone use
convert_to_camel_case() {
    local input="$1"
    echo "$input" | sed -E 's/([-_])([a-z])/\U\2/g' | sed 's/^./\L&/'
}

# Parse arguments
SOURCE_ENV=""
TARGET_ENV=""
ONLY_APPS=""
declare -A IMAGE_OVERRIDES

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 [OPTIONS] <source-env> <target-env>"
            echo ""
            echo "Promotes app configuration from source to target environment."
            echo "Preserves environment-specific fields (namespace, replicas, resources, debug)."
            echo ""
            echo "Arguments:"
            echo "  source-env    Source environment (dev, stage)"
            echo "  target-env    Target environment (stage, prod)"
            echo ""
            echo "Options:"
            echo "  --only-apps <apps>  Comma-separated list of CUE identifiers to promote"
            echo "                      (e.g., exampleApp,postgres). If omitted, all apps"
            echo "                      are promoted."
            echo "  --image-override <app>=<image>"
            echo "                      Use <image> instead of the source environment's image"
            echo "                      for <app>. App name can be kebab-case (example-app) or"
            echo "                      camelCase (exampleApp). Can be specified multiple times."
            echo "  -h, --help          Show this help message"
            echo ""
            echo "Example:"
            echo "  git checkout stage"
            echo "  $0 dev stage"
            echo "  $0 --only-apps exampleApp dev stage"
            echo "  $0 --image-override example-app=docker.local/p2c/example-app:1.0.0-rc1-abc123 dev stage"
            exit 0
            ;;
        --only-apps)
            ONLY_APPS="$2"
            shift 2
            ;;
        --image-override)
            override_spec="$2"
            if [[ "$override_spec" != *=* ]]; then
                log_error "--image-override value must be in format: app-name=image"
                exit 1
            fi
            override_app="${override_spec%%=*}"
            override_image="${override_spec#*=}"
            IMAGE_OVERRIDES["$(convert_to_camel_case "$override_app")"]="$override_image"
            shift 2
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

# Create temp directory for source branch checkout (needed for CUE module context)
SOURCE_DIR=$(mktemp -d)
cleanup() {
    git worktree remove "$SOURCE_DIR" 2>/dev/null || rm -rf "$SOURCE_DIR"
}
trap cleanup EXIT
log_debug "Created temp directory: $SOURCE_DIR"

# Clone source branch to temp directory (shallow for speed)
git worktree add --detach "$SOURCE_DIR" "origin/${SOURCE_ENV}" 2>/dev/null || {
    # Fallback: copy files if worktree fails
    log_debug "Worktree failed, using file copy fallback"
    git archive "origin/${SOURCE_ENV}" | tar -x -C "$SOURCE_DIR"
}

# Backup target env.cue
BACKUP_FILE="env.cue.backup.$(date +%s)"
cp env.cue "$BACKUP_FILE"
log_debug "Created backup: $BACKUP_FILE"

# Sync platform and app layers from source to target
# These files define templates/schemas - env.cue handles env-specific overrides
# CUE unification ensures target's env.cue values (namespace, replicas, etc.) are preserved
log_info "Syncing platform and app layers from $SOURCE_ENV..."
PLATFORM_CHANGED=false

for dir in templates/base templates/core templates/apps; do
    if [ -d "$SOURCE_DIR/$dir" ]; then
        # Check if there are actual differences
        if ! diff -rq "$dir" "$SOURCE_DIR/$dir" >/dev/null 2>&1; then
            log_info "  Syncing $dir/ (changes detected)"
            rm -rf "$dir"
            cp -r "$SOURCE_DIR/$dir" "$dir"
            git add "$dir"
            PLATFORM_CHANGED=true
        else
            log_debug "  $dir/ unchanged"
        fi
    fi
done

if [ "$PLATFORM_CHANGED" = true ]; then
    log_info "Platform/app layer changes will be included in promotion"
else
    log_debug "No platform/app layer changes detected"
fi

# Discover apps in source environment
log_info "Discovering apps in $SOURCE_ENV environment..."
APPS=$(cd "$SOURCE_DIR" && cue export ./env.cue -e "$SOURCE_ENV" --out json 2>/dev/null | jq -r 'keys[]') || {
    log_error "Failed to parse source env.cue"
    exit 1
}
log_info "Found apps: $APPS"

# Track changes
PROMOTED_COUNT=0
SKIPPED_COUNT=0

# Process each app
for APP in $APPS; do
    # Filter apps if --only-apps is specified
    if [[ -n "$ONLY_APPS" ]]; then
        # Check if APP is in the comma-separated ONLY_APPS list
        if ! echo ",$ONLY_APPS," | grep -q ",$APP,"; then
            log_info "Skipping app: $APP (not in --only-apps filter)"
            : $((SKIPPED_COUNT++))
            continue
        fi
    fi

    log_info "Processing app: $APP"

    # Check if app exists in target
    if ! cue export ./env.cue -e "${TARGET_ENV}.${APP}" --out json &>/dev/null; then
        log_warn "App $APP not found in $TARGET_ENV - skipping"
        : $((SKIPPED_COUNT++))
        continue
    fi

    # Extract source app config as JSON
    SOURCE_CONFIG=$(cd "$SOURCE_DIR" && cue export ./env.cue -e "${SOURCE_ENV}.${APP}.appConfig" --out json 2>/dev/null) || {
        log_warn "Could not extract appConfig for $APP from source - skipping"
        : $((SKIPPED_COUNT++))
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

    # 1. Update image if present
    if [[ -n "$SOURCE_IMAGE" ]]; then
        if [[ -n "${IMAGE_OVERRIDES[$APP]+_}" ]]; then
            EFFECTIVE_IMAGE="${IMAGE_OVERRIDES[$APP]}"
            log_info "  Updating image (override): $EFFECTIVE_IMAGE"
        else
            EFFECTIVE_IMAGE="$SOURCE_IMAGE"
            log_info "  Updating image: $EFFECTIVE_IMAGE"
        fi
        "${SCRIPT_DIR}/update-app-image.sh" "$TARGET_ENV" "$APP" "$EFFECTIVE_IMAGE" || {
            log_error "Failed to update image for $APP"
            mv "$BACKUP_FILE" env.cue
            exit 1
        }
    fi

    # TODO: Future enhancement - promote additionalEnv and configMap.data
    # This requires complex CUE manipulation to update arrays/objects.
    # For now, only images are promoted. Human reviewers can manually
    # add additionalEnv/configMap changes to the MR if needed.
    if [[ "$SOURCE_ADDITIONAL_ENV" != "[]" ]]; then
        log_debug "  Source has additionalEnv entries (not auto-promoted, see MR diff)"
    fi
    if [[ "$SOURCE_CONFIGMAP_DATA" != "{}" ]]; then
        log_debug "  Source has configMap.data entries (not auto-promoted, see MR diff)"
    fi

    : $((PROMOTED_COUNT++))
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
if [[ -n "$ONLY_APPS" ]]; then
    log_info "  App filter:     $ONLY_APPS"
fi
log_info "  Platform layer: $([ "$PLATFORM_CHANGED" = true ] && echo "changed" || echo "unchanged")"
log_info "  App images:     $PROMOTED_COUNT promoted, $SKIPPED_COUNT skipped"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $PROMOTED_COUNT -eq 0 ]] && [[ "$PLATFORM_CHANGED" != true ]]; then
    log_warn "No changes to promote"
    exit 0
fi

log_info "✓ Promotion complete"
log_info "Next steps:"
log_info "  1. Run ./scripts/generate-manifests.sh"
log_info "  2. Review changes with: git diff"
log_info "  3. Commit and create MR"

exit 0
