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

log_info "Evaluating CUE configuration..."

# Export the environment configuration
cue export \
    --out yaml \
    ./envs/${ENVIRONMENT}.cue \
    --path "${ENVIRONMENT}.exampleApp.resources" > "${MANIFEST_DIR}/example-app-raw.yaml"

# Convert the resources map to a YAML stream with document separators
python3 - "${MANIFEST_DIR}/example-app-raw.yaml" "${MANIFEST_DIR}/example-app.yaml" "${ENVIRONMENT}" <<'PYTHON_SCRIPT'
import yaml
import sys

raw_file = sys.argv[1]
output_file = sys.argv[2]
env = sys.argv[3]

with open(raw_file, 'r') as f:
    data = yaml.safe_load(f)

resources = data.get(env, {}).get('exampleApp', {}).get('resources', {})

with open(output_file, 'w') as out:
    first = True
    for name, resource in resources.items():
        if not first:
            out.write("---\n")
        first = False
        out.write(yaml.dump(resource, default_flow_style=False, sort_keys=False))
PYTHON_SCRIPT

if [ $? -eq 0 ]; then
    rm -f "${MANIFEST_DIR}/example-app-raw.yaml"
    log_info "Successfully generated manifests in: ${MANIFEST_DIR}"
    log_info "Files:"
    ls -lh "${MANIFEST_DIR}"
else
    log_error "Failed to generate manifests"
    exit 1
fi

log_info "Manifest generation complete!"
