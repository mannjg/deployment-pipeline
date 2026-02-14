#!/usr/bin/env bash
# Cluster Control Script
# Provides pause/resume/status commands for cluster lifecycle management
#
# Usage: ./cluster-ctl.sh <command> <config-file>
#
# Commands:
#   pause   - Scale all deployments to 0 (stores original replica counts)
#   resume  - Restore deployments to original replica counts
#   status  - Show deployment status for the cluster
#
# This provides defense against accidentally operating on the wrong cluster
# when hardcoded values exist during multi-cluster migration.

set -uo pipefail

# =============================================================================
# Colors and Logging
# =============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# =============================================================================
# Dependencies
# =============================================================================

check_dependencies() {
    local missing=()

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v kubectl &>/dev/null; then
        missing+=("kubectl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") <command> <config-file>

Commands:
  pause   Scale all infrastructure deployments to 0 replicas
          Original replica counts are stored in ConfigMaps for later restore

  resume  Restore deployments to their original replica counts
          Reads from ConfigMaps created during pause

  status  Show current deployment status for the cluster

Arguments:
  config-file  Path to cluster configuration file (e.g., config/clusters/alpha.env)

Examples:
  $(basename "$0") pause config/clusters/alpha.env
  $(basename "$0") resume config/clusters/alpha.env
  $(basename "$0") status config/clusters/beta.env

Notes:
  - The pause command provides defense against accidentally using the wrong cluster
  - Paused clusters have all infrastructure scaled to 0 replicas
  - Resume restores ORIGINAL replica counts (not just 1)
EOF
    exit 1
}

# =============================================================================
# Configuration
# =============================================================================

CONFIGMAP_NAME="cluster-ctl-replicas"

validate_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    # Source the config
    # shellcheck source=/dev/null
    source "$config_file"

    # Check required variables
    local required_vars=(
        "CLUSTER_NAME"
        "GITLAB_NAMESPACE"
        "JENKINS_NAMESPACE"
        "NEXUS_NAMESPACE"
        "ARGOCD_NAMESPACE"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Config file missing required variables: ${missing[*]}"
        exit 1
    fi

    log_info "Config loaded: cluster=${CLUSTER_NAME}"
}

get_infrastructure_namespaces() {
    # Returns infrastructure namespaces that exist
    local namespaces=("$GITLAB_NAMESPACE" "$JENKINS_NAMESPACE" "$NEXUS_NAMESPACE" "$ARGOCD_NAMESPACE")
    local existing=()

    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null; then
            existing+=("$ns")
        else
            log_warn "Namespace does not exist, skipping: $ns"
        fi
    done

    echo "${existing[@]}"
}

# =============================================================================
# Pause Command
# =============================================================================

