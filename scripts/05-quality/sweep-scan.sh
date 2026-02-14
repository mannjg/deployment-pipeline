#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_SCRIPT="$PROJECT_ROOT/scripts/05-quality/verify-conventions.sh"
BELIEFS_FILE="$PROJECT_ROOT/docs/governance/CORE_BELIEFS.md"
DOC_INDEX="$PROJECT_ROOT/docs/INDEX.md"

# shellcheck source=../lib/logging.sh
if [[ -f "$PROJECT_ROOT/scripts/lib/logging.sh" ]]; then
    source "$PROJECT_ROOT/scripts/lib/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

CURRENT_DATE="$(date +%F)"
SWEEP_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mechanical_fail=0
consistency_outliers=0
belief_fail=0
belief_skipped=0
doc_stale=0

list_shell_scripts() {
    find "$PROJECT_ROOT" \
        -path "$PROJECT_ROOT/.worktrees" -prune -o \
        -path "$PROJECT_ROOT/.git" -prune -o \
        -name '*.sh' -print
}

is_lib_script() {
    local path="$1"
    [[ "$path" == */lib/* ]]
}

is_demo_or_test_script() {
    local path="$1"
    [[ "$path" == */scripts/demo/* || "$path" == */scripts/test/* ]]
}

report_section() {
    local title="$1"
    echo
    echo "=== ${title} ==="
}

run_mechanical_checks() {
    report_section "Mechanical Checks (Tier 1-4)"
    if [[ ! -x "$VERIFY_SCRIPT" ]]; then
        echo "MECHANICAL: missing verify-conventions.sh (expected at scripts/05-quality/verify-conventions.sh)"
        mechanical_fail=1
        return
    fi

    local output
    local status=0
    set +e
    output="$($VERIFY_SCRIPT --strict 2>&1)"
    status=$?
    set -e
    if [[ -n "$output" ]]; then
        echo "$output"
    fi

    if [[ "$status" -ne 0 ]]; then
        echo "MECHANICAL: FAILED"
        mechanical_fail=1
    else
        echo "MECHANICAL: OK"
    fi
}

run_convention_consistency() {
    report_section "Convention Consistency Scan"

    if ! command -v rg >/dev/null 2>&1; then
        echo "CONSISTENCY: rg not installed (scan skipped)"
        return
    fi

    local scripts=()
    while IFS= read -r script; do
        if is_lib_script "$script" || is_demo_or_test_script "$script"; then
            continue
        fi
        scripts+=("$script")
    done < <(list_shell_scripts)

    local total=${#scripts[@]}
    if [[ "$total" -eq 0 ]]; then
        echo "CONSISTENCY: no scripts found"
        return
    fi

    local -a pattern_names=(
        "set -euo pipefail"
        "SCRIPT_DIR bootstrap"
        "PROJECT_ROOT bootstrap"
        "logging.sh source"
    )
    local -a pattern_regex=(
        'set -euo pipefail'
        'SCRIPT_DIR=.*BASH_SOURCE\[0\].*pwd'
        'PROJECT_ROOT=.*SCRIPT_DIR.*pwd|PROJECT_ROOT=.*dirname.*SCRIPT_DIR'
        'scripts/lib/logging\.sh'
    )

    local idx
    for idx in "${!pattern_names[@]}"; do
        local name="${pattern_names[$idx]}"
        local regex="${pattern_regex[$idx]}"
        local matches=()
        local missing=()
        local file

        for file in "${scripts[@]}"; do
            if rg -q "$regex" "$file" 2>/dev/null; then
                matches+=("$file")
            else
                missing+=("$file")
            fi
        done

        local count=${#matches[@]}
        local percent=$((count * 100 / total))

        if [[ "$percent" -ge 80 && "$count" -lt "$total" ]]; then
            consistency_outliers=$((consistency_outliers + ${#missing[@]}))
            echo "CONSISTENCY: '$name' used in ${count}/${total} scripts (${percent}%)"
            for file in "${missing[@]}"; do
                echo "  OUTLIER: ${file#"$PROJECT_ROOT"/}"
            done
        else
            echo "CONSISTENCY: '$name' used in ${count}/${total} scripts (${percent}%)"
        fi
    done
}

record_belief() {
    local belief="$1"
    local status="$2"
    local detail="$3"
    echo "BELIEF: ${status} :: ${belief}"
    if [[ -n "$detail" ]]; then
        echo "  ${detail}"
    fi
    if [[ "$status" == "FAIL" ]]; then
        belief_fail=$((belief_fail + 1))
    elif [[ "$status" == "SKIP" ]]; then
        belief_skipped=$((belief_skipped + 1))
    fi
}

run_belief_coverage() {
    report_section "Belief Coverage"

    if [[ ! -f "$BELIEFS_FILE" ]]; then
        record_belief "docs/governance/CORE_BELIEFS.md" "FAIL" "Missing CORE_BELIEFS.md"
        return
    fi

    local line
    while IFS= read -r line; do
        [[ "$line" == "## Beliefs" ]] && in_beliefs=1 && continue
        if [[ "${in_beliefs:-0}" -ne 1 ]]; then
            continue
        fi
        [[ "$line" =~ ^-[[:space:]].*\(Added[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}\)$ ]] || continue
        local belief="${line#- }"
        belief="${belief%% (Added*}"

        if [[ "$belief" == *"Subtree publishing over submodules"* ]]; then
            if [[ -f "$PROJECT_ROOT/scripts/04-operations/sync-to-github.sh" && -f "$PROJECT_ROOT/scripts/04-operations/sync-to-gitlab.sh" ]]; then
                record_belief "$belief" "PASS" "sync scripts present"
            else
                record_belief "$belief" "FAIL" "Missing sync-to-github.sh or sync-to-gitlab.sh"
            fi
            continue
        fi

        if [[ "$belief" == *"MR-only environment branches"* ]]; then
            if [[ -f "$PROJECT_ROOT/scripts/03-pipelines/setup-gitlab-env-branches.sh" ]]; then
                record_belief "$belief" "PASS" "env-branch setup script present"
            else
                record_belief "$belief" "FAIL" "Missing setup-gitlab-env-branches.sh"
            fi
            continue
        fi

        if [[ "$belief" == *"CUE over raw YAML"* ]]; then
            if [[ -f "$PROJECT_ROOT/k8s-deployments/templates/core/app.cue" ]]; then
                record_belief "$belief" "PASS" "app.cue present"
            else
                record_belief "$belief" "FAIL" "Missing k8s-deployments/templates/core/app.cue"
            fi
            continue
        fi

        if [[ "$belief" == *"CLI wrappers over direct API calls"* ]]; then
            if [[ -f "$PROJECT_ROOT/scripts/04-operations/gitlab-cli.sh" && -f "$PROJECT_ROOT/scripts/04-operations/jenkins-cli.sh" ]]; then
                record_belief "$belief" "PASS" "CLI wrappers present"
            else
                record_belief "$belief" "FAIL" "Missing gitlab-cli.sh or jenkins-cli.sh"
            fi
            continue
        fi

        if [[ "$belief" == *"Monorepo with subtree sync"* ]]; then
            if [[ -f "$PROJECT_ROOT/scripts/04-operations/sync-to-github.sh" && -f "$PROJECT_ROOT/scripts/04-operations/sync-to-gitlab.sh" ]]; then
                record_belief "$belief" "PASS" "sync scripts present"
            else
                record_belief "$belief" "FAIL" "Missing sync-to-github.sh or sync-to-gitlab.sh"
            fi
            continue
        fi

        if [[ "$belief" == *"environment-agnostic"*"env.cue"* ]]; then
            if ! command -v rg >/dev/null 2>&1; then
                record_belief "$belief" "SKIP" "rg not installed"
            else
                local matches
                matches=$(rg -n "\benvs\." "$PROJECT_ROOT/k8s-deployments/templates/apps" -g '*.cue' || true)
                if [[ -n "$matches" ]]; then
                    record_belief "$belief" "FAIL" "env-specific references found in apps"
                    echo "$matches" | head -n 5 | while IFS= read -r m; do
                        echo "  ${m#"$PROJECT_ROOT"/}"
                    done
                else
                    record_belief "$belief" "PASS" "no env-specific references in apps"
                fi
            fi
            continue
        fi

        if [[ "$belief" == *"#App is the required app template"* ]]; then
            if ! command -v rg >/dev/null 2>&1; then
                record_belief "$belief" "SKIP" "rg not installed"
            else
                if rg -q "#App" "$PROJECT_ROOT/k8s-deployments/templates/apps" -g '*.cue' 2>/dev/null; then
                    record_belief "$belief" "PASS" "apps reference #App"
                else
                    record_belief "$belief" "FAIL" "No #App references found in apps"
                fi
            fi
            continue
        fi

        if [[ "$belief" == *"Defaults in #App"* ]]; then
            if [[ -f "$PROJECT_ROOT/k8s-deployments/templates/core/app.cue" ]]; then
                record_belief "$belief" "PASS" "see Tier 4 optional default check"
            else
                record_belief "$belief" "FAIL" "Missing app.cue"
            fi
            continue
        fi

        if [[ "$belief" == *"Namespace names must not be hardcoded"* ]]; then
            if ! command -v rg >/dev/null 2>&1; then
                record_belief "$belief" "SKIP" "rg not installed"
            else
                local violations=()
                local script
                while IFS= read -r script; do
                    if [[ "$script" == */scripts/demo/* || "$script" == */scripts/test/* ]]; then
                        continue
                    fi
                    if [[ "$script" == */scripts/lib/credentials.sh || "$script" == */k8s-deployments/scripts/lib/* ]]; then
                        continue
                    fi
                    local rel_path="${script#"$PROJECT_ROOT"/}"
                    while IFS= read -r v; do
                        [[ -z "$v" ]] && continue
                        violations+=("${v}")
                    done < <(awk -v file="$rel_path" '
                        /kubectl/ && /(--namespace|-n)/ {
                            for (i=1; i<=NF; i++) {
                                if ($i == "-n" || $i == "--namespace") {
                                    val=$(i+1)
                                } else if ($i ~ /^--namespace=/) {
                                    split($i, parts, "=");
                                    val=parts[2]
                                } else {
                                    continue
                                }

                                if (val ~ /\$/) { continue }
                                if (val ~ /^"\$/) { continue }
                                if (val ~ /^\$\{/ ) { continue }
                                if (val ~ /^\$[A-Za-z_]/) { continue }
                                if (val ~ /^[A-Za-z0-9._-]+$/) {
                                    printf("%s:%d:%s\n", file, NR, val)
                                }
                            }
                        }
                    ' "$script")
                done < <(list_shell_scripts)

                if [[ "${#violations[@]}" -gt 0 ]]; then
                    record_belief "$belief" "FAIL" "hardcoded namespaces detected"
                    printf '%s\n' "${violations[@]}" | head -n 5 | while IFS= read -r v; do
                        echo "  ${v}"
                    done
                else
                    record_belief "$belief" "PASS" "no hardcoded namespaces detected"
                fi
            fi
            continue
        fi

        if [[ "$belief" == *"pre-installed"*"no runtime package installation"* ]]; then
            if ! command -v rg >/dev/null 2>&1; then
                record_belief "$belief" "SKIP" "rg not installed"
            else
                local installs
                installs=$(rg -n "\b(pip3? install|go get|apt-get install|apt install|brew install|yum install|dnf install|apk add|npm install)\b" \
                    "$PROJECT_ROOT/scripts" -g '*.sh' -g '!scripts/05-quality/*' || true)
                if [[ -n "$installs" ]]; then
                    record_belief "$belief" "FAIL" "runtime package install commands detected"
                    echo "$installs" | head -n 5 | while IFS= read -r i; do
                        echo "  ${i#"$PROJECT_ROOT"/}"
                    done
                else
                    record_belief "$belief" "PASS" "no runtime installs detected"
                fi
            fi
            continue
        fi

        record_belief "$belief" "SKIP" "no mapping in sweep-scan.sh"
    done < "$BELIEFS_FILE"
}

run_belief_gap_analysis() {
    report_section "Belief Gap Analysis"
    echo "BELIEF-GAP: manual review required (not automated yet)"
    echo "BELIEF-GAP: identify recurring patterns without a matching belief and propose candidates"
}

run_doc_freshness() {
    report_section "Doc Freshness"

    if [[ ! -f "$DOC_INDEX" ]]; then
        echo "DOCS: Missing docs/INDEX.md"
        doc_stale=$((doc_stale + 1))
        return
    fi

    local reviewed_regex
    local reviewed_missing_regex
    reviewed_regex='`([^`]+)`.*Last[[:space:]]reviewed:[[:space:]]([0-9]{4}-[0-9]{2}-[0-9]{2})'
    reviewed_missing_regex='`([^`]+)`.*Last[[:space:]]reviewed:'

    local line
    while IFS= read -r line; do
        if [[ "$line" =~ $reviewed_regex ]]; then
            local path="${BASH_REMATCH[1]}"
            local reviewed="${BASH_REMATCH[2]}"
            local reviewed_epoch
            reviewed_epoch=$(date -d "$reviewed" +%s 2>/dev/null || echo "0")
            local now_epoch
            now_epoch=$(date -d "$CURRENT_DATE" +%s 2>/dev/null || echo "0")
            local age_days=0
            if [[ "$reviewed_epoch" -gt 0 && "$now_epoch" -gt 0 ]]; then
                age_days=$(((now_epoch - reviewed_epoch) / 86400))
            fi

            if [[ "$age_days" -gt 90 ]]; then
                echo "DOCS: STALE :: ${path} :: Last reviewed ${reviewed} (${age_days} days)"
                doc_stale=$((doc_stale + 1))
            else
                echo "DOCS: OK :: ${path} :: Last reviewed ${reviewed} (${age_days} days)"
            fi
        elif [[ "$line" =~ $reviewed_missing_regex ]]; then
            local path_missing="${BASH_REMATCH[1]}"
            echo "DOCS: MISSING DATE :: ${path_missing}"
            doc_stale=$((doc_stale + 1))
        fi
    done < "$DOC_INDEX"
}

report_section "Sweep Metadata"
echo "SWEEP: ${SWEEP_TS}"
echo "SWEEP: repo=${PROJECT_ROOT}"

run_mechanical_checks
run_convention_consistency
run_belief_coverage
run_belief_gap_analysis
run_doc_freshness

report_section "Summary"
echo "SUMMARY: mechanical_fail=${mechanical_fail}"
echo "SUMMARY: consistency_outliers=${consistency_outliers}"
echo "SUMMARY: belief_fail=${belief_fail}"
echo "SUMMARY: belief_skipped=${belief_skipped}"
echo "SUMMARY: doc_stale=${doc_stale}"

if [[ "$mechanical_fail" -gt 0 || "$belief_fail" -gt 0 || "$doc_stale" -gt 0 ]]; then
    echo "SWEEP: completed with findings"
else
    echo "SWEEP: clean"
fi
