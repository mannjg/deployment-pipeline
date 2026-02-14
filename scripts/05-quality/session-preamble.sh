#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SCRIPT="$PROJECT_ROOT/scripts/05-quality/verify-conventions.sh"
BELIEFS_FILE="$PROJECT_ROOT/docs/governance/CORE_BELIEFS.md"

issues=0
tier1_count=0
tier2_count=0
tier2_shown=0
belief_issue_count=0
TIER2_CAP=20

emit_issue() {
    local message="$1"
    echo "PREAMBLE: ${message}"
    issues=$((issues + 1))
}

emit_belief_issue() {
    local message="$1"
    echo "PREAMBLE: ${message}"
    belief_issue_count=$((belief_issue_count + 1))
    issues=$((issues + 1))
}

run_convention_scan() {
    if [[ ! -x "$VERIFY_SCRIPT" ]]; then
        emit_issue "missing verify-conventions.sh (expected at scripts/05-quality/verify-conventions.sh)"
        return
    fi

    local output
    local tier1_lines=()
    local tier2_lines=()

    output="$("$VERIFY_SCRIPT" --warn --tier 1 --tier 2 || true)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[T1\][[:space:]] ]]; then
            tier1_lines+=("$line")
        elif [[ "$line" =~ ^\[T2\][[:space:]] ]]; then
            tier2_lines+=("$line")
        fi
    done <<< "$output"

    tier1_count=${#tier1_lines[@]}
    tier2_count=${#tier2_lines[@]}

    for line in "${tier1_lines[@]}"; do
        emit_issue "$line"
    done

    for line in "${tier2_lines[@]}"; do
        if [[ "$tier2_shown" -lt "$TIER2_CAP" ]]; then
            emit_issue "$line"
            tier2_shown=$((tier2_shown + 1))
        fi
    done
}

belief_quick_check() {
    if [[ ! -f "$BELIEFS_FILE" ]]; then
        emit_issue "missing docs/governance/CORE_BELIEFS.md (belief quick-check skipped)"
        return
    fi

    local recent_beliefs=()
    while IFS= read -r line; do
        [[ "$line" =~ ^-[[:space:]] ]] || continue
        recent_beliefs+=("$line")
    done < "$BELIEFS_FILE"

    if [[ ${#recent_beliefs[@]} -eq 0 ]]; then
        emit_issue "no beliefs found in docs/governance/CORE_BELIEFS.md"
        return
    fi

    local start=0
    if [[ ${#recent_beliefs[@]} -gt 2 ]]; then
        start=$((${#recent_beliefs[@]} - 2))
    fi

    local idx
    for ((idx=start; idx<${#recent_beliefs[@]}; idx++)); do
        local belief="${recent_beliefs[$idx]}"
        local mapped=0

        if [[ "$belief" == *"CLI wrappers over direct API calls"* ]]; then
            mapped=1
            if [[ ! -f "$PROJECT_ROOT/scripts/04-operations/gitlab-cli.sh" || ! -f "$PROJECT_ROOT/scripts/04-operations/jenkins-cli.sh" ]]; then
                emit_belief_issue "belief quick-check failed: CLI wrapper scripts missing"
            fi
        fi

        if [[ "$belief" == *"Monorepo with subtree sync"* || "$belief" == *"Subtree publishing"* ]]; then
            mapped=1
            if [[ ! -f "$PROJECT_ROOT/scripts/04-operations/sync-to-github.sh" || ! -f "$PROJECT_ROOT/scripts/04-operations/sync-to-gitlab.sh" ]]; then
                emit_belief_issue "belief quick-check failed: subtree sync scripts missing"
            fi
        fi

        if [[ "$belief" == *"MR-only environment branches"* ]]; then
            mapped=1
            if [[ ! -f "$PROJECT_ROOT/scripts/03-pipelines/setup-gitlab-env-branches.sh" ]]; then
                emit_belief_issue "belief quick-check failed: env-branch setup script missing"
            fi
        fi

        if [[ "$belief" == *"CUE over raw YAML"* ]]; then
            mapped=1
            if [[ ! -f "$PROJECT_ROOT/k8s-deployments/templates/core/app.cue" ]]; then
                emit_belief_issue "belief quick-check failed: app.cue missing"
            fi
        fi

        if [[ "$mapped" -eq 0 ]]; then
            echo "PREAMBLE: belief quick-check skipped (no mapping): ${belief#- }"
        fi
    done
}

run_convention_scan
belief_quick_check

issues=$((tier1_count + tier2_count + belief_issue_count))

if [[ "$issues" -eq 0 ]]; then
    echo "SESSION-PREAMBLE: ok (no Tier 1-2 issues)"
else
    if [[ "$tier2_count" -gt "$TIER2_CAP" ]]; then
        echo "SESSION-PREAMBLE: Tier1=${tier1_count} Tier2=${tier2_count} Belief=${belief_issue_count} (showing ${tier2_shown} Tier2)"
    else
        echo "SESSION-PREAMBLE: Tier1=${tier1_count} Tier2=${tier2_count} Belief=${belief_issue_count}"
    fi
    echo "SESSION-PREAMBLE: ${issues} issue(s) found (warn-only)"
fi
