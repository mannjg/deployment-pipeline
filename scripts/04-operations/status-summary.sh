#!/bin/bash
set -euo pipefail
# Agent-oriented status summary (short, grep-friendly, stable output)
#
# Usage: ./status-summary.sh [cluster-config]
#
# Notes:
# - Requires CLUSTER_CONFIG env var or explicit config file arg.
# - Does not fail on missing credentials; reports partial visibility.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"
source "$PROJECT_ROOT/scripts/lib/logging.sh"
source "$PROJECT_ROOT/scripts/lib/credentials.sh"

has_cmd() {
    command -v "$1" &>/dev/null
}

print_header() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    echo "status-summary | ts=${now} | cluster=${CLUSTER_NAME} | config=${CLUSTER_CONFIG}"
    echo "component | status | details"
}

status_line() {
    printf "%s | %s | %s\n" "$1" "$2" "$3"
}

k8s_ready=0
k8s_issue="ok"
if ! has_cmd kubectl; then
    k8s_issue="kubectl=missing"
elif kubectl cluster-info &>/dev/null; then
    k8s_ready=1
else
    k8s_issue="cluster=unreachable"
fi

curl_ready=0
if has_cmd curl; then
    curl_ready=1
fi

jq_ready=0
if has_cmd jq; then
    jq_ready=1
fi

