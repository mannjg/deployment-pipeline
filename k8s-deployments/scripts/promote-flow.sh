#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/pipeline-config.sh"

convert_to_camel_case() {
    local input="$1"
    echo "$input" | sed -E 's/([-_])([a-z])/\U\2/g' | sed 's/^./\L&/'
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/promote-flow.sh --mode <auto|manual> --source-env <env> --target-env <env> [options]

Options:
  --mode <auto|manual>           Promotion mode.
  --source-env <env>             Source environment (dev or stage).
  --target-env <env>             Target environment (stage or prod).
  --app-name <name>              App name (manual mode). Default: example-app
  --image-tag <tag>              Image tag to promote (manual mode optional).
  --full-image <image>           Full image reference (manual mode optional).
  --mr-description-file <path>   MR description file (manual mode required).
  --skip-artifact-promotion      Skip artifact promotion (auto mode only).
  -h, --help                     Show this help.
USAGE
}

MODE=""
SOURCE_ENV=""
TARGET_ENV=""
APP_NAME="$(pipeline_config_get '.apps.default')"
IMAGE_TAG=""
FULL_IMAGE=""
MR_DESCRIPTION_FILE=""
SKIP_ARTIFACT_PROMOTION="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --source-env)
            SOURCE_ENV="${2:-}"
            shift 2
            ;;
        --target-env)
            TARGET_ENV="${2:-}"
            shift 2
            ;;
        --app-name)
            APP_NAME="${2:-}"
            shift 2
            ;;
        --image-tag)
            IMAGE_TAG="${2:-}"
            shift 2
            ;;
        --full-image)
            FULL_IMAGE="${2:-}"
            shift 2
            ;;
        --mr-description-file)
            MR_DESCRIPTION_FILE="${2:-}"
            shift 2
            ;;
        --skip-artifact-promotion)
            SKIP_ARTIFACT_PROMOTION="true"
            shift 1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$MODE" || -z "$SOURCE_ENV" || -z "$TARGET_ENV" ]]; then
    usage
    exit 1
fi

if [[ "$MODE" != "auto" && "$MODE" != "manual" ]]; then
    echo "Invalid mode: $MODE (expected auto or manual)" >&2
    exit 1
fi

PROMOTE_BRANCH_PREFIX="${PROMOTE_BRANCH_PREFIX:-$(pipeline_config_get '.branches.promote_prefix')}"
export PROMOTE_BRANCH_PREFIX

