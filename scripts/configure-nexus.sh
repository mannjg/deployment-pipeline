#!/bin/bash
set -euo pipefail

# Nexus Configuration Script
# Configures repositories and settings via REST API

NEXUS_URL="http://nexus.local"
ADMIN_USER="admin"
ADMIN_PASS="3d9bd23d-997d-4fe4-ad3e-2244817bf093"  # Initial password
NEW_PASSWORD="${NEW_PASSWORD:-admin123}"  # Change this!

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_nexus() {
    log_info "Waiting for Nexus to be ready..."
    for i in {1..30}; do
        if curl -sf "${NEXUS_URL}/service/rest/v1/status" > /dev/null 2>&1; then
            log_info "Nexus is ready!"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    log_error "Nexus did not become ready in time"
    return 1
}

change_admin_password() {
    log_info "Changing admin password..."

    # Try with initial password
    response=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X PUT "${NEXUS_URL}/service/rest/v1/security/users/admin/change-password" \
        -H "Content-Type: text/plain" \
        -d "${NEW_PASSWORD}" 2>&1) || {
        log_warn "Password might already be changed. Trying with new password..."
        ADMIN_PASS="${NEW_PASSWORD}"
        return 0
    }

    ADMIN_PASS="${NEW_PASSWORD}"
    log_info "Admin password changed successfully"
}

create_maven_repos() {
    log_info "Creating Maven repositories..."

    # Maven Releases
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
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
        }' > /dev/null 2>&1 && log_info "Created maven-releases" || log_warn "maven-releases may already exist"

    # Maven Snapshots
    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
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
        }' > /dev/null 2>&1 && log_info "Created maven-snapshots" || log_warn "maven-snapshots may already exist"
}

create_docker_repo() {
    log_info "Creating Docker hosted repository..."

    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
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
                "forceBasicAuth": true,
                "httpPort": 5000
            }
        }' > /dev/null 2>&1 && log_info "Created docker-hosted on port 5000" || log_warn "docker-hosted may already exist"
}

enable_docker_realm() {
    log_info "Enabling Docker Bearer Token Realm..."

    # Get current realms
    current=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -X GET "${NEXUS_URL}/service/rest/v1/security/realms/active" \
        -H "accept: application/json")

    # Add DockerToken if not present
    if echo "$current" | grep -q "DockerToken"; then
        log_info "Docker Bearer Token Realm already enabled"
    else
        curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
            -X PUT "${NEXUS_URL}/service/rest/v1/security/realms/active" \
            -H "Content-Type: application/json" \
            -d '["NexusAuthenticatingRealm","NexusAuthorizingRealm","DockerToken"]' > /dev/null
        log_info "Docker Bearer Token Realm enabled"
    fi
}

create_jenkins_user() {
    log_info "Creating jenkins deployment user..."

    curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
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
        }' > /dev/null 2>&1 && log_info "Created jenkins user" || log_warn "jenkins user may already exist"
}

print_summary() {
    echo ""
    echo "========================================="
    log_info "Nexus Configuration Complete!"
    echo "========================================="
    echo ""
    echo "Nexus URL: ${NEXUS_URL}"
    echo ""
    echo "Admin Credentials:"
    echo "  Username: ${ADMIN_USER}"
    echo "  Password: ${ADMIN_PASS}"
    echo ""
    echo "Jenkins User:"
    echo "  Username: jenkins"
    echo "  Password: jenkins123"
    echo ""
    echo "Repositories Created:"
    echo "  - maven-releases (Maven releases)"
    echo "  - maven-snapshots (Maven snapshots)"
    echo "  - docker-hosted (Docker on port 5000)"
    echo ""
    echo "Docker Registry:"
    echo "  URL: nexus.local:5000"
    echo "  Login: docker login nexus.local:5000"
    echo "         Username: jenkins (or admin)"
    echo "         Password: jenkins123 (or ${ADMIN_PASS})"
    echo ""
    echo "Maven Settings:"
    echo "  Repository URL: ${NEXUS_URL}/repository/maven-releases/"
    echo "  Snapshots URL:  ${NEXUS_URL}/repository/maven-snapshots/"
    echo ""
}

main() {
    log_info "Starting Nexus configuration..."

    wait_for_nexus
    change_admin_password
    create_maven_repos
    create_docker_repo
    enable_docker_realm
    create_jenkins_user
    print_summary

    # Save credentials
    cat > /home/jmann/git/mannjg/deployment-pipeline/k8s/nexus/nexus-credentials.txt <<EOF
Nexus Admin: ${ADMIN_USER} / ${ADMIN_PASS}
Jenkins User: jenkins / jenkins123
Docker Registry: nexus.local:5000
EOF
    chmod 600 /home/jmann/git/mannjg/deployment-pipeline/k8s/nexus/nexus-credentials.txt
}

main "$@"