gitlab_status() {
    local details=()
    local status="warn"
    local ok=1

    if [[ $k8s_ready -eq 1 ]]; then
        local pods
        pods=$(kubectl get pods -n "$GITLAB_NAMESPACE" -l app=gitlab -o json 2>/dev/null || true)
        local running=0
        if [[ $jq_ready -eq 1 && -n "$pods" ]]; then
            running=$(echo "$pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
        fi
        if [[ "$running" -gt 0 ]]; then
            details+=("pod=running")
            ok=0
        else
            details+=("pod=missing")
        fi
    else
        details+=("$k8s_issue")
    fi

    if [[ $curl_ready -eq 1 ]]; then
        local http
        http=$(curl -sk -o /dev/null -w "%{http_code}" "$GITLAB_URL_EXTERNAL/" 2>/dev/null || true)
        if [[ "$http" == "200" || "$http" == "302" ]]; then
            details+=("http=$http")
        else
            details+=("http=${http:-na}")
            ok=1
        fi
    else
        details+=("curl=missing")
        ok=1
    fi

    if gitlab_token=$(try_gitlab_token 2>/dev/null); then
        if [[ $curl_ready -eq 1 && $jq_ready -eq 1 ]]; then
            local user
            user=$(curl -sk -H "PRIVATE-TOKEN: $gitlab_token" \
                "$GITLAB_URL_EXTERNAL/api/v4/user" 2>/dev/null | jq -r '.username // empty')
            if [[ -n "$user" ]]; then
                details+=("api=ok")
            else
                details+=("api=fail")
                ok=1
            fi
        else
            details+=("api=skipped")
            ok=1
        fi
    else
        details+=("api=auth-missing")
        ok=1
    fi

    if [[ $ok -eq 0 ]]; then
        status="ok"
    fi
    status_line "gitlab" "$status" "$(IFS=' '; echo "${details[*]}")"
}

jenkins_status() {
    local details=()
    local status="warn"
    local ok=1

    if [[ $k8s_ready -eq 1 ]]; then
        local pods
        pods=$(kubectl get pods -n "$JENKINS_NAMESPACE" -l app=jenkins -o json 2>/dev/null || true)
        local running=0
        if [[ $jq_ready -eq 1 && -n "$pods" ]]; then
            running=$(echo "$pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
        fi
        if [[ "$running" -gt 0 ]]; then
            details+=("pod=running")
            ok=0
        else
            details+=("pod=missing")
        fi
    else
        details+=("$k8s_issue")
    fi

    if [[ $curl_ready -eq 1 ]]; then
        local http
        http=$(curl -sk -o /dev/null -w "%{http_code}" "$JENKINS_URL_EXTERNAL/login" 2>/dev/null || true)
        if [[ "$http" == "200" || "$http" == "302" || "$http" == "403" ]]; then
            details+=("http=$http")
        else
            details+=("http=${http:-na}")
            ok=1
        fi
    else
        details+=("curl=missing")
        ok=1
    fi

    if [[ $ok -eq 0 ]]; then
        status="ok"
    fi
    status_line "jenkins" "$status" "$(IFS=' '; echo "${details[*]}")"
}

nexus_status() {
    local details=()
    local status="warn"
    local ok=1

    if [[ $k8s_ready -eq 1 ]]; then
        local pods
        pods=$(kubectl get pods -n "$NEXUS_NAMESPACE" -l app=nexus -o json 2>/dev/null || true)
        local running=0
        if [[ $jq_ready -eq 1 && -n "$pods" ]]; then
            running=$(echo "$pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
        fi
        if [[ "$running" -gt 0 ]]; then
            details+=("pod=running")
            ok=0
        else
            details+=("pod=missing")
        fi
    else
        details+=("$k8s_issue")
    fi

    if [[ $curl_ready -eq 1 ]]; then
        local http
        http=$(curl -sk -o /dev/null -w "%{http_code}" "$MAVEN_REPO_URL_EXTERNAL/" 2>/dev/null || true)
        if [[ "$http" == "200" || "$http" == "302" ]]; then
            details+=("http=$http")
        else
            details+=("http=${http:-na}")
            ok=1
        fi
    else
        details+=("curl=missing")
        ok=1
    fi

    if [[ $ok -eq 0 ]]; then
        status="ok"
    fi
    status_line "nexus" "$status" "$(IFS=' '; echo "${details[*]}")"
}

argocd_status() {
    local details=()
    local status="warn"
    local ok=1

    if [[ $k8s_ready -eq 1 ]]; then
        local server_pods
        server_pods=$(kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=argocd-server -o json 2>/dev/null || true)
        local running=0
        if [[ $jq_ready -eq 1 && -n "$server_pods" ]]; then
            running=$(echo "$server_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
        fi
        if [[ "$running" -gt 0 ]]; then
            details+=("pod=running")
            ok=0
        else
            details+=("pod=missing")
        fi
    else
        details+=("$k8s_issue")
    fi

    if [[ $curl_ready -eq 1 ]]; then
        local http
        http=$(curl -sk -o /dev/null -w "%{http_code}" "$ARGOCD_URL_EXTERNAL/" 2>/dev/null || true)
        if [[ "$http" == "200" || "$http" == "302" || "$http" == "403" ]]; then
            details+=("http=$http")
        else
            details+=("http=${http:-na}")
            ok=1
        fi
    else
        details+=("curl=missing")
        ok=1
    fi

    if [[ $ok -eq 0 ]]; then
        status="ok"
    fi
    status_line "argocd" "$status" "$(IFS=' '; echo "${details[*]}")"
}

jenkins_job_status() {
    local details=()
    local status="warn"
    local any_issue=0
    local any_success=0

    if ! try_jenkins_credentials &>/dev/null; then
        status_line "jenkins-jobs" "warn" "auth-missing"
        return 0
    fi

    if [[ $curl_ready -ne 1 || $jq_ready -ne 1 ]]; then
        status_line "jenkins-jobs" "warn" "curl/jq missing"
        return 0
    fi

    local auth
    auth=$(try_jenkins_credentials)
    local j_user="${auth%%:*}"
    local j_token="${auth#*:}"

    job_result() {
        local job_path="$1"
        local label="$2"
        local json
        json=$(curl -sk -u "$j_user:$j_token" \
            "$JENKINS_URL_EXTERNAL/job/$job_path/lastBuild/api/json" 2>/dev/null || true)
        if [[ -z "$json" ]]; then
            details+=("${label}=missing")
            any_issue=1
            return
        fi
        local building result
        building=$(echo "$json" | jq -r '.building // false')
        result=$(echo "$json" | jq -r '.result // empty')
        if [[ "$building" == "true" ]]; then
            details+=("${label}=BUILDING")
            any_success=1
        elif [[ -n "$result" ]]; then
            details+=("${label}=$result")
            if [[ "$result" == "SUCCESS" ]]; then
                any_success=1
            else
                any_issue=1
            fi
        else
            details+=("${label}=UNKNOWN")
            any_issue=1
        fi
    }

    job_result "$JENKINS_APP_JOB_PATH" "app"
    job_result "$JENKINS_PROMOTE_JOB_NAME" "promote"
    job_result "${K8S_DEPLOYMENTS_JOB}/job/main" "deploy"

    if [[ $any_success -eq 1 && $any_issue -eq 0 ]]; then
        status="ok"
    fi
    status_line "jenkins-jobs" "$status" "$(IFS=' '; echo "${details[*]}")"
}

deployments_status() {
    local details=()
    local status="warn"
    local any_issue=0
    local any_running=0

    if [[ $k8s_ready -ne 1 || $jq_ready -ne 1 ]]; then
        status_line "deployments" "warn" "$k8s_issue"
        return 0
    fi

    for env in "$DEV_NAMESPACE" "$STAGE_NAMESPACE" "$PROD_NAMESPACE"; do
        local data
        data=$(kubectl get deploy -n "$env" -l "app=$APP_REPO_NAME" -o json 2>/dev/null || true)
        local count
        count=$(echo "$data" | jq '.items | length' 2>/dev/null || echo "0")
        if [[ "$count" -eq 0 ]]; then
            details+=("${env}=none")
            continue
        fi
        any_running=1

        local ready desired image
        ready=$(echo "$data" | jq '[.items[].status.readyReplicas // 0] | add')
        desired=$(echo "$data" | jq '[.items[].status.replicas // 0] | add')
        image=$(echo "$data" | jq -r '.items[0].spec.template.spec.containers[0].image // empty' | sed 's/.*://')
        details+=("${env}=${ready}/${desired} image=${image:-unknown}")
        if [[ "$ready" -ne "$desired" || "$desired" -eq 0 ]]; then
            any_issue=1
        fi
    done

    if [[ $any_running -eq 1 && $any_issue -eq 0 ]]; then
        status="ok"
    fi
    status_line "deployments" "$status" "$(IFS=' '; echo "${details[*]}")"
}

main() {
    print_header
    gitlab_status
    jenkins_status
    argocd_status
    nexus_status
    jenkins_job_status
    deployments_status
}

main "$@"
