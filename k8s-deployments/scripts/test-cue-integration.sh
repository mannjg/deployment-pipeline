#!/usr/bin/env bash
# Integration tests for CUE configuration and manifest generation
# Tests the complete workflow: CUE → Manifest → Validation
#
# Expects branch-per-environment structure: env.cue at root
# Discovers apps dynamically from environment configuration.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load preflight library
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "cue" "https://cuelang.org/docs/install/"
preflight_check_command "yq" "https://github.com/mikefarah/yq"

echo "Running CUE integration tests..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Integration Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Require env.cue (branch-per-environment structure)
if [ ! -f "env.cue" ]; then
    echo "✗ ERROR: env.cue not found at project root"
    echo "  This script expects branch-per-environment structure."
    echo "  Make sure you are on the correct branch (dev/stage/prod)."
    exit 1
fi

# Detect environment from env.cue
DETECTED_ENV=$(grep -oP '^\s*env:\s*"\K[^"]+' "env.cue" 2>/dev/null || echo "")
if [ -z "$DETECTED_ENV" ]; then
    # Try to detect from branch name
    DETECTED_ENV=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "dev")
fi
echo "Testing environment: $DETECTED_ENV"

ERRORS=0

# Test 1: Generate manifests
echo ""
echo "Test 1: Manifest generation"
echo "  Testing $DETECTED_ENV environment..."

if [ -f "./scripts/generate-manifests.sh" ]; then
    if ./scripts/generate-manifests.sh "$DETECTED_ENV" > /dev/null 2>&1; then
        echo "    ✓ Manifest generation succeeded"
    else
        echo "    ✗ Manifest generation failed"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "    ⚠ generate-manifests.sh not found, skipping"
fi

# Test 2: Validate generated manifests exist
echo ""
echo "Test 2: Manifest file validation"

# Find manifests (in manifests/{app}/ structure)
manifest_count=$(find manifests -name "*.yaml" -type f 2>/dev/null | wc -l)

if [ "$manifest_count" -gt 0 ]; then
    echo "  Found $manifest_count manifest file(s)"

    # Validate YAML syntax for each
    for manifest in manifests/**/*.yaml manifests/*.yaml; do
        if [ -f "$manifest" ]; then
            if yq eval '.' "$manifest" > /dev/null 2>&1; then
                echo "    ✓ $manifest - YAML valid"
            else
                echo "    ✗ $manifest - YAML invalid"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
else
    echo "  ⚠ No manifest files found"
fi

# Test 3: Check required resources in manifests
echo ""
echo "Test 3: Required resources check"
for manifest in manifests/**/*.yaml manifests/*.yaml; do
    if [ -f "$manifest" ]; then
        app_name=$(basename "$manifest" .yaml)
        echo "  Checking $app_name..."

        # Check for Deployment
        if yq eval 'select(.kind == "Deployment")' "$manifest" 2>/dev/null | grep -q "kind"; then
            echo "    ✓ Deployment resource found"
        else
            echo "    ⚠ Deployment resource not found (may be optional)"
        fi

        # Check for Service
        if yq eval 'select(.kind == "Service")' "$manifest" 2>/dev/null | grep -q "kind"; then
            echo "    ✓ Service resource found"
        else
            echo "    ⚠ Service resource not found (may be optional)"
        fi
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $ERRORS -gt 0 ]; then
    echo "✗ Integration tests failed with $ERRORS error(s)"
    exit 1
else
    echo "✓ All integration tests passed"
    exit 0
fi
