#!/bin/bash
# GitLab CLI - Centralized GitLab API operations
#
# Usage:
#   gitlab-cli.sh mr list <project> [--state opened] [--target dev]
#   gitlab-cli.sh mr merge <project> <iid>
#   gitlab-cli.sh mr close <project> <iid>
#   gitlab-cli.sh branch list <project> [--pattern "update-*"]
#   gitlab-cli.sh branch delete <project> <branch>
#   gitlab-cli.sh file get <project> <path> [--ref main]
#   gitlab-cli.sh file update <project> <path> --ref <branch> --content <content> --message <msg>
#   gitlab-cli.sh commit list <project> [--ref main] [--limit 10]
#   gitlab-cli.sh env image <project> <environment> [--app exampleApp]
#   gitlab-cli.sh user
#
# Project notation: Use path like p2c/example-app (auto URL-encoded)
#
# Examples:
#   gitlab-cli.sh mr list p2c/k8s-deployments --state opened --target dev
#   gitlab-cli.sh mr merge p2c/k8s-deployments 123
#   gitlab-cli.sh branch list p2c/k8s-deployments --pattern "update-dev-*"
#   gitlab-cli.sh file get p2c/k8s-deployments env.cue --ref stage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$SCRIPT_DIR/../lib/infra.sh"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get GitLab auth once
GITLAB_TOKEN=$(require_gitlab_token)
GITLAB_URL="${GITLAB_URL_EXTERNAL}"

# URL-encode project path (p2c/example-app -> p2c%2Fexample-app)
encode_project() {
    echo "$1" | sed 's|/|%2F|g'
}

# URL-encode file path for API
encode_path() {
    echo "$1" | sed 's|/|%2F|g'
}

# Make GitLab API request
# Usage: gitlab_api GET /projects/p2c%2Fexample-app/merge_requests
# Usage: gitlab_api PUT /projects/p2c%2Fexample-app/merge_requests/123/merge
gitlab_api() {
    local method="$1"
    local endpoint="$2"
    shift 2

    local url="${GITLAB_URL}/api/v4${endpoint}"
    local response

    if ! response=$(curl -sk -X "$method" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$@" "$url" 2>/dev/null); then
        log_error "GitLab API request failed: $method $endpoint"
        return 1
    fi

    # Check for error response
    if echo "$response" | jq -e '.error // .message' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.error // .message // "Unknown error"')
        if [[ "$error_msg" != "null" && "$error_msg" != "Unknown error" ]]; then
            log_error "GitLab API error: $error_msg"
            return 1
        fi
    fi

    echo "$response"
}

show_help() {
    cat << 'EOF'
GitLab CLI - Centralized GitLab API operations

Usage:
  gitlab-cli.sh <command> <subcommand> [args] [options]

Commands:
  mr list <project> [options]       List merge requests
    --state <state>                 Filter by state: opened, merged, closed, all (default: opened)
    --target <branch>               Filter by target branch: dev, stage, prod

  mr merge <project> <iid>          Merge a merge request

  mr close <project> <iid>          Close a merge request

  branch list <project> [options]   List branches
    --pattern <glob>                Filter by pattern (e.g., "update-dev-*")

  branch delete <project> <branch>  Delete a branch

  file get <project> <path> [opts]  Get file content
    --ref <branch>                  Branch/tag/commit (default: main)

  file update <project> <path> [opts]  Update file content
    --ref <branch>                  Branch to update (required)
    --content <content>             New file content (required)
    --message <msg>                 Commit message (required)

  commit list <project> [options]   List recent commits
    --ref <branch>                  Branch/tag (default: main)
    --limit <n>                     Number of commits (default: 10)

  env image <project> <env>         Get deployed image tag for an environment
    --app <name>                    App name in CUE (default: exampleApp)

  user                              Show authenticated user info

Project Notation:
  Use path format: p2c/example-app, p2c/k8s-deployments
  Automatically URL-encoded for API requests.

Examples:
  gitlab-cli.sh mr list p2c/k8s-deployments --state opened --target dev
  gitlab-cli.sh mr merge p2c/k8s-deployments 634
  gitlab-cli.sh mr close p2c/k8s-deployments 634
  gitlab-cli.sh branch list p2c/k8s-deployments --pattern "promote-*"
  gitlab-cli.sh branch delete p2c/k8s-deployments promote-stage-20260124
  gitlab-cli.sh file get p2c/k8s-deployments env.cue --ref stage
  gitlab-cli.sh commit list p2c/k8s-deployments --ref stage --limit 5
  gitlab-cli.sh env image p2c/k8s-deployments dev
  gitlab-cli.sh env image p2c/k8s-deployments stage --app exampleApp
  gitlab-cli.sh user

Exit Codes:
  0 - Success
  1 - Error (network, auth, not found)
EOF
    exit 0
}

# =============================================================================
# MR Commands
# =============================================================================

cmd_mr_list() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: gitlab-cli.sh mr list <project> [--state opened] [--target branch]"
        exit 1
    fi

    local project="$1"
    shift

    local state="opened"
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state) state="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local encoded_project
    encoded_project=$(encode_project "$project")

    local endpoint="/projects/${encoded_project}/merge_requests?state=${state}"
    [[ -n "$target" ]] && endpoint="${endpoint}&target_branch=${target}"

    local response
    response=$(gitlab_api GET "$endpoint") || exit 1

    echo "$response" | jq -r '.[] | {iid, source_branch, target_branch, state, title, web_url}'
}

