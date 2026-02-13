#!/usr/bin/env bash
set -euo pipefail

PIPELINE_CONFIG_FILE="${PIPELINE_CONFIG_FILE:-config/pipeline.json}"

pipeline_config_get() {
    local jq_path="$1"

    if [[ ! -f "$PIPELINE_CONFIG_FILE" ]]; then
        echo "Pipeline config not found: $PIPELINE_CONFIG_FILE" >&2
        exit 1
    fi

    local value
    value=$(jq -r "$jq_path // empty" "$PIPELINE_CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "Missing required pipeline config key: $jq_path" >&2
        exit 1
    fi

    echo "$value"
}
