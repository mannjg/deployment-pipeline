#!/bin/bash
set -euo pipefail

# Generate Kubernetes manifests from CUE configuration
# Usage: ./generate-manifests.sh <environment>

ENVIRONMENT=${1:-dev}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST_DIR="${PROJECT_ROOT}/manifests/${ENVIRONMENT}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate environment
case $ENVIRONMENT in
    dev|stage|prod)
        log_info "Generating manifests for environment: ${ENVIRONMENT}"
        ;;
    *)
        log_error "Invalid environment: ${ENVIRONMENT}"
        echo "Usage: $0 <dev|stage|prod>"
        exit 1
        ;;
esac

# Check for CUE
if ! command -v cue &> /dev/null; then
    log_error "CUE command not found. Please install CUE: https://cuelang.org/docs/install/"
    exit 1
fi

# Create manifest directory
mkdir -p "${MANIFEST_DIR}"

log_info "Cleaning old manifests..."
rm -f "${MANIFEST_DIR}"/*.yaml

# Generate manifests for each app in the environment
cd "${PROJECT_ROOT}"

log_info "Discovering apps in ${ENVIRONMENT} environment..."

# Query all top-level keys in the environment to discover apps
# This dynamically finds all apps defined in the environment
apps_output=$(cue export ./envs/${ENVIRONMENT}.cue -e "${ENVIRONMENT}" --out json 2>&1)
apps_status=$?

# Check if cue export failed
if [ $apps_status -ne 0 ]; then
    log_error "Error querying apps in ${ENVIRONMENT}:"
    echo "$apps_output" | sed 's/^/  /'
    exit 1
fi

# Extract app names from JSON keys
# The JSON structure is: { "appName": { ... }, ... }
apps_json=$(echo "$apps_output" | tr -d '\n')
if [ -z "$apps_json" ] || [ "$apps_json" = "null" ] || [ "$apps_json" = "{}" ]; then
    log_warn "No apps defined in ${ENVIRONMENT} environment"
    exit 0
fi

# Parse JSON to get app names (keys at the top level)
# Use jq if available, otherwise use grep/sed
if command -v jq &> /dev/null; then
    app_names=$(echo "$apps_json" | jq -r 'keys[]' 2>/dev/null)
else
    # Fallback: parse JSON keys manually
    # Extract keys from JSON: "key": { ... }
    app_names=$(echo "$apps_json" | grep -o '"[^"]*"[[:space:]]*:' | sed 's/"//g' | sed 's/[[:space:]]*://')
fi

if [ -z "$app_names" ]; then
    log_warn "No apps found in ${ENVIRONMENT} environment"
    exit 0
fi

log_info "Found apps: $(echo $app_names | tr '\n' ' ')"

# Process each app
for app_name in $app_names; do
    log_info "Processing app: ${app_name}"

    # Create app-specific subdirectory
    APP_MANIFEST_DIR="${MANIFEST_DIR}/${app_name}"
    mkdir -p "${APP_MANIFEST_DIR}"

    # Query the resources_list for this app
    resources_output=$(cue export ./envs/${ENVIRONMENT}.cue -e "${ENVIRONMENT}.${app_name}.resources_list" --out json 2>&1)
    resources_status=$?

    # Check if cue export failed
    if [ $resources_status -ne 0 ]; then
        log_error "Error querying resources_list for ${app_name} in ${ENVIRONMENT}:"
        echo "$resources_output" | sed 's/^/  /'
        continue
    fi

    # Strip newlines from JSON output
    resources_json=$(echo "$resources_output" | tr -d '\n')

    # Handle empty or error output
    if [ -z "$resources_json" ] || [ "$resources_json" = "null" ]; then
        log_warn "No resources defined for ${app_name} in ${ENVIRONMENT}"
        continue
    fi

    # Parse JSON array into bash array
    # Remove brackets, quotes, and whitespace, split by comma
    resources_str=$(echo "$resources_json" | sed 's/[][]//g' | sed 's/"//g' | tr -d ' ')
    IFS=',' read -ra resources <<< "$resources_str"

    # Build export flags from resources_list
    # Each resource becomes: -e <env>.<app>.resources.<resource>
    if [ ${#resources[@]} -gt 0 ] && [ -n "${resources[0]}" ]; then
        export_flags=""
        for resource in "${resources[@]}"; do
            # Trim whitespace
            resource=$(echo "$resource" | xargs)
            if [ -n "$resource" ]; then
                export_flags="$export_flags -e ${ENVIRONMENT}.${app_name}.resources.$resource"
            fi
        done

        # Export all app resources in a single command
        # CUE automatically formats multiple exports with --- separators
        if [ -n "$export_flags" ]; then
            log_info "Exporting resources for ${app_name}: ${resources[*]}"
            log_info "Command: cue export ./envs/${ENVIRONMENT}.cue $export_flags --out yaml"

            export_output=$(cue export "./envs/${ENVIRONMENT}.cue" $export_flags --out yaml 2>&1)
            export_status=$?

            if [ $export_status -eq 0 ]; then
                # Sort keys for consistent output using yq if available
                if command -v yq &> /dev/null; then
                    echo "$export_output" | yq 'sort_keys(..)' > "${APP_MANIFEST_DIR}/${app_name}.yaml"
                else
                    echo "$export_output" > "${APP_MANIFEST_DIR}/${app_name}.yaml"
                fi
                log_info "Successfully generated ${APP_MANIFEST_DIR}/${app_name}.yaml"
                log_info "Resources: ${resources[*]}"
            else
                log_error "Error exporting resources for ${app_name} in ${ENVIRONMENT}:"
                echo "$export_output" | sed 's/^/  /'
                continue
            fi
        fi
    else
        log_warn "No resources defined for ${app_name} in ${ENVIRONMENT}"
        log_warn "Check that ${ENVIRONMENT}.${app_name}.resources_list exists in ./envs/${ENVIRONMENT}.cue"
    fi
done

log_info "Manifest generation complete!"
