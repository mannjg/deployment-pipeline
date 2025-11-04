#!/bin/bash
# Validates CUE configuration files
# Checks syntax, schema compliance, and imports

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Validating CUE configuration..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

# Check if cue command exists
if ! command -v cue &> /dev/null; then
    echo "✗ ERROR: cue command not found!"
    echo "  Please install CUE: https://cuelang.org/docs/install/"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Validating CUE Syntax"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Validate all CUE files
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

# Validate environments (must be complete)
if [ -d "envs" ]; then
    echo ""
    echo "Validating environments..."
    for file in envs/*.cue; do
        if [ -f "$file" ]; then
            if cue vet "$file" 2>&1 | grep -q "error"; then
                echo "✗ Error in $file"
                ERRORS=$((ERRORS + 1))
            else
                echo "✓ $file"
            fi
        fi
    done
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
