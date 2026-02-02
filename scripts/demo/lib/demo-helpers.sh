#!/bin/bash
# Demo Helper Library
# Shared functions for k8s-deployments demo scripts
#
# Source this file: source "$(dirname "$0")/lib/demo-helpers.sh"

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUE_EDIT="${DEMO_LIB_DIR}/cue-edit.py"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# OUTPUT FUNCTIONS
# ============================================================================

demo_header() {
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $*${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

demo_step() {
    local step_num="$1"
    shift
    echo -e "${BOLD}${CYAN}▶ Step ${step_num}: $*${NC}"
}

demo_action() {
    echo -e "  ${GREEN}→${NC} $*" >&2
}

demo_info() {
    echo -e "  ${BLUE}ℹ${NC} $*" >&2
}

demo_verify() {
    echo -e "  ${GREEN}✓${NC} $*" >&2
}

demo_fail() {
    echo -e "  ${RED}✗${NC} $*" >&2
}

demo_warn() {
    echo -e "  ${YELLOW}⚠${NC} $*" >&2
}

demo_wait() {
    local msg="${1:-Press Enter to continue...}"
    echo ""
    read -rp "  ${msg}"
    echo ""
}

demo_pause() {
    local seconds="${1:-2}"
    sleep "$seconds"
}

demo_complete() {
    echo ""
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}  Demo Complete!${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ============================================================================
# GITLAB API OPERATIONS (avoid subtree push divergent history)
# ============================================================================

# Create a feature branch in GitLab from dev and update a file
# This avoids subtree push which creates divergent commit history
# Usage: gitlab_create_feature_branch <branch_name> <file_path> <commit_message>
# The file content should be piped to stdin
# Returns: 0 on success, 1 on failure
gitlab_create_feature_branch() {
    local branch_name="$1"
    local file_path="$2"
    local commit_message="$3"
    local project="${GITLAB_PROJECT:-p2c/k8s-deployments}"
    local base_branch="${4:-dev}"

    local gitlab_cli="${SCRIPT_DIR}/../../04-operations/gitlab-cli.sh"

    # Create branch from dev
    demo_action "Creating branch '$branch_name' from $base_branch in GitLab..."
    if ! "$gitlab_cli" branch create "$project" "$branch_name" --from "$base_branch" 2>/dev/null; then
        demo_fail "Failed to create branch in GitLab"
        return 1
    fi

    # Update the file (content from stdin)
    demo_action "Updating $file_path in GitLab..."
    if ! "$gitlab_cli" file update "$project" "$file_path" \
        --ref "$branch_name" \
        --message "$commit_message" \
        --stdin; then
        demo_fail "Failed to update file in GitLab"
        return 1
    fi

    demo_verify "Feature branch '$branch_name' created in GitLab"
    return 0
}

# Get file content from GitLab
# Usage: gitlab_get_file <file_path> [--ref <branch>]
gitlab_get_file() {
    local file_path="$1"
    shift
    local project="${GITLAB_PROJECT:-p2c/k8s-deployments}"
    local gitlab_cli="${SCRIPT_DIR}/../../04-operations/gitlab-cli.sh"

    "$gitlab_cli" file get "$project" "$file_path" "$@"
}

# ============================================================================
# GIT OPERATIONS
# ============================================================================

demo_ensure_branch() {
    local branch="$1"
    local current_branch

    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "$branch" ]]; then
        demo_action "Switching to branch: $branch"
        git checkout "$branch" 2>/dev/null || git checkout -b "$branch"
    else
        demo_info "Already on branch: $branch"
    fi
}

demo_commit_changes() {
    local message="$1"
    local files="${2:-.}"

    demo_action "Staging changes: $files"
    git add $files

    if git diff --cached --quiet; then
        demo_info "No changes to commit"
        return 1
    fi

    demo_action "Committing: $message"
    git commit -m "$message"
    return 0
}

demo_push_branch() {
    local branch="${1:-$(git rev-parse --abbrev-ref HEAD)}"
    demo_action "Pushing to origin/$branch"
    git push origin "$branch"
}

# ============================================================================
# CUE EDITING WRAPPERS
# ============================================================================

demo_add_configmap_entry() {
    local env="$1"
    local app="$2"
    local key="$3"
    local value="$4"
    local file="${5:-env.cue}"

    demo_action "Adding ConfigMap entry: $key=$value"
    python3 "${CUE_EDIT}" env-configmap add "$file" "$env" "$app" "$key" "$value"
}

demo_remove_configmap_entry() {
    local env="$1"
    local app="$2"
    local key="$3"
    local file="${4:-env.cue}"

    demo_action "Removing ConfigMap entry: $key"
    python3 "${CUE_EDIT}" env-configmap remove "$file" "$env" "$app" "$key"
}

demo_add_app_configmap_entry() {
    local file="$1"
    local app="$2"
    local key="$3"
    local value="$4"

    demo_action "Adding app ConfigMap entry: $key=$value"
    python3 "${CUE_EDIT}" app-configmap add "$file" "$app" "$key" "$value"
}

demo_remove_app_configmap_entry() {
    local file="$1"
    local app="$2"
    local key="$3"

    demo_action "Removing app ConfigMap entry: $key"
    python3 "${CUE_EDIT}" app-configmap remove "$file" "$app" "$key"
}

demo_set_env_field() {
    local env="$1"
    local app="$2"
    local field="$3"
    local value="$4"
    local file="${5:-env.cue}"

    demo_action "Setting $field=$value for $app in $env"
    python3 "${CUE_EDIT}" env-field set "$file" "$env" "$app" "$field" "$value"
}

# ============================================================================
# MANIFEST OPERATIONS
# ============================================================================

demo_generate_manifests() {
    local env="${1:-$(git rev-parse --abbrev-ref HEAD)}"

    demo_action "Generating manifests for environment: $env"
    ./scripts/generate-manifests.sh "$env"
}

demo_verify_manifest_contains() {
    local manifest="$1"
    local pattern="$2"
    local description="$3"

    if grep -q "$pattern" "$manifest" 2>/dev/null; then
        demo_verify "$description"
        return 0
    else
        demo_fail "$description"
        return 1
    fi
}

demo_verify_manifest_not_contains() {
    local manifest="$1"
    local pattern="$2"
    local description="$3"

    if ! grep -q "$pattern" "$manifest" 2>/dev/null; then
        demo_verify "$description"
        return 0
    else
        demo_fail "$description (found when it shouldn't exist)"
        return 1
    fi
}

demo_show_manifest_diff() {
    local manifest="$1"
    local description="${2:-Manifest changes}"

    demo_info "$description:"
    if git diff --exit-code "$manifest" > /dev/null 2>&1; then
        demo_info "  (no changes)"
    else
        git diff --color=always "$manifest" | head -40
    fi
}

# ============================================================================
# CLEANUP OPERATIONS
# ============================================================================

demo_cleanup_on_exit() {
    local original_branch="$1"
    local cleanup_func="${2:-}"

    trap "demo_cleanup_handler '$original_branch' '$cleanup_func'" EXIT
}

demo_cleanup_handler() {
    local original_branch="$1"
    local cleanup_func="$2"

    echo ""
    demo_warn "Cleaning up..."

    # Run custom cleanup if provided
    if [[ -n "$cleanup_func" ]] && declare -f "$cleanup_func" > /dev/null; then
        "$cleanup_func"
    fi

    # Return to original branch
    if [[ -n "$original_branch" ]]; then
        git checkout "$original_branch" 2>/dev/null || true
    fi
}

# ============================================================================
# VALIDATION HELPERS
# ============================================================================

demo_require_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if ! command -v "$cmd" &> /dev/null; then
        demo_fail "Required command not found: $cmd"
        if [[ -n "$install_hint" ]]; then
            demo_info "Install: $install_hint"
        fi
        exit 1
    fi
}