cmd_mr_merge() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: gitlab-cli.sh mr merge <project> <iid>"
        exit 1
    fi

    local project="$1"
    local iid="$2"

    local encoded_project
    encoded_project=$(encode_project "$project")

    local response
    response=$(gitlab_api PUT "/projects/${encoded_project}/merge_requests/${iid}/merge") || exit 1

    local state
    state=$(echo "$response" | jq -r '.state // "unknown"')

    if [[ "$state" == "merged" ]]; then
        log_info "MR !${iid} merged successfully"
        echo "$response" | jq '{iid, state, merged_by: .merged_by.username, merged_at}'
    else
        local message
        message=$(echo "$response" | jq -r '.message // "Unknown error"')
        log_error "Failed to merge MR !${iid}: $message"
        exit 1
    fi
}

cmd_mr_close() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: gitlab-cli.sh mr close <project> <iid>"
        exit 1
    fi

    local project="$1"
    local iid="$2"

    local encoded_project
    encoded_project=$(encode_project "$project")

    local response
    response=$(gitlab_api PUT "/projects/${encoded_project}/merge_requests/${iid}" \
        -H "Content-Type: application/json" \
        -d '{"state_event": "close"}') || exit 1

    local state
    state=$(echo "$response" | jq -r '.state // "unknown"')

    if [[ "$state" == "closed" ]]; then
        log_info "MR !${iid} closed"
        echo "$response" | jq '{iid, state, title}'
    else
        log_error "Failed to close MR !${iid}"
        exit 1
    fi
}

# =============================================================================
# Branch Commands
# =============================================================================

cmd_branch_list() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: gitlab-cli.sh branch list <project> [--pattern glob]"
        exit 1
    fi

    local project="$1"
    shift

    local pattern=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pattern) pattern="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local encoded_project
    encoded_project=$(encode_project "$project")

    local endpoint="/projects/${encoded_project}/repository/branches?per_page=100"
    [[ -n "$pattern" ]] && endpoint="${endpoint}&search=${pattern}"

    local response
    response=$(gitlab_api GET "$endpoint") || exit 1

    echo "$response" | jq -r '.[].name'
}

cmd_branch_delete() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: gitlab-cli.sh branch delete <project> <branch>"
        exit 1
    fi

    local project="$1"
    local branch="$2"

    local encoded_project encoded_branch
    encoded_project=$(encode_project "$project")
    encoded_branch=$(encode_path "$branch")

    # DELETE returns empty on success
    if gitlab_api DELETE "/projects/${encoded_project}/repository/branches/${encoded_branch}" >/dev/null 2>&1; then
        log_info "Deleted branch: $branch"
    else
        log_error "Failed to delete branch: $branch"
        exit 1
    fi
}