if [[ "$MODE" == "auto" ]]; then
    : "${GITLAB_URL:?GITLAB_URL is required}"
    : "${GITLAB_GROUP:?GITLAB_GROUP is required}"
    : "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
    : "${WORKSPACE:?WORKSPACE is required}"

    project_name=$(pipeline_config_get '.gitlab.project')
    project_path="${GITLAB_GROUP}/${project_name}"
    encoded_project=$(echo "$project_path" | sed 's|/|%2F|g')

    export PROMOTE_ENCODED_PROJECT="$encoded_project"
    export PROMOTE_TARGET="$TARGET_ENV"

    ./scripts/pipeline close-stale-promotion-mrs

    app_name="${APP_NAME:-$(pipeline_config_get '.apps.default')}"
    export APP_NAME="$app_name"
    app_cue_name="$(convert_to_camel_case "$app_name")"
    env_file_content=$(./scripts/gitlab-api.sh GET \
        "${GITLAB_URL}/api/v4/projects/${encoded_project}/repository/files/env.cue?ref=${SOURCE_ENV}" \
        2>/dev/null | jq -r '.content' | base64 -d)

    source_image_tag=$(echo "$env_file_content" | awk -v env="${SOURCE_ENV}" -v app="${app_cue_name}" '
        BEGIN { in_block=0 }
        $0 ~ ("^" env ":[[:space:]]*" app "([[:space:]]|:)") { in_block=1 }
        in_block && $0 ~ ("^" env ":[[:space:]]*[A-Za-z0-9_-]+:") && $0 !~ ("^" env ":[[:space:]]*" app "([[:space:]]|:)") { exit }
        in_block && $0 ~ /image:[[:space:]]*"/ {
            match($0, /image:[[:space:]]*"([^"]+)"/, m)
            if (m[1] != "") { print m[1]; exit }
        }
    ')

    if [[ -z "$source_image_tag" ]]; then
        source_image_tag=$(echo "$env_file_content" | grep 'image:' | \
            sed -E 's/.*image:[[:space:]]*"([^"]+)".*/\1/' | head -1)
    fi

    if [[ -z "$source_image_tag" ]]; then
        echo "ERROR: Could not extract image tag from ${SOURCE_ENV} env.cue" >&2
        exit 1
    fi

    if [[ "$source_image_tag" == *:* ]]; then
        IMAGE_TAG="${source_image_tag##*:}"
    else
        IMAGE_TAG="$source_image_tag"
    fi

    git_hash=$(echo "$IMAGE_TAG" | grep -oE '[a-f0-9]{6,}$' || true)

    if [[ -z "$IMAGE_TAG" ]]; then
        echo "ERROR: Cannot create promotion MR: no image tag found in ${SOURCE_ENV} env.cue" >&2
        exit 1
    fi

    new_image_tag=""
    if [[ -n "$git_hash" && "$SKIP_ARTIFACT_PROMOTION" != "true" ]]; then
        if ! ./scripts/pipeline promote-artifacts "$SOURCE_ENV" "$TARGET_ENV" "$git_hash"; then
            echo "Artifact promotion output:"
            cat "${WORKSPACE}/promote.log" 2>/dev/null || true
            echo "Artifact promotion failed - cannot create promotion MR without valid image tag. If release version already exists in Nexus, bump the version in pom.xml." >&2
            exit 1
        fi
        if [[ -f "${WORKSPACE}/promoted-image-tag" ]]; then
            new_image_tag=$(cat "${WORKSPACE}/promoted-image-tag")
        fi
    fi

    ./scripts/pipeline create-promotion-branch-mr "$SOURCE_ENV" "$TARGET_ENV" "$IMAGE_TAG" "$new_image_tag"
    exit 0
fi

# manual mode
: "${GITLAB_URL:?GITLAB_URL is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${WORKSPACE:?WORKSPACE is required}"

if [[ -z "$APP_NAME" ]]; then
    echo "ERROR: --app-name is required in manual mode" >&2
    exit 1
fi

if [[ -z "$IMAGE_TAG" ]]; then
    current_image=$(kubectl get deployment "$APP_NAME" -n "$SOURCE_ENV" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

    if [[ -z "$current_image" ]]; then
        echo "ERROR: Could not detect image for ${APP_NAME} in ${SOURCE_ENV} namespace." >&2
        echo "Check: kubectl get deployment ${APP_NAME} -n ${SOURCE_ENV}" >&2
        exit 1
    fi

    IMAGE_TAG="${current_image##*:}"
fi

if [[ -z "$FULL_IMAGE" ]]; then
    : "${DEPLOY_REGISTRY:?DEPLOY_REGISTRY is required}"
    : "${APP_GROUP:?APP_GROUP is required}"
    FULL_IMAGE="${DEPLOY_REGISTRY}/${APP_GROUP}/${APP_NAME}:${IMAGE_TAG}"
fi

if [[ -z "$MR_DESCRIPTION_FILE" ]]; then
    echo "ERROR: --mr-description-file is required in manual mode" >&2
    exit 1
fi

if [[ ! -f "$MR_DESCRIPTION_FILE" ]]; then
    echo "ERROR: MR description file not found: $MR_DESCRIPTION_FILE" >&2
    exit 1
fi

./scripts/pipeline promote-env "$TARGET_ENV" "$SOURCE_ENV" "$APP_NAME" "$IMAGE_TAG" "$FULL_IMAGE" "$MR_DESCRIPTION_FILE"