demo_require_file() {
    local file="$1"
    local description="${2:-Required file}"

    if [[ ! -f "$file" ]]; then
        demo_fail "$description not found: $file"
        exit 1
    fi
}

demo_require_branch() {
    local branch="$1"

    if ! git rev-parse --verify "$branch" &> /dev/null; then
        demo_fail "Branch does not exist: $branch"
        demo_info "Create it with: git checkout -b $branch"
        exit 1
    fi
}

# ============================================================================
# INITIALIZATION
# ============================================================================

# Validate that cluster configuration has been loaded
# Called automatically by demo_init
demo_validate_config() {
    # Check for key config variable that indicates config was sourced
    if [[ -z "${GITLAB_NAMESPACE:-}" ]]; then
        demo_fail "Cluster configuration not loaded"
        if [[ -n "${CLUSTER_CONFIG:-}" ]]; then
            demo_info "CLUSTER_CONFIG is set to: $CLUSTER_CONFIG"
            demo_info "But configuration variables are not set. Check the config file."
        else
            demo_info "CLUSTER_CONFIG environment variable is not set"
            demo_info "Run demos via run-all-demos.sh with a config file:"
            demo_info "  ./scripts/demo/run-all-demos.sh config/clusters/alpha.env"
        fi
        exit 1
    fi
}

demo_init() {
    local demo_name="$1"

    # Validate cluster configuration is loaded
    demo_validate_config

    # Verify we're in a git repo
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        demo_fail "Not in a git repository"
        exit 1
    fi

    # Verify required tools
    demo_require_command "cue" "https://cuelang.org/docs/install/"
    demo_require_command "python3"

    # Verify cue-edit.py exists
    demo_require_file "$CUE_EDIT" "CUE edit helper"

    demo_header "$demo_name"
}

