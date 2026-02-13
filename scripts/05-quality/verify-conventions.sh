#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/logging.sh
if [[ -f "$PROJECT_ROOT/scripts/lib/logging.sh" ]]; then
    source "$PROJECT_ROOT/scripts/lib/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

MODE="warn"
TIERS=()
RG_AVAILABLE=1

usage() {
    cat <<'USAGE'
Usage: scripts/05-quality/verify-conventions.sh [--warn|--strict] [--tier N]

Options:
  --warn       Report issues but exit 0 (default)
  --strict     Exit non-zero if any issues are found
  --tier N     Run only a specific tier (1-4). May be repeated.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --warn)
            MODE="warn"
            shift
            ;;
        --strict)
            MODE="strict"
            shift
            ;;
        --tier)
            if [[ -z "${2:-}" ]]; then
                log_error "--tier requires a value"
                exit 1
            fi
            TIERS+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ ${#TIERS[@]} -eq 0 ]]; then
    TIERS=(1 2 3 4)
fi

ISSUES=0

issue() {
    local tier="$1"
    local location="$2"
    local message="$3"
    local reference="$4"
    local fix="$5"
    echo "[T${tier}] ${location} :: ${message}"
    echo "  Reference: ${reference}"
    echo "  Fix: ${fix}"
    echo
    ISSUES=$((ISSUES + 1))
}

if ! command -v rg >/dev/null 2>&1; then
    RG_AVAILABLE=0
    issue 2 "rg" "ripgrep (rg) not installed" \
        "CORE_BELIEFS.md (boring, legible tooling)" \
        "Install ripgrep or run checks in an environment where it is available"
fi

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

run_tier_1() {
    log_info "Tier 1: structural rules"

    local script
    while IFS= read -r script; do
        local rel_path
        rel_path="${script#"$PROJECT_ROOT"/}"
        local base
        base="$(basename "$script")"

        # Script naming convention (verb-noun.sh)
        if ! is_lib_script "$script"; then
            if [[ ! "$base" =~ ^[a-z0-9]+(-[a-z0-9]+)+\.sh$ ]]; then
                issue 1 "$rel_path" "Script name should use verb-noun.sh convention" \
                    "CORE_BELIEFS.md (agent legibility)" \
                    "Rename to a verb-noun style (e.g., sync-to-gitlab.sh)"
            fi
        fi

        # Shebang check
        local first_line
        first_line="$(head -n 1 "$script" || true)"
        if [[ ! "$first_line" =~ ^#!/(usr/bin/env[[:space:]]+)?bash$ ]]; then
            issue 1 "$rel_path:1" "Missing or non-bash shebang" \
                "CORE_BELIEFS.md (boring, legible tooling)" \
                "Use '#!/bin/bash' or '#!/usr/bin/env bash' as the first line"
        fi

        # set -euo pipefail for non-lib scripts
        if ! is_lib_script "$script"; then
            if [[ "$RG_AVAILABLE" -eq 1 ]]; then
                if ! rg -q "set -euo pipefail" "$script" 2>/dev/null; then
                    issue 1 "$rel_path" "Missing 'set -euo pipefail'" \
                        "CORE_BELIEFS.md (boring, legible tooling)" \
                        "Add 'set -euo pipefail' near the top of the script"
                fi
            fi
        fi

        # Standard source patterns (SCRIPT_DIR + PROJECT_ROOT)
        if [[ "$rel_path" == scripts/* ]] && ! is_lib_script "$script" && ! is_demo_or_test_script "$script"; then
            if [[ "$RG_AVAILABLE" -eq 1 ]]; then
                if ! rg -q "SCRIPT_DIR=" "$script" 2>/dev/null || ! rg -q "PROJECT_ROOT=" "$script" 2>/dev/null; then
                    issue 1 "$rel_path" "Missing SCRIPT_DIR/PROJECT_ROOT bootstrap" \
                        "CORE_BELIEFS.md (agent legibility)" \
                        "Add SCRIPT_DIR and PROJECT_ROOT definitions for consistent sourcing"
                fi
            fi
        fi

        # File size limits
        local line_count
        line_count=$(wc -l < "$script" | tr -d ' ')
        if [[ "$line_count" -gt 400 ]]; then
            issue 1 "$rel_path" "Script is ${line_count} lines (over 400)" \
                "CORE_BELIEFS.md (agent legibility)" \
                "Split into smaller scripts or move reusable logic into scripts/lib"
        fi
    done < <(list_shell_scripts)

    # Directory placement rules
    local bad_dir
    while IFS= read -r bad_dir; do
        local rel_path
        rel_path="${bad_dir#"$PROJECT_ROOT"/}"
        issue 1 "$rel_path" "Script located in unrecognized scripts/ subdirectory" \
            "CORE_BELIEFS.md (agent legibility)" \
            "Place scripts under scripts/{01-infrastructure,02-configure,03-pipelines,04-operations,debug,demo,lib,test,teardown}"
    done < <(find "$PROJECT_ROOT/scripts" -mindepth 2 -maxdepth 2 -type f -name '*.sh' \
        ! -path "$PROJECT_ROOT/scripts/01-infrastructure/*" \
        ! -path "$PROJECT_ROOT/scripts/02-configure/*" \
        ! -path "$PROJECT_ROOT/scripts/03-pipelines/*" \
        ! -path "$PROJECT_ROOT/scripts/04-operations/*" \
        ! -path "$PROJECT_ROOT/scripts/debug/*" \
        ! -path "$PROJECT_ROOT/scripts/demo/*" \
        ! -path "$PROJECT_ROOT/scripts/lib/*" \
        ! -path "$PROJECT_ROOT/scripts/test/*" \
        ! -path "$PROJECT_ROOT/scripts/teardown/*" \
        ! -path "$PROJECT_ROOT/scripts/*.sh" \
        -print)

    # No hardcoded namespace names outside config files
    while IFS= read -r script; do
        local rel_path
        rel_path="${script#"$PROJECT_ROOT"/}"
        awk -v file="$rel_path" '
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
        ' "$script" | while IFS=: read -r file line ns; do
            issue 1 "$file:$line" "Hardcoded namespace '$ns'" \
                "ANTI_PATTERNS.md (Operations: Don't hardcode namespace names)" \
                "Use \"\$K8S_NAMESPACE\" or a config-sourced namespace variable"
        done
    done < <(list_shell_scripts)
}

run_tier_2() {
    log_info "Tier 2: pattern consistency"

    # shellcheck
    if command -v shellcheck >/dev/null 2>&1; then
        while IFS= read -r script; do
            local shellcheck_output
            shellcheck_output=$(shellcheck -x "$script" 2>&1 || true)
            if [[ -n "$shellcheck_output" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ ^([^:]+):([0-9]+):([0-9]+):[[:space:]](.*)$ ]]; then
                        local file="${BASH_REMATCH[1]}"
                        local lineno="${BASH_REMATCH[2]}"
                        local message="${BASH_REMATCH[4]}"
                        local rel_path="${file#"$PROJECT_ROOT"/}"
                        issue 2 "$rel_path:$lineno" "shellcheck: $message" \
                            "CORE_BELIEFS.md (boring, legible tooling)" \
                            "Run: shellcheck -x $rel_path and address the warning"
                    fi
                done <<< "$shellcheck_output"
            fi
        done < <(list_shell_scripts)
    else
        issue 2 "shellcheck" "shellcheck not installed" \
            "CORE_BELIEFS.md (boring, legible tooling)" \
            "Install shellcheck or run checks in an environment where it is available"
    fi

    # Logging patterns (repo scripts only, excluding demo/test/lib)
    if [[ "$RG_AVAILABLE" -ne 1 ]]; then
        log_warn "rg not available; skipping Tier 2 content scans"
        return
    fi
    while IFS= read -r script; do
        if is_lib_script "$script" || is_demo_or_test_script "$script"; then
            continue
        fi
        local rel_path
        rel_path="${script#"$PROJECT_ROOT"/}"

        if rg -q "\becho\b" "$script" 2>/dev/null; then
            if ! rg -q "logging\.sh" "$script" 2>/dev/null; then
                local line
                line=$(rg -n "\becho\b" "$script" | head -n 1 | cut -d: -f2)
                issue 2 "$rel_path:${line:-1}" "Uses echo without sourcing scripts/lib/logging.sh" \
                    "CORE_BELIEFS.md (agent legibility)" \
                    "Source scripts/lib/logging.sh and use log_info/log_warn/log_error"
            fi
        fi
    done < <(list_shell_scripts)

    # Credential access patterns
    while IFS= read -r match; do
        local file
        file="${match%%:*}"
        local lineno
        lineno="${match#*:}"
        lineno="${lineno%%:*}"
        local rel_path="${file#"$PROJECT_ROOT"/}"
        issue 2 "$rel_path:$lineno" "Inline kubectl secret access detected" \
            "ANTI_PATTERNS.md (Shell scripts: Don't inline credential access)" \
            "Use scripts/lib/credentials.sh for secret retrieval"
    done < <(rg -n "kubectl.*\bsecret\b" "$PROJECT_ROOT" \
        -g '*.sh' \
        -g '!scripts/lib/credentials.sh' \
        -g '!k8s-deployments/scripts/lib/*' \
        -g '!scripts/demo/*' \
        -g '!scripts/test/*' \
        || true)

    # CLI wrapper usage
    while IFS= read -r match; do
        local file
        file="${match%%:*}"
        local lineno
        lineno="${match#*:}"
        lineno="${lineno%%:*}"
        local rel_path="${file#"$PROJECT_ROOT"/}"
        issue 2 "$rel_path:$lineno" "Direct API curl detected (use CLI wrapper)" \
            "CORE_BELIEFS.md (CLI wrappers over direct API calls)" \
            "Use scripts/04-operations/gitlab-cli.sh or scripts/04-operations/jenkins-cli.sh."
    done < <(rg -n "curl .*api/v4|curl .*GITLAB_URL|curl .*JENKINS_URL|curl .*jenkins" "$PROJECT_ROOT" \
        -g '*.sh' \
        -g '!scripts/04-operations/gitlab-cli.sh' \
        -g '!scripts/04-operations/jenkins-cli.sh' \
        -g '!k8s-deployments/scripts/gitlab-api.sh' \
        -g '!scripts/demo/*' \
        -g '!scripts/test/*' \
        || true)
}

run_tier_3() {
    log_info "Tier 3: Jenkinsfile enforcement"

    local jenkinsfiles
    mapfile -t jenkinsfiles < <(find "$PROJECT_ROOT" \
        -path "$PROJECT_ROOT/.git" -prune -o \
        -path "$PROJECT_ROOT/.worktrees" -prune -o \
        -name 'Jenkinsfile*' -print)

    if [[ ${#jenkinsfiles[@]} -eq 0 ]]; then
        return
    fi

    # Inline sh block length
    if ! command -v python3 >/dev/null 2>&1; then
        issue 3 "python3" "python3 not installed" \
            "CORE_BELIEFS.md (boring, legible tooling)" \
            "Install python3 or run checks in an environment where it is available"
        return
    fi

    while IFS=: read -r file line count; do
        local rel_path
        rel_path="${file#"$PROJECT_ROOT"/}"
        issue 3 "$rel_path:$line" "Inline sh block is ${count} lines (over 15)" \
            "ANTI_PATTERNS.md (Jenkinsfiles: Don't put logic in inline sh blocks over ~15 lines)" \
            "Move logic into a script under scripts/04-operations and call it"
    done < <(python3 - <<'PY' "${jenkinsfiles[@]}"
import re
import sys

limit = 15
files = sys.argv[1:]

for path in files:
    try:
        lines = open(path, 'r', encoding='utf-8').read().splitlines()
    except Exception:
        continue

    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.search(r"\bsh\s+([\'\"]){3}", line)
        if m:
            quote = m.group(0)[-3:]
            start = i + 1
            i += 1
            count = 0
            while i < len(lines) and quote not in lines[i]:
                count += 1
                i += 1
            if i < len(lines) and count > limit:
                print(f"{path}:{start}:{count}")
        i += 1
PY
    )

    if [[ "$RG_AVAILABLE" -ne 1 ]]; then
        log_warn "rg not available; skipping Tier 3 content scans"
        return
    fi

    # Hardcoded URLs
    while IFS= read -r match; do
        local file
        file="${match%%:*}"
        local lineno
        lineno="${match#*:}"
        lineno="${lineno%%:*}"
        local rel_path
        rel_path="${file#"$PROJECT_ROOT"/}"
        issue 3 "$rel_path:$lineno" "Hardcoded URL detected" \
            "ANTI_PATTERNS.md (Jenkinsfiles: Don't hardcode URLs)" \
            "Use environment variables or pipeline parameters instead"
    done < <(rg -n "https?://" "$PROJECT_ROOT" -g 'Jenkinsfile*' || true)

    # Credentials should use withCredentials
    for file in "${jenkinsfiles[@]}"; do
        if rg -q "credentialsId" "$file" && ! rg -q "withCredentials" "$file"; then
            local rel_path
            rel_path="${file#"$PROJECT_ROOT"/}"
            issue 3 "$rel_path" "credentialsId used without withCredentials" \
                "ANTI_PATTERNS.md (Jenkinsfiles: Credential access only via withCredentials)" \
                "Wrap credential usage in withCredentials blocks"
        fi
    done

    # Environment branch builds don't regenerate manifests (heuristic)
    for file in "${jenkinsfiles[@]}"; do
        if rg -q "Generate Manifests" "$file" && ! rg -q "IS_ENV_BRANCH|envBranchList|PIPELINE_PROMOTE_PREFIX" "$file"; then
            local rel_path
            rel_path="${file#"$PROJECT_ROOT"/}"
            issue 3 "$rel_path" "Generate Manifests stage lacks env-branch guard" \
                "ANTI_PATTERNS.md (Jenkinsfiles: Don't regenerate manifests on env branches)" \
                "Gate manifest generation to feature branches or non-env branches only"
        fi
    done

    # Feature branch builds don't deploy to live environments (heuristic)
    for file in "${jenkinsfiles[@]}"; do
        if rg -q "Deploy to Environment" "$file" && ! rg -q "IS_ENV_BRANCH|envBranchList|BRANCH_NAME" "$file"; then
            local rel_path
            rel_path="${file#"$PROJECT_ROOT"/}"
            issue 3 "$rel_path" "Deploy stage lacks branch guard" \
                "ANTI_PATTERNS.md (Jenkinsfiles: Don't deploy from feature branches)" \
                "Add branch gating to restrict deploys to env branches or main"
        fi
    done
}

run_tier_4() {
    log_info "Tier 4: CUE schema enforcement"

    # cue vet -c=false ./... for k8s-deployments (allow incomplete schemas)
    if command -v cue >/dev/null 2>&1; then
        if [[ -d "$PROJECT_ROOT/k8s-deployments" ]]; then
            local cue_output
            cue_output=$(cd "$PROJECT_ROOT/k8s-deployments" && cue vet -c=false ./... 2>&1 || true)
            if [[ -n "$cue_output" ]]; then
                issue 4 "k8s-deployments" "cue vet -c=false ./... failed" \
                    "CORE_BELIEFS.md (CUE over raw YAML)" \
                    "Run 'cd k8s-deployments && cue vet -c=false ./...' and address the errors"
            fi
        fi
    else
        issue 4 "cue" "cue CLI not installed" \
            "CORE_BELIEFS.md (CUE over raw YAML)" \
            "Install cue or run checks in an environment where it is available"
    fi

    # App CUE files should not reference env-specific values directly
    if [[ -d "$PROJECT_ROOT/k8s-deployments/services/apps" ]]; then
        if [[ "$RG_AVAILABLE" -ne 1 ]]; then
            log_warn "rg not available; skipping env-specific reference scan"
        else
        while IFS= read -r match; do
            local file
            file="${match%%:*}"
            local lineno
            lineno="${match#*:}"
            lineno="${lineno%%:*}"
            local rel_path
            rel_path="${file#"$PROJECT_ROOT"/}"
            issue 4 "$rel_path:$lineno" "App CUE references env-specific values" \
                "ANTI_PATTERNS.md (CUE schemas: Don't reference env-specific values from app definitions)" \
                "Move env-specific data to env.cue or appConfig overrides"
        done < <(rg -n "\benvs\." "$PROJECT_ROOT/k8s-deployments/services/apps" -g '*.cue' || true)
        fi
    fi

    # Every field in #App has default or is explicitly required (heuristic)
    local app_schema="$PROJECT_ROOT/k8s-deployments/services/core/app.cue"
    if [[ -f "$app_schema" ]]; then
        if ! command -v python3 >/dev/null 2>&1; then
            issue 4 "python3" "python3 not installed" \
                "CORE_BELIEFS.md (boring, legible tooling)" \
                "Install python3 or run checks in an environment where it is available"
            return
        fi
        while IFS=: read -r file line; do
            local rel_path
            rel_path="${file#"$PROJECT_ROOT"/}"
            issue 4 "$rel_path:$line" "Optional field in #App lacks a default" \
                "CORE_BELIEFS.md (CUE over raw YAML)" \
                "Add a default (*value | type) or make the field required"
        done < <(python3 - <<'PY' "$app_schema"
import re
import sys

path = sys.argv[1]
lines = open(path, 'r', encoding='utf-8').read().splitlines()

in_app = False
brace_depth = 0
start_line = 0

for idx, line in enumerate(lines, start=1):
    if not in_app:
        if re.match(r"^#App:\s*{", line):
            in_app = True
            brace_depth = 1
            start_line = idx
        continue

    brace_depth += line.count('{')
    brace_depth -= line.count('}')

    # detect optional fields without defaults
    m = re.match(r"\s*([A-Za-z0-9_]+\?)\s*:\s*(.+)", line)
    if m:
        value = m.group(2)
        if "| *" in value:
            continue
        if re.search(r"\*\s*[^|]", value):
            continue
        print(f"{path}:{idx}")

    if brace_depth == 0 and in_app:
        break
PY
        )
    fi
}

for tier in "${TIERS[@]}"; do
    case "$tier" in
        1) run_tier_1 ;;
        2) run_tier_2 ;;
        3) run_tier_3 ;;
        4) run_tier_4 ;;
        *)
            log_error "Unknown tier: $tier"
            exit 1
            ;;
    esac
done

if [[ "$MODE" == "strict" && "$ISSUES" -gt 0 ]]; then
    log_error "Convention checks failed: $ISSUES issue(s) found"
    exit 1
fi

log_info "Convention checks complete: $ISSUES issue(s) found"
exit 0
