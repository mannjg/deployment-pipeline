#!/bin/bash
# Configure Nexus repositories and settings via REST API
#
# Creates Maven and Docker repositories needed for the CI/CD pipeline.
#
# Usage: ./scripts/02-configure/configure-nexus.sh [config-file]
#
# Example: ./scripts/02-configure/configure-nexus.sh config/clusters/alpha.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source infrastructure config
source "$PROJECT_ROOT/scripts/lib/infra.sh" "${1:-${CLUSTER_CONFIG:-}}"

NEXUS_URL="${NEXUS_URL_EXTERNAL:?NEXUS_URL_EXTERNAL not set}"
ADMIN_USER="admin"

# Output helpers
log_step()  { echo "[→] $*"; }
log_pass()  { echo "[✓] $*"; }
log_fail()  { echo "[✗] $*"; }
log_info()  { echo "    $*"; }
log_warn()  { echo "[!] $*"; }

# Get Nexus admin password from Kubernetes secret or default
get_admin_password() {
    local password

    # Try to get from K8s secret first
    password=$(kubectl get secret nexus-admin-credentials -n "$NEXUS_NAMESPACE" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || true

    if [[ -n "$password" ]]; then
        echo "$password"
        return 0
    fi

    # Try to read initial admin password from Nexus pod
    password=$(kubectl exec -n "$NEXUS_NAMESPACE" deploy/nexus -- \
        cat /nexus-data/admin.password 2>/dev/null) || true

    if [[ -n "$password" ]]; then
        echo "$password"
        return 0
    fi

    # Default password (after first setup)
    echo "admin123"
}

wait_for_nexus() {
    log_step "Waiting for Nexus to be ready..."

    for i in {1..60}; do
        if curl -sfk "${NEXUS_URL}/service/rest/v1/status" > /dev/null 2>&1; then
            log_pass "Nexus is ready"
            return 0
        fi
        sleep 5
    done

    log_fail "Nexus did not become ready in time"
    return 1
}

change_admin_password() {
    local current_pass="$1"
    local new_pass="admin123"

    log_step "Checking admin password..."

    # Test if current password works
    if curl -sfk -u "${ADMIN_USER}:${new_pass}" \
        "${NEXUS_URL}/service/rest/v1/status" > /dev/null 2>&1; then
        log_info "Password already set to standard"
        ADMIN_PASS="${new_pass}"
        return 0
    fi

    # Try to change password
    if curl -sfk -u "${ADMIN_USER}:${current_pass}" \
        -X PUT "${NEXUS_URL}/service/rest/v1/security/users/admin/change-password" \
        -H "Content-Type: text/plain" \
        -d "${new_pass}" 2>/dev/null; then
        log_pass "Admin password changed"
        ADMIN_PASS="${new_pass}"
    else
        # Password might already be changed, try the new password
        ADMIN_PASS="${new_pass}"
        log_info "Using standard password"
    fi
}

create_maven_repos() {
    log_step "Creating Maven repositories..."

    # Maven Releases
    if curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X POST "${NEXUS_URL}/service/rest/v1/repositories/maven/hosted" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "maven-releases",
            "online": true,
            "storage": {
                "blobStoreName": "default",
                "strictContentTypeValidation": true,
                "writePolicy": "ALLOW_ONCE"
            },
            "maven": {
                "versionPolicy": "RELEASE",
                "layoutPolicy": "STRICT"
            }
        }' 2>/dev/null; then
        log_info "Created maven-releases"
    else
        log_info "maven-releases may already exist"
    fi

    # Maven Snapshots
    if curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X POST "${NEXUS_URL}/service/rest/v1/repositories/maven/hosted" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "maven-snapshots",
            "online": true,
            "storage": {
                "blobStoreName": "default",
                "strictContentTypeValidation": true,
                "writePolicy": "ALLOW"
            },
            "maven": {
                "versionPolicy": "SNAPSHOT",
                "layoutPolicy": "STRICT"
            }
        }' 2>/dev/null; then
        log_info "Created maven-snapshots"
    else
        log_info "maven-snapshots may already exist"
    fi
}

