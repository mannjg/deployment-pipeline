#!/bin/bash
# Validates CUE configuration files
# Checks syntax, schema compliance, and imports
#
# Expects branch-per-environment structure: env.cue at root

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load preflight library
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"

echo "Validating CUE configuration..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Validating CUE Syntax"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERRORS=0

# Validate services (allow incomplete - these are schemas)
if [ -d "services" ]; then
    echo "Validating services..."
    for file in services/**/*.cue; do
        if [ -f "$file" ]; then
            if cue vet -c=false "$file" 2>&1 | grep -q "error"; then
                echo "✗ Error in $file"
                ERRORS=$((ERRORS + 1))
            else
                echo "✓ $file"
            fi
        fi
    done
fi

# Validate environment configuration (env.cue at root)
echo ""
echo "Validating environment configuration..."

if [ -f "env.cue" ]; then
    if cue vet "env.cue" 2>&1 | grep -q "error"; then
        echo "✗ Error in env.cue"
        cue vet "env.cue" 2>&1 | head -20
        ERRORS=$((ERRORS + 1))
    else
        echo "✓ env.cue"
    fi
else
    echo "✗ ERROR: env.cue not found at project root"
    echo "  This script expects branch-per-environment structure."
    echo "  Make sure you are on the correct branch (dev/stage/prod)."
    exit 1
fi

# Validate k8s templates (allow incomplete)
if [ -d "k8s" ]; then
    echo ""
    echo "Validating k8s templates..."
    for file in k8s/*.cue; do
        if [ -f "$file" ]; then
            if cue vet -c=false "$file" 2>&1 | grep -q "error"; then
                echo "✗ Error in $file"
                ERRORS=$((ERRORS + 1))
            else
                echo "✓ $file"
            fi
        fi
    done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $ERRORS -gt 0 ]; then
    echo "✗ CUE validation failed with $ERRORS error(s)"
    exit 1
else
    echo "✓ All CUE files validated successfully"
    exit 0
fi
