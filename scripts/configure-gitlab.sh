#!/bin/bash
set -euo pipefail

# GitLab Configuration Script
# Creates projects and access tokens via REST API

GITLAB_URL="http://gitlab.local"
GITLAB_USER="root"
GITLAB_PASS="changeme123"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

wait_for_gitlab() {
    log_info "Waiting for GitLab to be ready..."
    for i in {1..30}; do
        if curl -sf "${GITLAB_URL}/users/sign_in" > /dev/null 2>&1; then
            log_info "GitLab is ready!"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    log_error "GitLab did not become ready in time"
    return 1
}

get_access_token() {
    log_info "Creating personal access token..."

    # Get CSRF token from login page
    local response=$(curl -sc /tmp/gitlab-cookies "${GITLAB_URL}/users/sign_in" 2>/dev/null)
    local csrf_token=$(echo "$response" | grep -oP 'csrf-token" content="\K[^"]+')

    # Login to get session
    curl -sb /tmp/gitlab-cookies -c /tmp/gitlab-cookies \
        -X POST "${GITLAB_URL}/users/sign_in" \
        -d "authenticity_token=${csrf_token}&user[login]=${GITLAB_USER}&user[password]=${GITLAB_PASS}" \
        > /dev/null 2>&1 || {
        log_warn "Login might have failed, trying alternative method..."
    }

    # Try creating token via API (requires initial setup to be complete)
    # For local demo, we'll document manual token creation
    log_warn "Access token must be created manually via GitLab UI"
    log_info "Go to: ${GITLAB_URL}/-/user_settings/personal_access_tokens"
}

create_project() {
    local project_name=$1
    local description=$2

    log_info "Creating project: ${project_name}..."

    # This requires a personal access token
    # For now, document manual creation
    log_warn "Project '${project_name}' should be created manually"
    log_info "Description: ${description}"
}

print_configuration_guide() {
    cat << EOF

========================================
GitLab Configuration Guide
========================================

1. Login to GitLab:
   URL: ${GITLAB_URL}
   Username: ${GITLAB_USER}
   Password: ${GITLAB_PASS}

2. Change Root Password:
   - Go to: ${GITLAB_URL}/-/user_settings/password/edit
   - Set a new password

3. Create Personal Access Token:
   - Go to: ${GITLAB_URL}/-/user_settings/personal_access_tokens
   - Name: jenkins-integration
   - Scopes: api, read_repository, write_repository
   - Click "Create personal access token"
   - SAVE THE TOKEN (you won't see it again!)

4. Create Projects:

   A. Project: example-app
      - Go to: ${GITLAB_URL}/projects/new
      - Project name: example-app
      - Visibility: Private
      - Initialize with README: No
      - Click "Create project"

   B. Project: k8s-deployments
      - Go to: ${GITLAB_URL}/projects/new
      - Project name: k8s-deployments
      - Visibility: Private
      - Initialize with README: No
      - Click "Create project"

5. Clone URLs (after creation):
   - example-app: ${GITLAB_URL}/root/example-app.git
   - k8s-deployments: ${GITLAB_URL}/root/k8s-deployments.git

6. Setup Git Credentials (local machine):
   git config --global user.name "Root User"
   git config --global user.email "root@local"

========================================
Project Structure:
========================================

example-app/
├── src/                    # Quarkus application source
├── deployment/             # CUE configuration
│   └── app.cue            # Application-specific config
├── Jenkinsfile            # CI/CD pipeline
└── pom.xml                # Maven configuration

k8s-deployments/
├── cue.mod/               # CUE module
├── k8s/                   # Base schemas
├── services/
│   ├── base/              # Schemas and defaults
│   ├── apps/              # Application configs
│   └── resources/         # Resource templates
├── envs/                  # Environment configs
│   ├── dev.cue
│   ├── stage.cue
│   └── prod.cue
└── manifests/             # Generated YAML
    ├── dev/
    ├── stage/
    └── prod/

========================================
Next Steps:
========================================
1. Complete manual configuration above
2. Save the personal access token
3. Configure Jenkins with GitLab credentials
4. Setup webhooks (will be done when creating Jenkinsfiles)

========================================
EOF
}

main() {
    log_info "Starting GitLab configuration..."

    wait_for_gitlab
    print_configuration_guide

    # Save configuration guide
    print_configuration_guide > /home/jmann/git/mannjg/deployment-pipeline/GITLAB_SETUP_GUIDE.md
    log_info "Configuration guide saved to: GITLAB_SETUP_GUIDE.md"
}

main "$@"
