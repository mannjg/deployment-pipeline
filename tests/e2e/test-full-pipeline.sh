#!/bin/bash
# E2E Pipeline Test Orchestrator
# Runs complete pipeline test from source to production

set -euo pipefail

# Ensure kubectl is in PATH
export PATH="$HOME/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries from k8s-deployments
source "$SCRIPT_DIR/../../k8s-deployments/tests/lib/common.sh"
source "$SCRIPT_DIR/../../k8s-deployments/tests/lib/cleanup.sh"

# Source E2E test libraries
source "$SCRIPT_DIR/lib/test-setup.sh"
source "$SCRIPT_DIR/lib/gitlab-api.sh"

# Default values
CLEANUP_MODE="on-success"
SKIP_CLEANUP=false
STOP_ON_FAILURE=true
START_STAGE=1
END_STAGE=6

# Parse command line arguments
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Run end-to-end pipeline test from source code commit through production deployment.

OPTIONS:
    -h, --help              Show this help message
    -c, --cleanup MODE      Cleanup mode: always, on-success, on-failure, never (default: on-success)
    --no-cleanup            Skip cleanup entirely (same as --cleanup never)
    --continue-on-failure   Continue to next stage even if current stage fails
    --start STAGE           Start from specific stage (1-6)
    --end STAGE             End at specific stage (1-6)
    --stage STAGE           Run only a specific stage
    -v, --verbose           Enable verbose output
    --dry-run               Show what would be executed without running

STAGES:
    1. Trigger Build        Create commit, trigger Jenkins, wait for build
    2. Verify Dev           Verify dev deployment is healthy
    3. Promote Stage        Create and merge MR from dev to stage
    4. Verify Stage         Verify stage deployment is healthy
    5. Promote Prod         Create and merge MR from stage to prod
    6. Verify Prod          Verify production deployment is healthy

EXAMPLES:
    # Run full pipeline test
    $0

    # Run with cleanup disabled
    $0 --no-cleanup

    # Run only stages 1-4 (up to stage verification)
    $0 --start 1 --end 4

    # Run only stage 3 (promote to stage)
    $0 --stage 3

    # Continue on failures for debugging
    $0 --continue-on-failure

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -c|--cleanup)
            CLEANUP_MODE="$2"
            shift 2
            ;;
        --no-cleanup)
            SKIP_CLEANUP=true
            CLEANUP_MODE="never"
            shift
            ;;
        --continue-on-failure)
            STOP_ON_FAILURE=false
            shift
            ;;
        --start)
            START_STAGE="$2"
            shift 2
            ;;
        --end)
            END_STAGE="$2"
            shift 2
            ;;
        --stage)
            START_STAGE="$2"
            END_STAGE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Set state directory before loading config
export E2E_STATE_DIR="$SCRIPT_DIR/state/$(date +%Y%m%d-%H%M%S)"

# Load E2E configuration
if [ -f "$SCRIPT_DIR/config/e2e-config.sh" ]; then
    source "$SCRIPT_DIR/config/e2e-config.sh"
else
    log_error "E2E configuration not found at $SCRIPT_DIR/config/e2e-config.sh"
    log_error "Please copy e2e-config.template.sh to e2e-config.sh and configure it"
    exit 1
fi

# Validate configuration
validate_config() {
    local missing_vars=()

    [ -z "${JENKINS_URL:-}" ] && missing_vars+=("JENKINS_URL")
    [ -z "${JENKINS_USER:-}" ] && missing_vars+=("JENKINS_USER")
    [ -z "${JENKINS_TOKEN:-}" ] && missing_vars+=("JENKINS_TOKEN")
    [ -z "${JENKINS_JOB_NAME:-}" ] && missing_vars+=("JENKINS_JOB_NAME")
    [ -z "${GITLAB_URL:-}" ] && missing_vars+=("GITLAB_URL")
    [ -z "${GITLAB_TOKEN:-}" ] && missing_vars+=("GITLAB_TOKEN")
    [ -z "${DEV_BRANCH:-}" ] && missing_vars+=("DEV_BRANCH")
    [ -z "${STAGE_BRANCH:-}" ] && missing_vars+=("STAGE_BRANCH")
    [ -z "${PROD_BRANCH:-}" ] && missing_vars+=("PROD_BRANCH")

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing required configuration variables:"
        for var in "${missing_vars[@]}"; do
            log_error "  - $var"
        done
        exit 1
    fi
}

