
========================================
GitLab Configuration Guide
========================================

1. Login to GitLab:
   URL: http://gitlab.local
   Username: root
   Password: changeme123

2. Change Root Password:
   - Go to: http://gitlab.local/-/user_settings/password/edit
   - Set a new password

3. Create Personal Access Token:
   - Go to: http://gitlab.local/-/user_settings/personal_access_tokens
   - Name: jenkins-integration
   - Scopes: api, read_repository, write_repository
   - Click "Create personal access token"
   - SAVE THE TOKEN (you won't see it again!)

4. Create Projects:

   A. Project: example-app
      - Go to: http://gitlab.local/projects/new
      - Project name: example-app
      - Visibility: Private
      - Initialize with README: No
      - Click "Create project"

   B. Project: k8s-deployments
      - Go to: http://gitlab.local/projects/new
      - Project name: k8s-deployments
      - Visibility: Private
      - Initialize with README: No
      - Click "Create project"

5. Clone URLs (after creation):
   - example-app: http://gitlab.local/root/example-app.git
   - k8s-deployments: http://gitlab.local/root/k8s-deployments.git

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
├── schemas/               # Base schemas
├── templates/
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
