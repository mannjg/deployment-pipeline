#!/bin/bash
# Promote artifacts from one environment version to another
# Re-deploys Maven JAR with new version, re-tags Docker image
#
# Version progression:
#   dev -> stage:  SNAPSHOT -> RC (e.g., 1.0.0-SNAPSHOT -> 1.0.0-rc1)
#   stage -> prod: RC -> Release (e.g., 1.0.0-rc1 -> 1.0.0)
#
# Usage:
#   ./scripts/promote-artifact.sh \
#     --source-env dev \
#     --target-env stage \
#     --app-name example-app \
#     --git-hash abc123

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load preflight library and local config
source "${SCRIPT_DIR}/lib/preflight.sh"
preflight_load_local_env "$SCRIPT_DIR"

# Check required commands
preflight_check_command "curl" "apt-get install curl"
preflight_check_command "jq" "https://stedolan.github.io/jq/download/"
preflight_check_command "docker" "https://docs.docker.com/get-docker/"
preflight_check_command "mvn" "https://maven.apache.org/install.html"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*" >&2; }

# Parse arguments
SOURCE_ENV=""
TARGET_ENV=""
APP_NAME=""
GIT_HASH=""

show_help() {
    cat << EOF
Usage: $0 --source-env <env> --target-env <env> --app-name <name> --git-hash <hash>

Promote artifacts from one environment version to another.
Re-deploys Maven JAR with new version coordinates, re-tags Docker image.

Arguments:
  --source-env    Source environment (dev, stage)
  --target-env    Target environment (stage, prod)
  --app-name      Application name (e.g., example-app)
  --git-hash      Git commit hash (short or full)

Version Progression:
  dev -> stage:   SNAPSHOT -> RC (increments RC number automatically)
  stage -> prod:  RC -> Release (fails if release exists)

Environment Variables:
  NEXUS_URL         Nexus base URL (default: http://nexus.nexus.svc.cluster.local:8081)
  NEXUS_USER        Nexus username (optional, for authenticated repos)
  NEXUS_PASSWORD    Nexus password (optional, for authenticated repos)
  DOCKER_REGISTRY   Docker registry URL (default: nexus.nexus.svc.cluster.local:5000)
  MAVEN_GROUP_ID    Maven group ID (default: com.example)
  GITLAB_URL        GitLab URL for fetching env.cue (default: from GITLAB_URL_INTERNAL)
  GITLAB_TOKEN      GitLab API token
  GITLAB_PROJECT    GitLab project path (default: p2c/k8s-deployments)

Example:
  $0 --source-env dev --target-env stage --app-name example-app --git-hash abc123f

Output:
  On success, prints the new image tag as the last line of stdout.
  All other output goes to stderr for easy capture:
    NEW_TAG=\$($0 --source-env dev --target-env stage --app-name example-app --git-hash abc123)
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        --source-env) SOURCE_ENV="$2"; shift 2 ;;
        --target-env) TARGET_ENV="$2"; shift 2 ;;
        --app-name) APP_NAME="$2"; shift 2 ;;
        --git-hash) GIT_HASH="$2"; shift 2 ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# Validate required arguments
[[ -z "$SOURCE_ENV" ]] && { log_error "--source-env required"; exit 1; }
[[ -z "$TARGET_ENV" ]] && { log_error "--target-env required"; exit 1; }
[[ -z "$APP_NAME" ]] && { log_error "--app-name required"; exit 1; }
[[ -z "$GIT_HASH" ]] && { log_error "--git-hash required"; exit 1; }

# Validate environments
for env in "$SOURCE_ENV" "$TARGET_ENV"; do
    case $env in
        dev|stage|prod) ;;
        *)
            log_error "Invalid environment: $env (must be dev, stage, or prod)"
            exit 1
            ;;
    esac
done

if [[ "$SOURCE_ENV" == "$TARGET_ENV" ]]; then
    log_error "Source and target environments must be different"
    exit 1
fi