# Initialize test state directory
init_state_dir() {
    mkdir -p "${E2E_STATE_DIR}"
    echo "$(date +%s)" > "${E2E_STATE_DIR}/test_start_timestamp.txt"
    echo "$$" > "${E2E_STATE_DIR}/test_pid.txt"
}

# Cleanup function
cleanup_e2e_test() {
    local test_status=$1

    if [ "$SKIP_CLEANUP" = "true" ]; then
        log_info "Cleanup skipped"
        return 0
    fi

    case "$CLEANUP_MODE" in
        always)
            log_info "Performing cleanup (mode: always)..."
            do_cleanup
            ;;
        on-success)
            if [ "$test_status" = "0" ]; then
                log_info "Performing cleanup (mode: on-success, status: success)..."
                do_cleanup
            else
                log_warn "Skipping cleanup (mode: on-success, status: failure)"
                log_info "Test artifacts preserved in: ${E2E_STATE_DIR}"
            fi
            ;;
        on-failure)
            if [ "$test_status" != "0" ]; then
                log_info "Performing cleanup (mode: on-failure, status: failure)..."
                do_cleanup
            else
                log_info "Skipping cleanup (mode: on-failure, status: success)"
            fi
            ;;
        never)
            log_info "Cleanup skipped (mode: never)"
            log_info "Test artifacts preserved in: ${E2E_STATE_DIR}"
            ;;
        *)
            log_warn "Unknown cleanup mode: $CLEANUP_MODE"
            ;;
    esac
}

# Perform actual cleanup
do_cleanup() {
    log_info "Cleaning up E2E test artifacts..."

    # Close any open merge requests
    if [ -f "${E2E_STATE_DIR}/gitlab_project_id.txt" ]; then
        local project_id
        project_id=$(cat "${E2E_STATE_DIR}/gitlab_project_id.txt")

        # Close stage MR if exists
        if [ -f "${E2E_STATE_DIR}/stage_mr_iid.txt" ]; then
            local stage_mr
            stage_mr=$(cat "${E2E_STATE_DIR}/stage_mr_iid.txt")
            log_debug "Closing stage MR !${stage_mr}"
            source "$SCRIPT_DIR/lib/gitlab-api.sh"
            close_merge_request "$project_id" "$stage_mr" 2>/dev/null || true
        fi

        # Close prod MR if exists
        if [ -f "${E2E_STATE_DIR}/prod_mr_iid.txt" ]; then
            local prod_mr
            prod_mr=$(cat "${E2E_STATE_DIR}/prod_mr_iid.txt")
            log_debug "Closing prod MR !${prod_mr}"
            source "$SCRIPT_DIR/lib/gitlab-api.sh"
            close_merge_request "$project_id" "$prod_mr" 2>/dev/null || true
        fi
    fi

    # Delete feature branch
    if [ -f "${E2E_STATE_DIR}/feature_branch.txt" ]; then
        local feature_branch
        feature_branch=$(cat "${E2E_STATE_DIR}/feature_branch.txt")

        log_debug "Deleting feature branch: $feature_branch"
        source "$SCRIPT_DIR/lib/git-operations.sh"

        delete_remote_branch "$feature_branch" 2>/dev/null || true
        delete_local_branch "$feature_branch" 2>/dev/null || true
    fi

    # Clean up old E2E branches
    source "$SCRIPT_DIR/lib/git-operations.sh"
    cleanup_e2e_branches 1

    log_pass "Cleanup complete"
}

