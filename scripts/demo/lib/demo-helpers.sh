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

demo_init() {
    local demo_name="$1"

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
