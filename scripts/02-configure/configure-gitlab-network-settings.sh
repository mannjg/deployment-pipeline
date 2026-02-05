#!/bin/bash
# Configure GitLab network settings for local/internal webhook URLs
#
# GitLab by default blocks webhooks to private/internal network addresses
# for security. This script enables local requests from webhooks so that
# GitLab can communicate with Jenkins running in the same cluster.
#
# Usage: ./scripts/02-configure/configure-gitlab-network-settings.sh [config-file]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load infrastructure config
source "$SCRIPT_DIR/../lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

# Output helpers
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Configuring GitLab Network Settings"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    log_info "Namespace: $GITLAB_NAMESPACE"
    echo ""

    log_step "Configuring GitLab application settings..."

    # Use Rails runner to update application settings:
    # 1. Allow local network requests for webhooks (Jenkins is in-cluster)
    # 2. Disable Auto DevOps (we use Jenkins for CI/CD, not GitLab CI)
    # 3. Disable shared runners (no GitLab Runners configured)
    local result
    if result=$(kubectl exec -n "$GITLAB_NAMESPACE" deployment/gitlab -- \
        gitlab-rails runner "
            settings = ApplicationSetting.current || ApplicationSetting.create_from_defaults
            settings.update!(
                allow_local_requests_from_web_hooks_and_services: true,
                allow_local_requests_from_system_hooks: true,
                auto_devops_enabled: false,
                shared_runners_enabled: false
            )
            puts 'allow_local_requests=true, auto_devops=false, shared_runners=false'
        " 2>&1); then
        log_pass "GitLab application settings configured"
        log_info "$result"
    else
        log_fail "Failed to update GitLab settings"
        log_info "$result"
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_pass "GitLab network settings configured"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