# ============================================================================
# PIPELINE STATE INTEGRATION
# ============================================================================

# Source pipeline-state.sh for quiescence checks
# Note: pipeline-wait.sh must also be sourced for load_pipeline_credentials
source "${DEMO_LIB_DIR}/pipeline-state.sh"

# Preflight check: ensure pipeline is quiescent before starting demo
# If dirty, offers cleanup (interactive or automatic via DEMO_FORCE_CLEANUP=1)
# Returns: 0 if clean (or cleaned), exits 1 if user declines or cleanup fails
demo_preflight_check() {
    demo_action "Checking pipeline state..."

    # Ensure credentials are loaded (load_pipeline_credentials is from pipeline-wait.sh)
    # Check if the function exists (pipeline-wait.sh may be sourced by the calling script)
    if declare -f load_pipeline_credentials >/dev/null 2>&1; then
        load_pipeline_credentials || {
            demo_fail "Could not load pipeline credentials"
            exit 1
        }
    elif [[ -z "${GITLAB_TOKEN:-}" ]] || [[ -z "${JENKINS_USER:-}" ]]; then
        demo_fail "Credentials not set and load_pipeline_credentials not available"
        demo_info "Source pipeline-wait.sh or set GITLAB_TOKEN/JENKINS_USER/JENKINS_TOKEN"
        exit 1
    fi

    # Wait briefly for transient items (agent pods, etc.) to clear
    # This handles race conditions between reset completing and demo starting
    local wait_timeout="${DEMO_PREFLIGHT_WAIT:-15}"
    local wait_interval=3
    local elapsed=0

    while [[ $elapsed -lt $wait_timeout ]]; do
        if check_pipeline_quiescent; then
            demo_verify "Pipeline is quiescent - ready to start"
            return 0
        fi

        # Only show waiting message after first check fails
        if [[ $elapsed -eq 0 ]]; then
            demo_info "Waiting for pipeline activity to settle..."
        fi

        sleep $wait_interval
        elapsed=$((elapsed + wait_interval))
    done

    # Still not quiescent after waiting - display state
    demo_warn "Pipeline has pending work after ${wait_timeout}s:"
    display_pipeline_state

    # Determine cleanup approach
    if [[ "${DEMO_FORCE_CLEANUP:-0}" == "1" ]]; then
        demo_action "Auto-cleanup enabled (DEMO_FORCE_CLEANUP=1)"
        demo_action "Cleaning up pipeline state..."
        cleanup_pipeline_state

        # Verify cleanup succeeded
        if check_pipeline_quiescent; then
            demo_verify "Pipeline cleaned up successfully"
            return 0
        else
            demo_fail "Cleanup did not fully resolve pipeline state"
            display_pipeline_state
            exit 1
        fi
    else
        # Interactive prompt
        echo ""
        read -rp "  Clean up and continue? [y/N] " response
        case "$response" in
            [yY]|[yY][eE][sS])
                demo_action "Cleaning up pipeline state..."
                cleanup_pipeline_state

                # Verify cleanup succeeded
                if check_pipeline_quiescent; then
                    demo_verify "Pipeline cleaned up successfully"
                    return 0
                else
                    demo_fail "Cleanup did not fully resolve pipeline state"
                    display_pipeline_state
                    exit 1
                fi
                ;;
            *)
                demo_warn "Cleanup declined - demo cannot proceed safely"
                exit 1
                ;;
        esac
    fi
}

# Postflight check: wait for pipeline to become quiescent after demo completes
# Waits up to timeout for all triggered activity (builds, syncs) to finish
# Returns: 0 if quiescent, exits with 1 if still dirty after timeout
demo_postflight_check() {
    local timeout="${DEMO_POSTFLIGHT_TIMEOUT:-60}"
    local interval=5

    demo_action "Waiting for pipeline to become quiescent (timeout ${timeout}s)..."

    # Ensure credentials are loaded
    if declare -f load_pipeline_credentials >/dev/null 2>&1; then
        load_pipeline_credentials || {
            demo_fail "Could not load pipeline credentials"
            exit 1
        }
    elif [[ -z "${GITLAB_TOKEN:-}" ]] || [[ -z "${JENKINS_USER:-}" ]]; then
        demo_fail "Credentials not set and load_pipeline_credentials not available"
        demo_info "Source pipeline-wait.sh or set GITLAB_TOKEN/JENKINS_USER/JENKINS_TOKEN"
        exit 1
    fi

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if check_pipeline_quiescent; then
            demo_verify "Pipeline is quiescent - demo completed cleanly"
            return 0
        fi

        # Show progress
        demo_info "Waiting for activity to finish... (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    # Still not quiescent after timeout - hard error
    demo_fail "Pipeline still has pending work after ${timeout}s:"
    display_pipeline_state
    exit 1
}