# =============================================================================
# File Commands
# =============================================================================

cmd_file_get() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: gitlab-cli.sh file get <project> <path> [--ref branch]"
        exit 1
    fi

    local project="$1"
    local filepath="$2"
    shift 2

    local ref="main"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref) ref="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local encoded_project encoded_path
    encoded_project=$(encode_project "$project")
    encoded_path=$(encode_path "$filepath")

    local response
    response=$(gitlab_api GET "/projects/${encoded_project}/repository/files/${encoded_path}?ref=${ref}") || exit 1

    # Decode base64 content
    echo "$response" | jq -r '.content' | base64 -d
}

cmd_file_update() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: gitlab-cli.sh file update <project> <path> --ref <branch> --content <content> --message <msg>"
        exit 1
    fi

    local project="$1"
    local filepath="$2"
    shift 2

    local ref=""
    local content=""
    local message=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref) ref="$2"; shift 2 ;;
            --content) content="$2"; shift 2 ;;
            --message) message="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Validate required options
    [[ -z "$ref" ]] && { log_error "--ref is required"; exit 1; }
    [[ -z "$content" ]] && { log_error "--content is required"; exit 1; }
    [[ -z "$message" ]] && { log_error "--message is required"; exit 1; }

    local encoded_project encoded_path
    encoded_project=$(encode_project "$project")
    encoded_path=$(encode_path "$filepath")

    # First, get the current file to obtain its SHA (required for updates)
    local current_file
    current_file=$(gitlab_api GET "/projects/${encoded_project}/repository/files/${encoded_path}?ref=${ref}") || {
        log_error "Failed to get current file (does it exist?)"
        exit 1
    }

    # Base64 encode the new content
    local encoded_content
    encoded_content=$(echo -n "$content" | base64 -w0)

    # Update the file via API
    local response
    response=$(gitlab_api PUT "/projects/${encoded_project}/repository/files/${encoded_path}" \
        -H "Content-Type: application/json" \
        -d "{
            \"branch\": \"${ref}\",
            \"content\": \"${encoded_content}\",
            \"commit_message\": \"${message}\",
            \"encoding\": \"base64\"
        }") || exit 1

    local file_path
    file_path=$(echo "$response" | jq -r '.file_path // "unknown"')

    if [[ "$file_path" != "null" && "$file_path" != "unknown" ]]; then
        log_info "Updated file: $file_path on branch $ref"
        echo "$response" | jq '{file_path, branch}'
    else
        log_error "Failed to update file"
        echo "$response" | jq .
        exit 1
    fi
}

# =============================================================================
# Commit Commands
# =============================================================================