store_replica_counts() {
    local namespace="$1"

    log_info "Storing replica counts for namespace: $namespace"

    # Build ConfigMap data from deployments
    local deploy_data=""
    local deploys
    deploys=$(kubectl get deployments -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}' 2>/dev/null)

    if [[ -n "$deploys" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local name="${line%%=*}"
                local replicas="${line#*=}"
                deploy_data="${deploy_data}  deploy.${name}: \"${replicas}\"\n"
                log_debug "  Deployment: $name (replicas=$replicas)"
            fi
        done <<< "$deploys"
    fi

    # Build ConfigMap data from statefulsets
    local sts_data=""
    local statefulsets
    statefulsets=$(kubectl get statefulsets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}' 2>/dev/null)

    if [[ -n "$statefulsets" ]]; then
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local name="${line%%=*}"
                local replicas="${line#*=}"
                sts_data="${sts_data}  sts.${name}: \"${replicas}\"\n"
                log_debug "  StatefulSet: $name (replicas=$replicas)"
            fi
        done <<< "$statefulsets"
    fi

    if [[ -z "$deploy_data" && -z "$sts_data" ]]; then
        log_warn "No deployments or statefulsets found in $namespace"
        return 0
    fi

    # Create or update ConfigMap
    local cm_yaml
    cm_yaml=$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: cluster-ctl
data:
$(echo -e "${deploy_data}${sts_data}")
EOF
)

    if ! echo "$cm_yaml" | kubectl apply -f - >/dev/null; then
        log_error "Failed to create ConfigMap in $namespace"
        return 1
    fi
    log_info "Stored replica counts in ConfigMap: $namespace/$CONFIGMAP_NAME"
}

scale_down_namespace() {
    local namespace="$1"

    log_info "Scaling down namespace: $namespace"

    # Scale deployments to 0
    local deploys
    deploys=$(kubectl get deployments -n "$namespace" -o name 2>/dev/null)
    if [[ -n "$deploys" ]]; then
        while IFS= read -r deploy; do
            if [[ -n "$deploy" ]]; then
                kubectl scale "$deploy" -n "$namespace" --replicas=0
                log_debug "  Scaled: $deploy"
            fi
        done <<< "$deploys"
    fi

    # Scale statefulsets to 0
    local statefulsets
    statefulsets=$(kubectl get statefulsets -n "$namespace" -o name 2>/dev/null)
    if [[ -n "$statefulsets" ]]; then
        while IFS= read -r sts; do
            if [[ -n "$sts" ]]; then
                kubectl scale "$sts" -n "$namespace" --replicas=0
                log_debug "  Scaled: $sts"
            fi
        done <<< "$statefulsets"
    fi
}

cmd_pause() {
    log_info "Pausing cluster: $CLUSTER_NAME"
    echo ""

    # Get existing namespaces
    local namespaces
    read -ra namespaces <<< "$(get_infrastructure_namespaces)"

    if [[ ${#namespaces[@]} -eq 0 ]]; then
        log_warn "No infrastructure namespaces found"
        return 0
    fi

    local pause_errors=0

    # Store replica counts and scale down each namespace
    for ns in "${namespaces[@]}"; do
        if ! store_replica_counts "$ns"; then
            pause_errors=$((pause_errors + 1))
        fi
        scale_down_namespace "$ns"
        echo ""
    done

    if [[ $pause_errors -gt 0 ]]; then
        log_error "Cluster pause completed with $pause_errors error(s)"
        return 1
    fi

    log_info "Cluster paused: $CLUSTER_NAME"
    log_info "Use 'cluster-ctl.sh resume' to restore"
}

# =============================================================================
# Resume Command
# =============================================================================

restore_namespace() {
    local namespace="$1"
    local restore_errors=0

    log_info "Restoring namespace: $namespace"

    # Check if ConfigMap exists
    if ! kubectl get configmap "$CONFIGMAP_NAME" -n "$namespace" &>/dev/null; then
        log_warn "No replica data found in $namespace, skipping"
        return 0
    fi

    # Read ConfigMap data
    local cm_data
    if ! cm_data=$(kubectl get configmap "$CONFIGMAP_NAME" -n "$namespace" -o json 2>/dev/null); then
        log_error "Failed to read ConfigMap in $namespace"
        return 1
    fi

    if [[ -z "$cm_data" ]]; then
        log_warn "Could not read ConfigMap in $namespace"
        return 1
    fi

    # Restore deployments
    local deploy_keys
    if ! deploy_keys=$(echo "$cm_data" | jq -r '.data | keys[] | select(startswith("deploy."))' 2>/dev/null); then
        log_error "Failed to parse ConfigMap data for deployments in $namespace"
        restore_errors=$((restore_errors + 1))
    fi

    if [[ -n "$deploy_keys" ]]; then
        while IFS= read -r key; do
            if [[ -n "$key" ]]; then
                local name="${key#deploy.}"
                local replicas
                if ! replicas=$(echo "$cm_data" | jq -r --arg k "$key" '.data[$k]' 2>/dev/null); then
                    log_error "  Failed to parse replica count for deployment: $name"
                    restore_errors=$((restore_errors + 1))
                    continue
                fi

                if kubectl get deployment "$name" -n "$namespace" &>/dev/null; then
                    if ! kubectl scale deployment "$name" -n "$namespace" --replicas="$replicas"; then
                        log_error "  Failed to scale deployment: $name"
                        restore_errors=$((restore_errors + 1))
                    else
                        log_debug "  Deployment: $name (replicas=$replicas)"
                    fi
                else
                    log_warn "  Deployment not found: $name"
                fi
            fi
        done <<< "$deploy_keys"
    fi

    # Restore statefulsets
    local sts_keys
    if ! sts_keys=$(echo "$cm_data" | jq -r '.data | keys[] | select(startswith("sts."))' 2>/dev/null); then
        log_error "Failed to parse ConfigMap data for statefulsets in $namespace"
        restore_errors=$((restore_errors + 1))
    fi

    if [[ -n "$sts_keys" ]]; then
        while IFS= read -r key; do
            if [[ -n "$key" ]]; then
                local name="${key#sts.}"
                local replicas
                if ! replicas=$(echo "$cm_data" | jq -r --arg k "$key" '.data[$k]' 2>/dev/null); then
                    log_error "  Failed to parse replica count for statefulset: $name"
                    restore_errors=$((restore_errors + 1))
                    continue
                fi

                if kubectl get statefulset "$name" -n "$namespace" &>/dev/null; then
                    if ! kubectl scale statefulset "$name" -n "$namespace" --replicas="$replicas"; then
                        log_error "  Failed to scale statefulset: $name"
                        restore_errors=$((restore_errors + 1))
                    else
                        log_debug "  StatefulSet: $name (replicas=$replicas)"
                    fi
                else
                    log_warn "  StatefulSet not found: $name"
                fi
            fi
        done <<< "$sts_keys"
    fi

    if [[ $restore_errors -gt 0 ]]; then
        log_error "Encountered $restore_errors error(s) restoring $namespace"
        return 1
    fi
}

wait_for_pods() {
    local namespace="$1"
    local timeout="${2:-120}"

    log_info "Waiting for pods in $namespace to be ready (timeout: ${timeout}s)..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            log_warn "Timeout waiting for pods in $namespace"
            return 1
        fi

        # Check if all pods are ready
        local not_ready
        not_ready=$(kubectl get pods -n "$namespace" -o json 2>/dev/null | \
            jq '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length')

        if [[ "$not_ready" == "0" ]]; then
            log_info "All pods ready in $namespace"
            return 0
        fi

        sleep 5
    done
}

cmd_resume() {
    log_info "Resuming cluster: $CLUSTER_NAME"
    echo ""

    # Get existing namespaces
    local namespaces
    read -ra namespaces <<< "$(get_infrastructure_namespaces)"

    if [[ ${#namespaces[@]} -eq 0 ]]; then
        log_warn "No infrastructure namespaces found"
        return 0
    fi

    local resume_errors=0

    # Restore each namespace
    for ns in "${namespaces[@]}"; do
        if ! restore_namespace "$ns"; then
            resume_errors=$((resume_errors + 1))
        fi
        echo ""
    done

    # Wait for pods to be ready
    log_info "Waiting for all pods to be ready..."
    echo ""

    for ns in "${namespaces[@]}"; do
        wait_for_pods "$ns" 180 || true
    done

    if [[ $resume_errors -gt 0 ]]; then
        log_error "Cluster resume completed with $resume_errors error(s)"
        return 1
    fi

    log_info "Cluster resumed: $CLUSTER_NAME"
}

# =============================================================================
# Status Command
# =============================================================================

print_namespace_status() {
    local namespace="$1"

    echo ""
    echo "=== $namespace ==="

    if ! kubectl get namespace "$namespace" &>/dev/null; then
        echo "  Namespace does not exist"
        return
    fi

    # Deployments
    local deploys
    deploys=$(kubectl get deployments -n "$namespace" -o json 2>/dev/null)

    if [[ -n "$deploys" && "$(echo "$deploys" | jq '.items | length')" != "0" ]]; then
        echo "  Deployments:"
        echo "$deploys" | jq -r '.items[] | "    \(.metadata.name): \(.status.readyReplicas // 0)/\(.spec.replicas) ready"'
    fi

    # StatefulSets
    local statefulsets
    statefulsets=$(kubectl get statefulsets -n "$namespace" -o json 2>/dev/null)

    if [[ -n "$statefulsets" && "$(echo "$statefulsets" | jq '.items | length')" != "0" ]]; then
        echo "  StatefulSets:"
        echo "$statefulsets" | jq -r '.items[] | "    \(.metadata.name): \(.status.readyReplicas // 0)/\(.spec.replicas) ready"'
    fi

    # Check for stored replica ConfigMap
    if kubectl get configmap "$CONFIGMAP_NAME" -n "$namespace" &>/dev/null; then
        echo -e "  ${YELLOW}[PAUSED]${NC} Original replicas stored in ConfigMap"
    fi
}

cmd_status() {
    echo "=== Cluster Status: $CLUSTER_NAME ==="
    date '+%Y-%m-%d %H:%M:%S'

    # Infrastructure namespaces
    local infra_namespaces=("$GITLAB_NAMESPACE" "$JENKINS_NAMESPACE" "$NEXUS_NAMESPACE" "$ARGOCD_NAMESPACE")

    for ns in "${infra_namespaces[@]}"; do
        print_namespace_status "$ns"
    done

    # Summary
    echo ""
    echo "=== Summary ==="

    local total_desired=0
    local total_ready=0
    local paused_namespaces=0

    for ns in "${infra_namespaces[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null; then
            local desired
            local ready
            desired=$(kubectl get deployments,statefulsets -n "$ns" -o json 2>/dev/null | \
                jq '[.items[].spec.replicas] | add // 0')
            ready=$(kubectl get deployments,statefulsets -n "$ns" -o json 2>/dev/null | \
                jq '[.items[].status.readyReplicas // 0] | add // 0')

            total_desired=$((total_desired + desired))
            total_ready=$((total_ready + ready))

            if kubectl get configmap "$CONFIGMAP_NAME" -n "$ns" &>/dev/null; then
                paused_namespaces=$((paused_namespaces + 1))
            fi
        fi
    done

    echo "  Total replicas: $total_ready/$total_desired ready"

    if [[ $paused_namespaces -gt 0 ]]; then
        echo -e "  ${YELLOW}Cluster is PAUSED${NC} ($paused_namespaces namespaces have stored replicas)"
    elif [[ $total_desired -eq 0 ]]; then
        echo -e "  ${YELLOW}Cluster appears to be scaled down${NC}"
    elif [[ $total_ready -eq $total_desired ]]; then
        echo -e "  ${GREEN}Cluster is HEALTHY${NC}"
    else
        echo -e "  ${RED}Cluster has issues${NC} (not all replicas ready)"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    local command="$1"

    # Handle help
    if [[ "$command" == "-h" || "$command" == "--help" || "$command" == "help" ]]; then
        usage
    fi

    # Check dependencies early
    check_dependencies

    # Require config file for all commands
    if [[ $# -lt 2 ]]; then
        log_error "Config file required"
        echo ""
        usage
    fi

    local config_file="$2"
    validate_config "$config_file"

    local exit_code=0

    case "$command" in
        pause)
            cmd_pause || exit_code=$?
            ;;
        resume)
            cmd_resume || exit_code=$?
            ;;
        status)
            cmd_status || exit_code=$?
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            usage
            ;;
    esac

    exit $exit_code
}

main "$@"
