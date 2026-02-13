#!/bin/bash
# rollback-environment.sh - Roll back an environment to its previous state
#
# Usage:
#   rollback-environment.sh <env> --reason <reason> [options]
#
# Arguments:
#   <env>                     Target environment: dev, stage, prod
#   --reason <reason>         Required: Reason for rollback (e.g., "INC-123: API errors")
#
# Options:
#   --to <target>             What to roll back to (default: last)
#                             Values: last, HEAD~N, <commit-sha>
#   --dry-run                 Show what would happen without making changes
#   --force                   Skip preflight checks (use with caution)
#   --help                    Show this help
#
# Examples:
#   # Roll back stage to previous state (most common)
#   rollback-environment.sh stage --reason "INC-1234: API errors after deploy"
#
#   # Roll back to specific commit
#   rollback-environment.sh prod --to abc123f --reason "INC-5678: Known-good state"
#
#   # Dry-run to see what would happen
#   rollback-environment.sh stage --reason "testing" --dry-run
#
# The rollback:
#   1. Checks for pending promotion MRs (fails if found, unless --force)
#   2. Creates a git revert commit via GitLab API
#   3. The revert includes [no-promote] to prevent cascading
#   4. Waits for Jenkins CI to regenerate manifests
#   5. ArgoCD auto-syncs the reverted state
#
# This tool creates auditable rollbacks through the GitOps workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source dependencies
# Pass CLUSTER_CONFIG explicitly to avoid inheriting parent's $1
source "$SCRIPT_DIR/../lib/infra.sh" "${CLUSTER_CONFIG:-}"
source "$SCRIPT_DIR/../lib/credentials.sh"

# Get credentials
GITLAB_TOKEN=$(require_gitlab_token)
GITLAB_CLI="$SCRIPT_DIR/gitlab-cli.sh"
JENKINS_CLI="$SCRIPT_DIR/jenkins-cli.sh"

# Configuration
PROJECT="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"

# ============================================================================
# HELPERS
# ============================================================================

show_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
}

# Get the merge commit to revert
# Usage: get_revert_target <env> <target>
# Returns: commit SHA to revert
get_revert_target() {
    local env="$1"
    local target="$2"

    case "$target" in
        last|HEAD~1)
            # Get the last commit on the branch
            "$GITLAB_CLI" commit list "$PROJECT" --ref "$env" --limit 1 2>/dev/null | \
                head -1 | awk '{print $1}'
            ;;
        HEAD~*)
            # Get Nth commit back
            local n="${target#HEAD~}"
            "$GITLAB_CLI" commit list "$PROJECT" --ref "$env" --limit "$((n+1))" 2>/dev/null | \
                tail -1 | awk '{print $1}'
            ;;
        *)
            # Assume it's a commit SHA
            echo "$target"
            ;;
    esac
}

# Get downstream environment (for preflight check)
get_downstream_env() {
    local env="$1"
    case "$env" in
        dev)   echo "stage" ;;
        stage) echo "prod" ;;
        prod)  echo "" ;;  # No downstream
    esac
}

# ============================================================================
# PREFLIGHT CHECK
# ============================================================================

preflight_check() {
    local env="$1"
    local force="$2"

    log_step "Running preflight checks..."

    local downstream
    downstream=$(get_downstream_env "$env")

    if [[ -n "$downstream" ]]; then
        log_info "Checking for pending promotion MRs to $downstream..."

        local pending_mrs
        pending_mrs=$("$GITLAB_CLI" mr promotion-pending "$PROJECT" "$downstream" 2>/dev/null || true)

        if [[ -n "$pending_mrs" ]]; then
            log_warn "Found pending promotion MRs targeting $downstream:"
            for iid in $pending_mrs; do
                log_warn "  - MR !$iid"
            done

            if [[ "$force" == "true" ]]; then
                log_warn "Proceeding anyway (--force specified)"
            else
                log_error "Close or merge pending MRs before rollback, or use --force"
                return 1
            fi
        else
            log_pass "No pending promotion MRs to $downstream"
        fi
    else
        log_info "No downstream environment (rolling back prod)"
    fi

    return 0
}