# Validate promotion path
case "$SOURCE_ENV-$TARGET_ENV" in
    dev-stage|stage-prod) ;;
    *)
        log_error "Invalid promotion path: $SOURCE_ENV -> $TARGET_ENV"
        log_error "Supported paths: dev->stage, stage->prod"
        exit 1
        ;;
esac

# Configuration (from environment or defaults)
NEXUS_URL="${NEXUS_URL:-http://nexus.nexus.svc.cluster.local:8081}"
# Prefer external registry (HTTPS) for Docker operations - Docker daemon may not trust internal HTTP registry
DOCKER_REGISTRY="${DOCKER_REGISTRY_EXTERNAL:-${DOCKER_REGISTRY:-nexus.nexus.svc.cluster.local:5000}}"
MAVEN_GROUP_ID="${MAVEN_GROUP_ID:-com.example}"
GITLAB_URL="${GITLAB_URL:-${GITLAB_URL_INTERNAL:-http://gitlab.gitlab.svc.cluster.local}}"
GITLAB_PROJECT="${GITLAB_PROJECT:-p2c/k8s-deployments}"

# Normalize git hash to short form (7 chars) for consistency
GIT_HASH="${GIT_HASH:0:7}"

log_debug "Configuration:"
log_debug "  NEXUS_URL: $NEXUS_URL"
log_debug "  DOCKER_REGISTRY: $DOCKER_REGISTRY"
log_debug "  MAVEN_GROUP_ID: $MAVEN_GROUP_ID"
log_debug "  GITLAB_URL: $GITLAB_URL"
log_debug "  GITLAB_PROJECT: $GITLAB_PROJECT"

# =============================================================================
# Maven Settings Management
# =============================================================================

# Global variable for settings file path (set by create_maven_settings)
MAVEN_SETTINGS_FILE=""

