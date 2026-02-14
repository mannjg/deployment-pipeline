#!/usr/bin/env bash
set -euo pipefail

if [ -x "./scripts/lib/validate-cue-config.sh" ]; then
    ./scripts/lib/validate-cue-config.sh || {
        echo "CUE validation failed"
        exit 1
    }
else
    cue vet ./env.cue || {
        echo "CUE validation failed"
        exit 1
    }
fi

echo "CUE configuration is valid"