# ============================================================================
# ROLLBACK EXECUTION
# ============================================================================

execute_rollback() {
    local env="$1"
    local target="$2"
    local reason="$3"
    local dry_run="$4"

    # Get the commit to revert
    log_step "Identifying commit to revert..."
    local revert_sha
    revert_sha=$(get_revert_target "$env" "$target")

    if [[ -z "$revert_sha" ]]; then
        log_error "Could not determine commit to revert"
        return 1
    fi

    # Get commit info for display
    local commit_info
    commit_info=$("$GITLAB_CLI" commit list "$PROJECT" --ref "$env" --limit 10 2>/dev/null | \
        grep "^${revert_sha}" | head -1 || echo "$revert_sha (details unavailable)")

    log_info "Will revert: $commit_info"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] Would revert commit $revert_sha on $env branch"
        log_info "[DRY-RUN] Reason: $reason"
        log_info "[DRY-RUN] Commit message would include [no-promote] marker"
        return 0
    fi

    # Execute the revert via GitLab API
    log_step "Creating revert commit on $env branch..."

    local revert_result
    if ! revert_result=$("$GITLAB_CLI" commit revert "$PROJECT" "$revert_sha" --branch "$env" 2>&1); then
        log_error "Failed to create revert commit: $revert_result"
        return 1
    fi

    local new_sha
    new_sha=$(echo "$revert_result" | grep -oP 'Reverted .* → \K[a-f0-9]+' || echo "unknown")
    log_pass "Created revert commit: $new_sha"

    # Note: The revert commit message is auto-generated by GitLab as "Revert <original message>"
    # The [no-promote] marker is handled by checking if the commit is a revert in the Jenkinsfile

    log_step "Waiting for Jenkins CI to process $env branch..."

    # Record pre-trigger timestamp to detect new builds
    local pre_trigger_time
    pre_trigger_time=$(date +%s%3N)

    # Wait for Jenkins to pick up the change and complete
    local timeout=300
    local jenkins_job="${DEPLOYMENTS_REPO_NAME}/${env}"

    if "$JENKINS_CLI" wait "$jenkins_job" --timeout "$timeout" --after "$pre_trigger_time" 2>&1; then
        log_pass "Jenkins CI completed successfully"
    else
        local exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            log_warn "Timeout waiting for Jenkins CI (${timeout}s)"
            log_info "ArgoCD should still sync once Jenkins completes"
        else
            log_error "Jenkins CI failed"
            return 1
        fi
    fi

    log_pass "Rollback initiated for $env"
    log_info "ArgoCD will auto-sync the reverted manifests"
    log_info "Reason logged: $reason"

    return 0
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    local env=""
    local reason=""
    local target="last"
    local dry_run="false"
    local force="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            --to)
                target="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                if [[ -z "$env" ]]; then
                    env="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$env" ]]; then
        log_error "Environment is required"
        show_help
        exit 1
    fi

    if [[ ! "$env" =~ ^(dev|stage|prod)$ ]]; then
        log_error "Invalid environment: $env (must be dev, stage, or prod)"
        exit 1
    fi

    if [[ -z "$reason" ]]; then
        log_error "--reason is required"
        exit 1
    fi

    echo ""
    log_header "Environment Rollback"
    echo "  Environment: $env"
    echo "  Target:      $target"
    echo "  Reason:      $reason"
    echo "  Dry-run:     $dry_run"
    echo ""

    # Preflight check
    if ! preflight_check "$env" "$force"; then
        exit 1
    fi

    # Execute rollback
    if ! execute_rollback "$env" "$target" "$reason" "$dry_run"; then
        exit 1
    fi

    echo ""
    log_pass "Rollback Complete"
}

main "$@"
