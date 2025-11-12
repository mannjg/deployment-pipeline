#!/bin/bash
# Test script to verify that updating one app's image doesn't affect other apps
# This tests the fix for the image replacement bug

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DEPLOYMENTS_DIR="${SCRIPT_DIR}/k8s-deployments"

cd "$K8S_DEPLOYMENTS_DIR"

log_info "=========================================="
log_info "  Image Update Isolation Test"
log_info "=========================================="
echo

# Step 1: Capture baseline images
log_info "Step 1: Capturing baseline images..."
BEFORE_EXAMPLE_APP=$(cue export ./envs/dev.cue -e 'dev.exampleApp.appConfig.deployment.image' --out text)
BEFORE_POSTGRES=$(cue export ./envs/dev.cue -e 'dev.postgres.appConfig.deployment.image' --out text)

log_info "Baseline images:"
log_info "  example-app: $BEFORE_EXAMPLE_APP"
log_info "  postgres:    $BEFORE_POSTGRES"
echo

# Step 2: Update example-app image (simulating Jenkins pipeline)
log_info "Step 2: Updating example-app image..."
NEW_EXAMPLE_APP_IMAGE="docker.local/example/example-app:test-$(date +%s)"

log_info "Running: ./scripts/update-app-image.sh dev example-app \"$NEW_EXAMPLE_APP_IMAGE\""
if ./scripts/update-app-image.sh dev example-app "$NEW_EXAMPLE_APP_IMAGE" > /tmp/update-output.log 2>&1; then
    log_pass "Image update script succeeded"
else
    log_fail "Image update script failed"
    cat /tmp/update-output.log
    exit 1
fi
echo

# Step 3: Verify example-app image changed
log_info "Step 3: Verifying example-app image updated..."
AFTER_EXAMPLE_APP=$(cue export ./envs/dev.cue -e 'dev.exampleApp.appConfig.deployment.image' --out text)

if [ "$AFTER_EXAMPLE_APP" = "$NEW_EXAMPLE_APP_IMAGE" ]; then
    log_pass "✓ example-app image updated correctly"
    log_info "  Before: $BEFORE_EXAMPLE_APP"
    log_info "  After:  $AFTER_EXAMPLE_APP"
else
    log_fail "✗ example-app image did not update correctly"
    log_error "  Expected: $NEW_EXAMPLE_APP_IMAGE"
    log_error "  Got:      $AFTER_EXAMPLE_APP"
    git checkout envs/dev.cue
    exit 1
fi
echo

# Step 4: Verify postgres image did NOT change
log_info "Step 4: Verifying postgres image unchanged..."
AFTER_POSTGRES=$(cue export ./envs/dev.cue -e 'dev.postgres.appConfig.deployment.image' --out text)

if [ "$AFTER_POSTGRES" = "$BEFORE_POSTGRES" ]; then
    log_pass "✓ postgres image remained unchanged"
    log_info "  Before: $BEFORE_POSTGRES"
    log_info "  After:  $AFTER_POSTGRES"
else
    log_fail "✗ postgres image was incorrectly modified!"
    log_error "  Expected: $BEFORE_POSTGRES"
    log_error "  Got:      $AFTER_POSTGRES"
    log_error "This indicates the image update affected multiple apps"
    git checkout envs/dev.cue
    exit 1
fi
echo

# Step 5: Test updating postgres (reverse scenario)
log_info "Step 5: Testing postgres image update (should not affect example-app)..."
NEW_POSTGRES_IMAGE="postgres:17-test"

log_info "Running: ./scripts/update-app-image.sh dev postgres \"$NEW_POSTGRES_IMAGE\""
if ./scripts/update-app-image.sh dev postgres "$NEW_POSTGRES_IMAGE" > /tmp/update-output2.log 2>&1; then
    log_pass "Postgres image update script succeeded"
else
    log_fail "Postgres image update script failed"
    cat /tmp/update-output2.log
    git checkout envs/dev.cue
    exit 1
fi
echo

# Step 6: Verify postgres updated but example-app didn't change
log_info "Step 6: Verifying updates were isolated..."
FINAL_POSTGRES=$(cue export ./envs/dev.cue -e 'dev.postgres.appConfig.deployment.image' --out text)
FINAL_EXAMPLE_APP=$(cue export ./envs/dev.cue -e 'dev.exampleApp.appConfig.deployment.image' --out text)

SUCCESS=true

if [ "$FINAL_POSTGRES" = "$NEW_POSTGRES_IMAGE" ]; then
    log_pass "✓ postgres image updated correctly"
    log_info "  Updated: $BEFORE_POSTGRES → $FINAL_POSTGRES"
else
    log_fail "✗ postgres image did not update"
    log_error "  Expected: $NEW_POSTGRES_IMAGE"
    log_error "  Got:      $FINAL_POSTGRES"
    SUCCESS=false
fi

if [ "$FINAL_EXAMPLE_APP" = "$NEW_EXAMPLE_APP_IMAGE" ]; then
    log_pass "✓ example-app image remained at its updated value"
    log_info "  Image: $FINAL_EXAMPLE_APP"
else
    log_fail "✗ example-app image was incorrectly modified during postgres update!"
    log_error "  Expected: $NEW_EXAMPLE_APP_IMAGE"
    log_error "  Got:      $FINAL_EXAMPLE_APP"
    SUCCESS=false
fi
echo

# Step 7: Restore original state
log_info "Step 7: Restoring original environment configuration..."
git checkout envs/dev.cue
log_pass "Restored dev.cue to original state"
echo

# Final result
log_info "=========================================="
if [ "$SUCCESS" = true ]; then
    log_pass "  ALL TESTS PASSED ✓"
    log_info "=========================================="
    echo
    log_info "Summary:"
    log_info "  ✓ example-app image can be updated independently"
    log_info "  ✓ postgres image can be updated independently"
    log_info "  ✓ Updates to one app do not affect other apps"
    log_info "  ✓ Image update isolation is working correctly"
    echo
    exit 0
else
    log_fail "  TESTS FAILED ✗"
    log_info "=========================================="
    echo
    log_error "One or more tests failed - see above for details"
    echo
    exit 1
fi
