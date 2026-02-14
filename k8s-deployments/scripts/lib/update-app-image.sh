#!/usr/bin/env bash
set -euo pipefail

# Update application image in environment CUE configuration
# This script safely updates only the specified app's image without affecting other apps
# Usage: ./update-app-image.sh <environment> <app-name> <new-image>

ENVIRONMENT=${1:-}
APP_NAME=${2:-}
NEW_IMAGE=${3:-}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load preflight library and local config
source "${SCRIPT_DIR}/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR/.."

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"

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

# Validate arguments
if [ -z "$ENVIRONMENT" ] || [ -z "$APP_NAME" ] || [ -z "$NEW_IMAGE" ]; then
    log_error "Missing required arguments"
    echo "Usage: $0 <environment> <app-name> <new-image>"
    echo ""
    echo "Arguments:"
    echo "  environment  Target environment (dev|stage|prod)"
    echo "  app-name     Application name (e.g., example-app, postgres)"
    echo "  new-image    New Docker image reference (e.g., docker.local/p2c/example-app:1.2.0-abc123)"
    echo ""
    echo "Example:"
    echo "  $0 dev example-app docker.local/p2c/example-app:1.2.0-abc123"
    exit 1
fi

# Validate environment
case $ENVIRONMENT in
    dev|stage|prod)
        log_info "Updating image for ${APP_NAME} in ${ENVIRONMENT} environment"
        ;;
    *)
        log_error "Invalid environment: ${ENVIRONMENT}"
        echo "Valid environments: dev, stage, prod"
        exit 1
        ;;
esac

# Convert app-name to camelCase for CUE field name
# e.g., example-app -> exampleApp, my-service -> myService
# This matches the CUE naming convention used in the environment files
convert_to_camel_case() {
    local input="$1"
    # Convert kebab-case or snake_case to camelCase
    # First, replace - or _ followed by a letter with uppercase letter
    # Then lowercase the first character
    echo "$input" | sed -E 's/([-_])([a-z])/\U\2/g' | sed 's/^./\L&/'
}

APP_CUE_NAME=$(convert_to_camel_case "$APP_NAME")
log_debug "Converted app name: ${APP_NAME} -> ${APP_CUE_NAME}"

# Change to project root
cd "$PROJECT_ROOT"

# In branch-per-environment structure, env.cue is at root
ENV_FILE="env.cue"

# Validate environment file exists
if [ ! -f "$ENV_FILE" ]; then
    log_error "Environment file not found: ${ENV_FILE}"
    log_error "Make sure you are on the correct branch (dev/stage/prod)"
    exit 1
fi

# Verify the app exists in the environment
log_info "Verifying ${APP_CUE_NAME} exists in ${ENVIRONMENT} environment..."
if ! cue export "./${ENV_FILE}" -e "${ENVIRONMENT}.${APP_CUE_NAME}" --out json &> /dev/null; then
    log_error "App '${APP_CUE_NAME}' not found in ${ENVIRONMENT} environment"
    log_error "Available apps in ${ENVIRONMENT}:"
    cue export "./${ENV_FILE}" -e "${ENVIRONMENT}" --out json 2>/dev/null | jq -r 'keys[]' | sed 's/^/  - /' || echo "  (could not list apps)"
    exit 1
fi

log_info "Found ${APP_CUE_NAME} in ${ENVIRONMENT} environment"

# Get current image before update
CURRENT_IMAGE=$(cue export "./${ENV_FILE}" -e "${ENVIRONMENT}.${APP_CUE_NAME}.appConfig.deployment.image" --out text 2>/dev/null || echo "unknown")
log_info "Current image: ${CURRENT_IMAGE}"
log_info "New image:     ${NEW_IMAGE}"

# Check if image is already set to target value
if [ "$CURRENT_IMAGE" = "$NEW_IMAGE" ]; then
    log_warn "Image is already set to ${NEW_IMAGE}"
    log_info "No update needed"
    exit 0
fi

# Create backup of original file
BACKUP_FILE="${ENV_FILE}.backup.$(date +%s)"
cp "$ENV_FILE" "$BACKUP_FILE"
log_debug "Created backup: ${BACKUP_FILE}"

# Update the image using awk for precise section-based replacement
# This ensures we only update the image within the specific app's section
log_info "Updating image field in ${ENV_FILE}..."