# Create Maven settings.xml with Nexus repository definitions
# This enables Maven to resolve SNAPSHOT artifacts from Nexus
create_maven_settings() {
    MAVEN_SETTINGS_FILE=$(mktemp --suffix="-maven-settings.xml")

    # Build server credentials block if credentials are provided
    local servers_block=""
    if [[ -n "${NEXUS_USER:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
        servers_block="<servers>
    <server>
      <id>nexus-snapshots</id>
      <username>${NEXUS_USER}</username>
      <password>${NEXUS_PASSWORD}</password>
    </server>
    <server>
      <id>nexus-releases</id>
      <username>${NEXUS_USER}</username>
      <password>${NEXUS_PASSWORD}</password>
    </server>
    <server>
      <id>nexus</id>
      <username>${NEXUS_USER}</username>
      <password>${NEXUS_PASSWORD}</password>
    </server>
  </servers>"
    fi

    cat > "$MAVEN_SETTINGS_FILE" << SETTINGS_EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <!--
    Maven 3.8.1+ blocks HTTP repositories by default for security.
    We explicitly allow HTTP here because:
    - Nexus is on an internal/airgapped network with no external exposure
    - TLS termination happens at the ingress layer (if applicable)
    To use HTTPS instead, update NEXUS_URL to https:// and remove this mirror.
  -->
  <mirrors>
    <mirror>
      <id>internal-nexus-http-allowed</id>
      <mirrorOf>external:http:*</mirrorOf>
      <url>${NEXUS_URL}/repository/maven-public/</url>
      <blocked>false</blocked>
    </mirror>
  </mirrors>
  ${servers_block}
  <profiles>
    <profile>
      <id>nexus</id>
      <repositories>
        <repository>
          <id>nexus-snapshots</id>
          <url>${NEXUS_URL}/repository/maven-snapshots/</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled><updatePolicy>always</updatePolicy></snapshots>
        </repository>
        <repository>
          <id>nexus-releases</id>
          <url>${NEXUS_URL}/repository/maven-releases/</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>false</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>nexus</activeProfile>
  </activeProfiles>
</settings>
SETTINGS_EOF

    log_debug "Created Maven settings at: $MAVEN_SETTINGS_FILE"
}

# Cleanup temporary files (Maven settings and temp directory)
# Note: Silent cleanup to avoid interfering with stdout output that Jenkinsfile captures
cleanup_temp_files() {
    if [[ -n "${MAVEN_SETTINGS_FILE:-}" && -f "$MAVEN_SETTINGS_FILE" ]]; then
        rm -f "$MAVEN_SETTINGS_FILE"
    fi
    if [[ -n "${TMP_DIR_PROMOTE:-}" && -d "$TMP_DIR_PROMOTE" ]]; then
        rm -rf "$TMP_DIR_PROMOTE"
    fi
}

# =============================================================================
# Version Parsing Functions
# =============================================================================

# Extract base version from image tag (e.g., "1.0.0" from "1.0.0-SNAPSHOT-abc123")
extract_base_version() {
    local image_tag="$1"
    # Remove git hash suffix (last component after -)
    # Remove SNAPSHOT or rcN suffix
    echo "$image_tag" | sed -E 's/-[a-f0-9]{6,}$//' | sed -E 's/-(SNAPSHOT|rc[0-9]+)$//'
}

# Extract git hash from image tag (e.g., "abc123" from "1.0.0-SNAPSHOT-abc123")
extract_git_hash() {
    local image_tag="$1"
    echo "$image_tag" | grep -oE '[a-f0-9]{6,}$' || echo ""
}

# Get current image tag from env.cue for a given environment
get_current_image_tag() {
    local env="$1"
    local env_cue_content

    # Check for GitLab token
    if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        log_error "GITLAB_TOKEN not set - required to fetch env.cue from GitLab"
        return 1
    fi

    # Fetch env.cue from GitLab for the environment branch
    local encoded_project
    encoded_project=$(echo "$GITLAB_PROJECT" | sed 's/\//%2F/g')

    local api_url="${GITLAB_URL}/api/v4/projects/${encoded_project}/repository/files/env.cue?ref=${env}"
    log_debug "Fetching env.cue from: $api_url"

    local http_response
    http_response=$(curl -sf -w "%{http_code}" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$api_url" 2>/dev/null) || {
        log_error "Failed to fetch env.cue from GitLab for branch: $env (curl error)"
        return 1
    }

    local http_code="${http_response: -3}"
    local response_body="${http_response:0:-3}"

    if [[ "$http_code" != "200" ]]; then
        log_error "Failed to fetch env.cue from GitLab for branch: $env (HTTP $http_code)"
        return 1
    fi

    env_cue_content=$(echo "$response_body" | jq -r '.content' | base64 -d) || {
        log_error "Failed to parse env.cue content from GitLab response"
        return 1
    }

    # Extract image tag from env.cue
    # Look for pattern: image: "registry/path/app:TAG"
    local full_image
    full_image=$(echo "$env_cue_content" | grep 'image:' | sed -E 's/.*image:\s*"([^"]+)".*/\1/' | head -1) || {
        log_error "Could not extract image from env.cue"
        return 1
    }

    # Extract just the tag portion (after the last colon)
    echo "$full_image" | sed 's/.*://'
}

# =============================================================================
# Nexus Query Functions
# =============================================================================

# Check if artifact exists in Nexus
nexus_artifact_exists() {
    local version="$1"
    local repository="$2"

    local search_url="${NEXUS_URL}/service/rest/v1/search?repository=${repository}&group=${MAVEN_GROUP_ID}&name=${APP_NAME}&version=${version}"
    log_debug "Checking Nexus for artifact: $search_url"

    local result
    result=$(curl -sf "$search_url" 2>/dev/null | jq -r '.items | length') || {
        log_warn "Failed to query Nexus, assuming artifact does not exist"
        echo "0"
        return 1
    }

    [[ "$result" -gt 0 ]]
}

# Get next RC number for a base version
get_next_rc_number() {
    local base_version="$1"

    # Query Nexus for existing RCs of this version
    local search_url="${NEXUS_URL}/service/rest/v1/search?repository=maven-releases&group=${MAVEN_GROUP_ID}&name=${APP_NAME}&version=${base_version}-rc*"
    log_debug "Searching for existing RCs: $search_url"

    local existing_rcs
    existing_rcs=$(curl -sf "$search_url" 2>/dev/null | jq -r '.items[].version' 2>/dev/null | grep -o 'rc[0-9]\+' | sed 's/rc//' | sort -n | tail -1) || true

    if [[ -z "$existing_rcs" ]]; then
        echo "1"
    else
        echo "$((existing_rcs + 1))"
    fi
}

# Download JAR from Nexus using Maven (handles SNAPSHOT resolution automatically)
download_jar() {
    local version="$1"
    local repository="$2"
    local output_file="$3"

    local output_dir
    output_dir=$(dirname "$output_file")

    log_info "Downloading ${MAVEN_GROUP_ID}:${APP_NAME}:${version} from ${repository}"

    # Use Maven with settings.xml to resolve the artifact
    # Settings file contains repository definitions for SNAPSHOT resolution
    if ! mvn dependency:copy \
        -s "$MAVEN_SETTINGS_FILE" \
        -Dartifact="${MAVEN_GROUP_ID}:${APP_NAME}:${version}:jar" \
        -DoutputDirectory="$output_dir" \
        -Dmdep.stripVersion=true \
        -q; then
        log_error "Failed to download artifact via Maven"
        log_error "Artifact: ${MAVEN_GROUP_ID}:${APP_NAME}:${version}"
        log_error "Check that the artifact exists in Nexus and settings are correct"
        return 1
    fi

    # Maven outputs as APP_NAME.jar (due to stripVersion), rename to expected location
    local maven_output="$output_dir/${APP_NAME}.jar"
    if [[ "$maven_output" != "$output_file" ]]; then
        mv "$maven_output" "$output_file"
    fi

    log_info "Downloaded to: $output_file"
}

# Deploy JAR to Nexus with new version
deploy_jar() {
    local jar_file="$1"
    local new_version="$2"
    local repository="$3"

    log_info "Deploying JAR as version $new_version to $repository"

    local deploy_url="${NEXUS_URL}/repository/${repository}"

    # Use settings.xml for credentials (repositoryId=nexus matches server id)
    mvn deploy:deploy-file \
        -s "$MAVEN_SETTINGS_FILE" \
        -DgroupId="${MAVEN_GROUP_ID}" \
        -DartifactId="${APP_NAME}" \
        -Dversion="${new_version}" \
        -Dpackaging=jar \
        -Dfile="$jar_file" \
        -DrepositoryId=nexus \
        -Durl="$deploy_url" \
        -DgeneratePom=true \
        -q || {
        log_error "Failed to deploy JAR to Nexus"
        return 1
    }

    log_info "Successfully deployed ${APP_NAME}:${new_version} to ${repository}"
}

# =============================================================================
# Docker Re-tagging Functions
# =============================================================================

# Re-tag and push Docker image
retag_docker_image() {
    local source_tag="$1"
    local target_tag="$2"

    local source_image="${DOCKER_REGISTRY}/p2c/${APP_NAME}:${source_tag}"
    local target_image="${DOCKER_REGISTRY}/p2c/${APP_NAME}:${target_tag}"

    log_info "Re-tagging Docker image: $source_tag -> $target_tag"
    log_debug "Source: $source_image"
    log_debug "Target: $target_image"

    # Login to Docker registry if credentials provided
    if [[ -n "${NEXUS_USER:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
        log_debug "Logging into Docker registry: $DOCKER_REGISTRY"
        echo "$NEXUS_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$NEXUS_USER" --password-stdin || {
            log_error "Failed to login to Docker registry"
            return 1
        }
    fi

    # Pull source image
    if ! docker pull "$source_image"; then
        log_error "Failed to pull source image: $source_image"
        return 1
    fi

    # Tag with new version
    docker tag "$source_image" "$target_image"

    # Push new tag
    if ! docker push "$target_image"; then
        log_error "Failed to push target image: $target_image"
        return 1
    fi

    log_info "Successfully re-tagged and pushed: $target_image"
}

# =============================================================================
# Main Promotion Logic
# =============================================================================

main() {
    log_info "=== Artifact Promotion: $SOURCE_ENV -> $TARGET_ENV ==="
    log_info "App: $APP_NAME, Git Hash: $GIT_HASH"

    # Create Maven settings for Nexus access
    create_maven_settings
    # Cleanup on early exit (errors) - for success path, cleanup is called manually
    # before final output to ensure the image tag is the absolute last line of stdout
    trap cleanup_temp_files EXIT

    # Get source image tag
    local source_image_tag
    source_image_tag=$(get_current_image_tag "$SOURCE_ENV") || {
        log_error "Could not determine source image tag from $SOURCE_ENV env.cue"
        exit 1
    }
    log_info "Source image tag: $source_image_tag"

    # Extract base version
    local base_version
    base_version=$(extract_base_version "$source_image_tag")
    log_info "Base version: $base_version"

    # Determine source and target versions
    local source_version=""
    local target_version=""
    local target_image_tag=""
    local source_repo=""
    local target_repo="maven-releases"

    case "$SOURCE_ENV-$TARGET_ENV" in
        dev-stage)
            source_version="${base_version}-SNAPSHOT"
            source_repo="maven-snapshots"

            # Check if same git hash already promoted (skip if so)
            local current_stage_tag=""
            current_stage_tag=$(get_current_image_tag "stage" 2>/dev/null) || true

            if [[ -n "$current_stage_tag" ]]; then
                local current_stage_hash
                current_stage_hash=$(extract_git_hash "$current_stage_tag")

                if [[ "$current_stage_hash" == "$GIT_HASH" ]]; then
                    log_info "Same git hash already in stage - skipping promotion"
                    echo "$current_stage_tag"
                    exit 0
                fi
            fi

            local rc_num
            rc_num=$(get_next_rc_number "$base_version")
            target_version="${base_version}-rc${rc_num}"
            target_image_tag="${target_version}-${GIT_HASH}"
            ;;
        stage-prod)
            # Get RC version from stage (remove git hash suffix)
            source_version=$(echo "$source_image_tag" | sed -E "s/-${GIT_HASH}$//")
            source_repo="maven-releases"
            target_version="${base_version}"
            target_image_tag="${target_version}-${GIT_HASH}"

            # Check if release already exists
            if nexus_artifact_exists "$target_version" "maven-releases"; then
                log_error "Release version $target_version already exists in Nexus"
                log_error "Cannot promote to prod with existing release version."
                log_error "Bump the base version in pom.xml (e.g., ${base_version}-SNAPSHOT -> next version)"
                exit 1
            fi
            ;;
    esac

    log_info "Source version: $source_version ($source_repo)"
    log_info "Target version: $target_version ($target_repo)"
    log_info "Target image tag: $target_image_tag"

    # Create temp directory for JAR
    # Note: Using global variable so cleanup function can access it
    TMP_DIR_PROMOTE=$(mktemp -d)

    # Download source JAR
    local jar_file="$TMP_DIR_PROMOTE/${APP_NAME}.jar"
    download_jar "$source_version" "$source_repo" "$jar_file"

    # Deploy with new version
    deploy_jar "$jar_file" "$target_version" "$target_repo"

    # Re-tag Docker image
    local source_docker_tag="${source_version}-${GIT_HASH}"
    retag_docker_image "$source_docker_tag" "$target_image_tag"

    log_info "=== Promotion Complete ==="
    log_info "New image tag: $target_image_tag"

    # Cleanup before final output to ensure tag is the last line
    cleanup_temp_files

    # Output the new image tag (for caller to capture)
    # MUST be the absolute last line of output for Jenkinsfile to capture
    echo "$target_image_tag"
}

main
