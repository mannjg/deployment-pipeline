#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 <target-env> <source-env> <app-name> <promote-image-tag> <promote-full-image> <mr-description-file>" >&2
    exit 1
fi

TARGET_ENV="$1"
SOURCE_ENV="$2"
APP_NAME="$3"
PROMOTE_IMAGE_TAG="$4"
PROMOTE_FULL_IMAGE="$5"
MR_DESCRIPTION_FILE="$6"

: "${PROMOTE_BRANCH_PREFIX:?PROMOTE_BRANCH_PREFIX is required}"
BUILD_URL="${BUILD_URL:-unknown}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${GITLAB_URL:?GITLAB_URL is required}"
: "${WORKSPACE:?WORKSPACE is required}"

if [[ ! -f "$MR_DESCRIPTION_FILE" ]]; then
    echo "MR description file not found: $MR_DESCRIPTION_FILE" >&2
    exit 1
fi

# Fetch target environment branch
git fetch origin "${TARGET_ENV}"
git checkout "${TARGET_ENV}"
git pull origin "${TARGET_ENV}"

# Create feature branch for this promotion
FEATURE_BRANCH="${PROMOTE_BRANCH_PREFIX}${TARGET_ENV}-${PROMOTE_IMAGE_TAG}"
git checkout -b "${FEATURE_BRANCH}"

echo "============================================"
echo "Promoting ${APP_NAME} from ${SOURCE_ENV} to ${TARGET_ENV}"
echo "============================================"
echo "Image: ${PROMOTE_FULL_IMAGE}"
echo "Feature branch: ${FEATURE_BRANCH}"
echo ""

# Update the image in target environment's env.cue
./scripts/lib/update-app-image.sh "${TARGET_ENV}" "${APP_NAME}" "${PROMOTE_FULL_IMAGE}"
echo "[${TARGET_ENV^^}] Updated ${APP_NAME} image in env.cue"

# Regenerate Kubernetes manifests for target environment
./scripts/generate-manifests.sh "${TARGET_ENV}"

# Stage all changes
git add env.cue manifests/

# Commit with promotion metadata
git commit -m "Promote ${APP_NAME} to ${TARGET_ENV}: ${PROMOTE_IMAGE_TAG}

Automated promotion from ${SOURCE_ENV} environment.

Changes:
- Updated ${TARGET_ENV} environment image to ${PROMOTE_IMAGE_TAG}
- Regenerated Kubernetes manifests

Build: ${BUILD_URL}
Image: ${PROMOTE_FULL_IMAGE}
Source environment: ${SOURCE_ENV}

Generated manifests from CUE configuration." || echo "No changes to commit"

# Delete remote branch if it exists, then push fresh
git push origin --delete "${FEATURE_BRANCH}" 2>/dev/null || echo "Branch does not exist remotely"
git push -u origin "${FEATURE_BRANCH}"

# Create MR using GitLab API
export GITLAB_URL_INTERNAL="${GITLAB_URL}"

./scripts/lib/create-gitlab-mr.sh \
    "${FEATURE_BRANCH}" \
    "${TARGET_ENV}" \
    "Promote ${APP_NAME} to ${TARGET_ENV}: ${PROMOTE_IMAGE_TAG}" \
    "$(cat "${MR_DESCRIPTION_FILE}")"