awk -v env="${ENVIRONMENT}" -v app="${APP_CUE_NAME}" -v img="${NEW_IMAGE}" '
BEGIN { 
    in_app_section = 0
    found_image = 0
}

# Detect app section start: "dev: exampleApp:" or similar
$0 ~ "^" env ": " app ":" {
    in_app_section = 1
    section_indent = match($0, /[^ \t]/)
    print
    next
}

# Detect when we exit the app section
# This happens when we encounter another top-level environment field at the same indent level
in_app_section && /^[a-zA-Z]/ && !($0 ~ app ":") {
    in_app_section = 0
}

# Replace image only within the app section
in_app_section && /image:/ {
    # Extract indentation and replace image value
    indent = substr($0, 1, match($0, /[^ \t]/)-1)
    sub(/image: ".*"/, "image: \"" img "\"")
    found_image = 1
}

{ print }

END {
    if (!found_image) {
        print "ERROR: Image field not found in app section" > "/dev/stderr"
        exit 1
    }
}
' "$ENV_FILE" > "${ENV_FILE}.tmp"

AWK_STATUS=$?

if [ $AWK_STATUS -ne 0 ]; then
    log_error "Failed to update image in ${ENV_FILE}"
    log_info "Restoring from backup..."
    mv "$BACKUP_FILE" "$ENV_FILE"
    rm -f "${ENV_FILE}.tmp"
    exit 1
fi

# Move updated file into place
mv "${ENV_FILE}.tmp" "$ENV_FILE"

# Validate the updated CUE file
log_info "Validating updated CUE configuration..."
if ! cue vet "./${ENV_FILE}" 2>&1; then
    log_error "CUE validation failed after update!"
    log_info "Restoring from backup..."
    mv "$BACKUP_FILE" "$ENV_FILE"
    exit 1
fi

log_info "CUE validation passed"

# Verify the update was successful
UPDATED_IMAGE=$(cue export "./${ENV_FILE}" -e "${ENVIRONMENT}.${APP_CUE_NAME}.appConfig.deployment.image" --out text 2>/dev/null)
if [ "$UPDATED_IMAGE" != "$NEW_IMAGE" ]; then
    log_error "Image update verification failed!"
    log_error "Expected: ${NEW_IMAGE}"
    log_error "Got:      ${UPDATED_IMAGE}"
    log_info "Restoring from backup..."
    mv "$BACKUP_FILE" "$ENV_FILE"
    exit 1
fi

log_info "Update verification passed"

# Count how many image fields changed (should be exactly 1)
# Look for lines like: +			image: "..."
CHANGES_COUNT=$(diff -u "$BACKUP_FILE" "$ENV_FILE" | grep -c '^+[[:space:]]*image: "' 2>/dev/null || true)
# If grep failed or returned empty, set to 0
if [ -z "$CHANGES_COUNT" ]; then
    CHANGES_COUNT=0
fi
if [ "$CHANGES_COUNT" -ne 1 ]; then
    log_warn "Expected 1 image change, but found ${CHANGES_COUNT}"
    log_warn "This may indicate the update affected multiple apps"
    log_info "Diff of changes:"
    diff -u "$BACKUP_FILE" "$ENV_FILE" | grep 'image:' | head -10
    
    # In non-interactive mode (CI/CD), fail fast
    if [ ! -t 0 ]; then
        log_error "Running in non-interactive mode - cannot confirm multiple changes"
        log_info "Restoring from backup..."
        mv "$BACKUP_FILE" "$ENV_FILE"
        exit 1
    fi
    
    # In interactive mode, ask for confirmation
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restoring from backup..."
        mv "$BACKUP_FILE" "$ENV_FILE"
        exit 1
    fi
fi

# Remove backup on success
rm -f "$BACKUP_FILE"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "✓ Successfully updated ${APP_NAME} image"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Environment: ${ENVIRONMENT}"
log_info "Application: ${APP_NAME} (${APP_CUE_NAME})"
log_info "Old image:   ${CURRENT_IMAGE}"
log_info "New image:   ${NEW_IMAGE}"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Show the diff for visibility
if command -v git &> /dev/null && [ -d .git ]; then
    log_info "Changes made:"
    git diff "$ENV_FILE" | grep -A2 -B2 'image:' || echo "  (git diff not available)"
fi

exit 0
