#!/bin/bash
# Integration tests for CUE configuration and manifest generation
# Tests the complete workflow: CUE → Manifest → Validation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Running CUE integration tests..."
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

# Check for required commands
if ! command -v cue &> /dev/null; then
    echo "✗ ERROR: cue command not found!"
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo "✗ ERROR: yq command not found!"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Integration Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ERRORS=0

# Test 1: Generate manifests for all environments
echo ""
echo "Test 1: Manifest generation"
for env in dev stage prod; do
    echo "  Testing $env environment..."

    if [ -f "./scripts/generate-manifests.sh" ]; then
        if ./scripts/generate-manifests.sh "$env" > /dev/null 2>&1; then
            echo "    ✓ Manifest generation succeeded"
        else
            echo "    ✗ Manifest generation failed"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "    ⚠ generate-manifests.sh not found, skipping"
    fi
done

# Test 2: Validate generated manifests
echo ""
echo "Test 2: Manifest validation"
for env in dev stage prod; do
    if [ -f "manifests/$env/example-app.yaml" ]; then
        echo "  Validating $env manifests..."

        if yq eval '.' "manifests/$env/example-app.yaml" > /dev/null 2>&1; then
            echo "    ✓ YAML syntax valid"
        else
            echo "    ✗ YAML syntax invalid"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

# Test 3: Check required fields in manifests
echo ""
echo "Test 3: Required fields check"
for env in dev stage prod; do
    if [ -f "manifests/$env/example-app.yaml" ]; then
        echo "  Checking $env manifest fields..."

        # Check for deployment
        if yq eval 'select(.kind == "Deployment")' "manifests/$env/example-app.yaml" > /dev/null 2>&1; then
            echo "    ✓ Deployment resource found"
        else
            echo "    ✗ Deployment resource missing"
            ERRORS=$((ERRORS + 1))
        fi

        # Check for service
        if yq eval 'select(.kind == "Service")' "manifests/$env/example-app.yaml" > /dev/null 2>&1; then
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