create_docker_repo() {
    log_step "Creating Docker hosted repository..."

    if curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X POST "${NEXUS_URL}/service/rest/v1/repositories/docker/hosted" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "docker-hosted",
            "online": true,
            "storage": {
                "blobStoreName": "default",
                "strictContentTypeValidation": true,
                "writePolicy": "ALLOW"
            },
            "docker": {
                "v1Enabled": false,
                "forceBasicAuth": false,
                "httpPort": 5000
            }
        }' 2>/dev/null; then
        log_pass "Created docker-hosted on port 5000"
    else
        log_info "docker-hosted may already exist"
    fi
}

enable_docker_realm() {
    log_step "Enabling Docker Bearer Token Realm..."

    # Get current realms
    local current
    current=$(curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X GET "${NEXUS_URL}/service/rest/v1/security/realms/active" \
        -H "accept: application/json" 2>/dev/null)

    # Check if DockerToken is already enabled
    if echo "$current" | grep -q "DockerToken"; then
        log_info "Docker Bearer Token Realm already enabled"
        return 0
    fi

    # Enable DockerToken realm
    if curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X PUT "${NEXUS_URL}/service/rest/v1/security/realms/active" \
        -H "Content-Type: application/json" \
        -d '["NexusAuthenticatingRealm","NexusAuthorizingRealm","DockerToken"]' 2>/dev/null; then
        log_pass "Docker Bearer Token Realm enabled"
    else
        log_warn "Could not enable Docker realm"
    fi
}

enable_anonymous_access() {
    log_step "Enabling anonymous access for Docker pulls..."

    # Enable anonymous access (needed for unauthenticated docker pull)
    if curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X PUT "${NEXUS_URL}/service/rest/v1/security/anonymous" \
        -H "Content-Type: application/json" \
        -d '{
            "enabled": true,
            "userId": "anonymous",
            "realmName": "NexusAuthorizingRealm"
        }' 2>/dev/null; then
        log_pass "Anonymous access enabled"
    else
        log_info "Anonymous access may already be enabled"
    fi
}

create_jenkins_user() {
    log_step "Creating jenkins deployment user..."

    if curl -sfk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X POST "${NEXUS_URL}/service/rest/v1/security/users" \
        -H "Content-Type: application/json" \
        -d '{
            "userId": "jenkins",
            "firstName": "Jenkins",
            "lastName": "CI",
            "emailAddress": "jenkins@local",
            "password": "jenkins123",
            "status": "active",
            "roles": ["nx-admin"]
        }' 2>/dev/null; then
        log_pass "Created jenkins user"
    else
        log_info "jenkins user may already exist"
    fi
}

store_credentials_secret() {
    log_step "Storing Nexus credentials in Kubernetes secret..."

    # Create or update the secret
    if kubectl get secret nexus-admin-credentials -n "$NEXUS_NAMESPACE" &>/dev/null; then
        kubectl delete secret nexus-admin-credentials -n "$NEXUS_NAMESPACE"
    fi

    kubectl create secret generic nexus-admin-credentials \
        -n "$NEXUS_NAMESPACE" \
        --from-literal=username="$ADMIN_USER" \
        --from-literal=password="$ADMIN_PASS" \
        --from-literal=jenkins-username="jenkins" \
        --from-literal=jenkins-password="jenkins123"

    log_pass "Credentials stored in nexus-admin-credentials secret"
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "Nexus Repository Configuration"
    echo "=========================================="
    echo ""
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Nexus: $NEXUS_URL"
    echo ""

    wait_for_nexus

    # Get initial password
    local initial_pass
    initial_pass=$(get_admin_password)

    change_admin_password "$initial_pass"
    create_maven_repos
    create_docker_repo
    enable_docker_realm
    enable_anonymous_access
    create_jenkins_user
    store_credentials_secret

    echo ""
    echo "=========================================="
    log_pass "Nexus configuration complete"
    echo "=========================================="
    echo ""
    echo "Docker Registry: ${DOCKER_REGISTRY_HOST}:5000"
    echo "Maven Releases:  ${NEXUS_URL}/repository/maven-releases/"
    echo "Maven Snapshots: ${NEXUS_URL}/repository/maven-snapshots/"
    echo ""
}

main "$@"
