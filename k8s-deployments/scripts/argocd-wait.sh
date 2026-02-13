#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <app-name> <timeout-seconds>" >&2
    exit 1
fi

APP_NAME="$1"
TIMEOUT_SECONDS="$2"

argocd app wait "${APP_NAME}" \
    --timeout "${TIMEOUT_SECONDS}" \
    --health \
    --sync || {
    echo "ERROR: ${APP_NAME} failed to sync or become healthy"
    argocd app get "${APP_NAME}"
    exit 1
}

echo "${APP_NAME} synced and healthy"