# Run a specific stage
run_stage() {
    local stage_num=$1
    local stage_script="$SCRIPT_DIR/stages/0${stage_num}-*.sh"

    # Find the stage script
    local script_path
    script_path=$(ls $stage_script 2>/dev/null | head -n1)

    if [ -z "$script_path" ]; then
        log_error "Stage $stage_num script not found"
        return 1
    fi

    local stage_name
    stage_name=$(basename "$script_path" .sh | sed 's/^[0-9]*-//' | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')

    log_info ""
    log_info "========================================="
    log_info "  Running Stage $stage_num: $stage_name"
    log_info "========================================="

    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[DRY RUN] Would execute: $script_path"
        return 0
    fi

    # Source and run the stage in a subshell to isolate directory changes
    (
        source "$script_path"

        local stage_function="stage_0${stage_num}_$(basename "$script_path" .sh | sed 's/^[0-9]*-//' | tr '-' '_')"

        if declare -f "$stage_function" > /dev/null; then
            $stage_function
            exit $?
        else
            log_error "Stage function $stage_function not found"
            exit 1
        fi
    )
    return $?
}

# Main execution
main() {
    echo
    log_info "=========================================="
    log_info "  E2E PIPELINE TEST"
    log_info "=========================================="
    echo
    log_info "Test Configuration:"
    log_info "  Start Stage: $START_STAGE"
    log_info "  End Stage: $END_STAGE"
    log_info "  Cleanup Mode: $CLEANUP_MODE"
    log_info "  Stop on Failure: $STOP_ON_FAILURE"
    echo

    # Validate configuration
    validate_config

    # Run pre-flight checks and cleanup
    log_info "Running pre-flight checks..."
    if ! run_test_initialization; then
        log_error "Pre-flight checks failed. Cannot proceed with tests."
        log_error "Please review the errors above and ensure all services are ready."
        exit 1
    fi
    echo

    # Initialize state directory
    init_state_dir

    # Track overall status
    local overall_status=0
    local stages_run=0
    local stages_passed=0
    local stages_failed=0

    # Run stages
    for stage in $(seq $START_STAGE $END_STAGE); do
        stages_run=$((stages_run + 1))

        if run_stage "$stage"; then
            stages_passed=$((stages_passed + 1))
            log_pass "Stage $stage completed successfully"
        else
            stages_failed=$((stages_failed + 1))
            overall_status=1
            log_error "Stage $stage failed"

            if [ "$STOP_ON_FAILURE" = "true" ]; then
                log_error "Stopping due to stage failure"
                break
            else
                log_warn "Continuing to next stage despite failure"
            fi
        fi
    done

    # Print summary
    echo
    log_info "=========================================="
    log_info "  E2E PIPELINE TEST SUMMARY"
    log_info "=========================================="
    echo
    log_info "Stages Run: $stages_run"
    log_info "Stages Passed: $stages_passed"
    log_info "Stages Failed: $stages_failed"
    echo

    # Calculate duration
    if [ -f "${E2E_STATE_DIR}/test_start_timestamp.txt" ]; then
        local start_time
        start_time=$(cat "${E2E_STATE_DIR}/test_start_timestamp.txt")
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_info "Total Duration: $(seconds_to_human $duration)"
        echo
    fi

    # Final status
    if [ $overall_status -eq 0 ]; then
        log_pass "✓ ALL STAGES PASSED"
    else
        log_error "✗ SOME STAGES FAILED"
    fi

    echo
    log_info "Test artifacts location: ${E2E_STATE_DIR}"
    echo

    # Cleanup
    cleanup_e2e_test $overall_status

    return $overall_status
}

# Set up trap for cleanup on exit
trap 'cleanup_e2e_test $?' EXIT INT TERM

# Run main
main "$@"
