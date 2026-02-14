#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/pipeline-config.sh"

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <source-env> <target-env> <git-hash>" >&2
    exit 1
fi

SOURCE_ENV="$1"
TARGET_ENV="$2"
GIT_HASH="$3"
APP_NAME="${APP_NAME:-$(pipeline_config_get '.apps.default')}"

: "${NEXUS_USER:?NEXUS_USER is required}"
: "${NEXUS_PASSWORD:?NEXUS_PASSWORD is required}"
: "${MAVEN_REPO_URL_INTERNAL:?MAVEN_REPO_URL_INTERNAL is required}"
: "${CONTAINER_REGISTRY_EXTERNAL:?CONTAINER_REGISTRY_EXTERNAL is required}"
: "${CONTAINER_REGISTRY_PATH_PREFIX:?CONTAINER_REGISTRY_PATH_PREFIX is required}"
: "${GITLAB_URL_INTERNAL:?GITLAB_URL_INTERNAL is required}"
: "${GITLAB_GROUP:?GITLAB_GROUP is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${WORKSPACE:?WORKSPACE is required}"

export NEXUS_USER
export NEXUS_PASSWORD
export MAVEN_REPO_URL_INTERNAL
export CONTAINER_REGISTRY_EXTERNAL
export CONTAINER_REGISTRY_PATH_PREFIX
export GITLAB_URL_INTERNAL
export GITLAB_GROUP
export GITLAB_TOKEN
export PROMOTED_IMAGE_TAG_FILE="${WORKSPACE}/promoted-image-tag"

bash ./scripts/lib/promote-artifact.sh \
    --source-env "${SOURCE_ENV}" \
    --target-env "${TARGET_ENV}" \
    --app-name "${APP_NAME}" \
    --git-hash "${GIT_HASH}" \
    2>&1 | tee "${WORKSPACE}/promote.log"