cmd_commit_list() {
    if [[ $# -lt 1 ]]; then
        log_error "Usage: gitlab-cli.sh commit list <project> [--ref branch] [--limit n]"
        exit 1
    fi

    local project="$1"
    shift

    local ref="main"
    local limit=10

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref) ref="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local encoded_project
    encoded_project=$(encode_project "$project")

    local response
    response=$(gitlab_api GET "/projects/${encoded_project}/repository/commits?ref_name=${ref}&per_page=${limit}") || exit 1

    echo "$response" | jq -r '.[] | "\(.short_id) \(.created_at | split("T")[0]) \(.title)"'
}

# =============================================================================
# Environment Commands
# =============================================================================

cmd_env_image() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: gitlab-cli.sh env image <project> <environment> [--app name]"
        exit 1
    fi

    local project="$1"
    local environment="$2"
    shift 2

    local app_name="exampleApp"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app_name="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    local encoded_project encoded_path
    encoded_project=$(encode_project "$project")
    encoded_path=$(encode_path "env.cue")

    # Fetch env.cue from the environment branch
    local response
    response=$(gitlab_api GET "/projects/${encoded_project}/repository/files/${encoded_path}?ref=${environment}") || {
        log_error "Failed to fetch env.cue from branch: $environment"
        exit 1
    }

    # Decode and extract image for the specified app
    local env_cue_content
    env_cue_content=$(echo "$response" | jq -r '.content' | base64 -d) || {
        log_error "Failed to decode env.cue content"
        exit 1
    }

    # Extract the full image URL for the app
    # Pattern: looks for the app section and extracts the image field
    local full_image
    full_image=$(echo "$env_cue_content" | \
        awk -v env="$environment" -v app="$app_name" '
            $0 ~ "^"env": "app":" { in_section=1 }
            in_section && /image:/ {
                match($0, /"[^"]+"/);
                print substr($0, RSTART+1, RLENGTH-2);
                exit
            }
            in_section && /^[a-zA-Z]/ && !($0 ~ app) { in_section=0 }
        ') || true

    if [[ -z "$full_image" ]]; then
        log_error "Could not find image for app '$app_name' in environment '$environment'"
        exit 1
    fi

    # Output just the tag (after the last colon)
    local image_tag
    image_tag=$(echo "$full_image" | sed 's/.*://')

    echo "$image_tag"
}

# =============================================================================
# User Command
# =============================================================================

cmd_user() {
    local response
    response=$(gitlab_api GET "/user") || exit 1

    local username
    username=$(echo "$response" | jq -r '.username // "unknown"')

    log_info "Authenticated as: $username"
    echo "$response" | jq '{id, username, name, email, state}'
}

# =============================================================================
# Main
# =============================================================================

if [[ $# -lt 1 ]]; then
    show_help
fi

case "$1" in
    -h|--help|help) show_help ;;
    mr)
        shift
        if [[ $# -lt 1 ]]; then
            log_error "Usage: gitlab-cli.sh mr <list|merge|close> ..."
            exit 1
        fi
        subcommand="$1"
        shift
        case "$subcommand" in
            list) cmd_mr_list "$@" ;;
            merge) cmd_mr_merge "$@" ;;
            close) cmd_mr_close "$@" ;;
            *) log_error "Unknown mr subcommand: $subcommand"; exit 1 ;;
        esac
        ;;
    branch)
        shift
        if [[ $# -lt 1 ]]; then
            log_error "Usage: gitlab-cli.sh branch <list|delete> ..."
            exit 1
        fi
        subcommand="$1"
        shift
        case "$subcommand" in
            list) cmd_branch_list "$@" ;;
            delete) cmd_branch_delete "$@" ;;
            *) log_error "Unknown branch subcommand: $subcommand"; exit 1 ;;
        esac
        ;;
    file)
        shift
        if [[ $# -lt 1 ]]; then
            log_error "Usage: gitlab-cli.sh file <get> ..."
            exit 1
        fi
        subcommand="$1"
        shift
        case "$subcommand" in
            get) cmd_file_get "$@" ;;
            update) cmd_file_update "$@" ;;
            *) log_error "Unknown file subcommand: $subcommand"; exit 1 ;;
        esac
        ;;
    commit)
        shift
        if [[ $# -lt 1 ]]; then
            log_error "Usage: gitlab-cli.sh commit <list> ..."
            exit 1
        fi
        subcommand="$1"
        shift
        case "$subcommand" in
            list) cmd_commit_list "$@" ;;
            *) log_error "Unknown commit subcommand: $subcommand"; exit 1 ;;
        esac
        ;;
    env)
        shift
        if [[ $# -lt 1 ]]; then
            log_error "Usage: gitlab-cli.sh env <image> ..."
            exit 1
        fi
        subcommand="$1"
        shift
        case "$subcommand" in
            image) cmd_env_image "$@" ;;
            *) log_error "Unknown env subcommand: $subcommand"; exit 1 ;;
        esac
        ;;
    user) cmd_user ;;
    *) log_error "Unknown command: $1"; show_help ;;
esac
