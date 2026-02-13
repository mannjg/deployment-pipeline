#!/usr/bin/env bash
set -euo pipefail

# Server-side dry-run validation against the cluster.

MANIFEST_DIR="manifests"
if [ ! -d "$MANIFEST_DIR" ]; then
    echo "ERROR: Manifest directory not found: $MANIFEST_DIR"
    exit 1
fi

FAILED=0
for manifest in $(find "$MANIFEST_DIR" -name "*.yaml" -o -name "*.yml"); do
    echo "  Validating: $manifest"
    if ! kubectl apply --dry-run=server -f "$manifest" 2>&1; then
        echo "  ERROR: Dry-run failed for $manifest"
        FAILED=1
    fi
done

if [ $FAILED -ne 0 ]; then
    echo "ERROR: Server-side dry-run validation failed"
    exit 1
fi

echo "Server-side dry-run validation passed"
