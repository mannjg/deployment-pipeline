#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/pipeline-config.sh"

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <source-env> <target-env> <image-tag> <new-image-tag>" >&2
    exit 1
fi

SOURCE_ENV="$1"
TARGET_ENV="$2"
IMAGE_TAG="$3"
NEW_IMAGE_TAG="$4"

PROMOTE_BRANCH_PREFIX="${PROMOTE_BRANCH_PREFIX:-$(pipeline_config_get '.branches.promote_prefix' 'promote-')}"
: "${PROMOTE_BRANCH_PREFIX:?PROMOTE_BRANCH_PREFIX is required}"
: "${CONTAINER_REGISTRY_EXTERNAL:?CONTAINER_REGISTRY_EXTERNAL is required}"
: "${CONTAINER_REGISTRY_PATH_PREFIX:?CONTAINER_REGISTRY_PATH_PREFIX is required}"
BUILD_URL="${BUILD_URL:-unknown}"
: "${GITLAB_URL:?GITLAB_URL is required}"

# Clean up promote temp files from workspace before git operations
rm -f promoted-image-tag promote.log

# Fetch both branches
git fetch origin "${SOURCE_ENV}" "${TARGET_ENV}"

# Create promotion branch from target
# Branch convention: promote-{env}-{appVersion}-{timestamp}
# App version extracted from image tag by stripping trailing git hash
APP_NAME=$(pipeline_config_get '.apps.default')
APP_VERSION=$(echo "${IMAGE_TAG}" | sed 's/-[a-f0-9]\\{6,\\}$//')
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PROMOTION_BRANCH="${PROMOTE_BRANCH_PREFIX}${TARGET_ENV}-${APP_VERSION}-${TIMESTAMP}"

git checkout -B "${TARGET_ENV}" "origin/${TARGET_ENV}"
git checkout -b "${PROMOTION_BRANCH}"

# Promote app config from source to target
# If we have a promoted image tag, pass it as an override so
# promote-app-config.sh writes the correct promoted image (e.g., RC)
# instead of the source image (e.g., SNAPSHOT)
IMAGE_OVERRIDE_FLAG=""
if [[ -n "${NEW_IMAGE_TAG}" ]]; then
    NEW_IMAGE="${CONTAINER_REGISTRY_EXTERNAL}/${CONTAINER_REGISTRY_PATH_PREFIX}/${APP_NAME}:${NEW_IMAGE_TAG}"
    IMAGE_OVERRIDE_FLAG="--image-override ${APP_NAME}=${NEW_IMAGE}"
    echo "Promoting with image override: ${NEW_IMAGE}"
fi

./scripts/promote-app-config.sh ${IMAGE_OVERRIDE_FLAG} "${SOURCE_ENV}" "${TARGET_ENV}" || {
    echo "ERROR: App config promotion failed"
    exit 1
}

# Regenerate manifests with promoted config
./scripts/generate-manifests.sh "${TARGET_ENV}" || {
    echo "ERROR: Manifest generation failed"
    exit 1
}

# Check if there are any changes to commit
if git diff --quiet && git diff --cached --quiet; then
    echo "No changes to promote - config already in sync"
    exit 0
fi

# Commit changes
git add -A
git commit -m "Promote ${SOURCE_ENV} to ${TARGET_ENV}

Automated promotion after successful ${SOURCE_ENV} deployment.

Source: ${SOURCE_ENV}
Target: ${TARGET_ENV}
Build: ${BUILD_URL}"

# Push promotion branch
git push -u origin "${PROMOTION_BRANCH}"

# Create MR using GitLab API
export GITLAB_URL_INTERNAL="${GITLAB_URL}"

./scripts/create-gitlab-mr.sh \
    "${PROMOTION_BRANCH}" \
    "${TARGET_ENV}" \
    "Promote ${SOURCE_ENV} to ${TARGET_ENV}" \
    "Automated promotion MR after successful ${SOURCE_ENV} deployment.

## What's Promoted
- Container images (CI/CD managed)
- Application environment variables
- ConfigMap data

## What's Preserved
- Namespace: ${TARGET_ENV}
- Replicas, resources, debug flags

---
**Source:** ${SOURCE_ENV}
**Target:** ${TARGET_ENV}
**Jenkins Build:** ${BUILD_URL}"

echo "Created promotion MR: ${PROMOTION_BRANCH} → ${TARGET_ENV}"
