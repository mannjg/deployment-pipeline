# k8s-deployments Subproject Cleanup and Consistency Design

## Overview

This design addresses cleanup, quality improvement, and architecture validation for the `k8s-deployments` subproject, ensuring consistency with the overall project's GitOps design and the `example-app` subproject.

**Design Principle**: Root orchestrates, subprojects are self-contained. One-way dependency only (root → subprojects).

**Validation Approach**: No fallback defaults. Strict preflight checks with clear error messages pointing to documentation.

## Problem Statement

The `k8s-deployments` subproject has several issues:

1. **Cannot bootstrap standalone** - assumes ConfigMap exists without validation
2. **Inconsistent configuration** - hardcoded URLs, mismatched variable names
3. **Redundant/conflicting files** - `Jenkinsfile.k8s-manifest-generator` unclear purpose
4. **Duplicate scripts** - `create-gitlab-mr.sh` exists in both root and subproject
5. **Documentation drift** - paths reference `example/` instead of `p2c/`
6. **Implicit contracts undocumented** - branch naming, manifest paths

## Design

### 1. Configuration Contract Definition

Each subproject defines its required configuration in `config/configmap.schema.yaml`:

```yaml
# k8s-deployments/config/configmap.schema.yaml
# Configuration contract for k8s-deployments pipelines
#
# Jenkins pipelines require these variables in pipeline-config ConfigMap.
# Local scripts require these as environment variables or in config/local.env.

required:
  GITLAB_URL_INTERNAL:
    description: "GitLab API URL (cluster-internal)"
    example: "http://gitlab.gitlab.svc.cluster.local"

  GITLAB_GROUP:
    description: "GitLab group/namespace for repositories"
    example: "p2c"

  DEPLOYMENTS_REPO_URL:
    description: "Full Git URL for k8s-deployments repo"
    example: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"

  DOCKER_REGISTRY_EXTERNAL:
    description: "External Docker registry URL (what kubelet pulls from)"
    example: "docker.jmann.local"

  JENKINS_AGENT_IMAGE:
    description: "Custom Jenkins agent image with CUE, kubectl, etc."
    example: "localhost:30500/jenkins-agent-custom:latest"

credentials:
  gitlab-credentials:
    type: "usernamePassword"
    description: "GitLab username/password for git operations"

  gitlab-api-token-secret:
    type: "secretText"
    description: "GitLab API token for MR creation"

  argocd-credentials:
    type: "usernamePassword"
    description: "ArgoCD admin credentials"

conventions:
  branch_naming:
    dev_update: "update-dev-{image_tag}"
    promotion: "promote-{target_env}-{image_tag}"

  manifest_paths:
    pattern: "manifests/{app_cue_name}/{app_cue_name}.yaml"
    example: "manifests/exampleApp/exampleApp.yaml"
```

### 2. Preflight Check Pattern

All scripts and Jenkinsfiles follow this pattern:

**Shell scripts** (`scripts/lib/preflight.sh`):
```bash
#!/bin/bash
# Shared preflight check functions for k8s-deployments scripts

preflight_check_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    if [[ -z "$var_value" ]]; then
        echo "ERROR: $var_name not set"
        return 1
    fi
    return 0
}

preflight_check_required() {
    local failed=0
    local missing=()

    for var in "$@"; do
        if ! preflight_check_var "$var"; then
            missing+=("$var")
            failed=1
        fi
    done

    if [[ $failed -eq 1 ]]; then
        echo ""
        echo "Missing required configuration: ${missing[*]}"
        echo ""
        echo "For Jenkins: Configure pipeline-config ConfigMap"
        echo "For local:   Copy config/local.env.example to config/local.env and edit"
        echo "See:         docs/CONFIGURATION.md"
        exit 1
    fi
}
```

**Jenkinsfiles** (Preflight stage):
```groovy
stage('Preflight') {
    steps {
        script {
            def missing = []
            if (!System.getenv('GITLAB_URL_INTERNAL')) missing.add('GITLAB_URL_INTERNAL')
            if (!System.getenv('GITLAB_GROUP')) missing.add('GITLAB_GROUP')
            if (!System.getenv('DEPLOYMENTS_REPO_URL')) missing.add('DEPLOYMENTS_REPO_URL')
            if (!System.getenv('JENKINS_AGENT_IMAGE')) missing.add('JENKINS_AGENT_IMAGE')

            if (missing) {
                error """Missing required configuration: ${missing.join(', ')}

Configure pipeline-config ConfigMap with these variables.
See: k8s-deployments/docs/CONFIGURATION.md"""
            }
            echo "Preflight checks passed"
        }
    }
}
```

### 3. Variable Name Standardization

Standardize all Jenkinsfiles to use names matching `config/infra.env`:

| Old Name (Jenkinsfile) | New Name (matches infra.env) |
|------------------------|------------------------------|
| `GITLAB_INTERNAL_URL` | `GITLAB_URL_INTERNAL` |
| `DOCKER_REGISTRY` | `DOCKER_REGISTRY_EXTERNAL` |
| `DEPLOYMENT_REPO` | `DEPLOYMENTS_REPO_URL` |

### 4. Files to Remove/Archive

| File | Action | Reason |
|------|--------|--------|
| `k8s-deployments/jenkins/pipelines/Jenkinsfile.k8s-manifest-generator` | Archive to `docs/archives/` | Redundant; uses SCM polling which conflicts with event-driven MR workflow |
| `k8s-deployments/test-results/` | Remove | Empty directory with no defined purpose |
| `scripts/04-operations/create-gitlab-mr.sh` | Remove | Duplicate of `k8s-deployments/scripts/create-gitlab-mr.sh` |

### 5. Path Reference Fixes

All occurrences of `example/k8s-deployments` must be changed to `p2c/k8s-deployments`:

- `k8s-deployments/docs/JENKINS_SETUP.md`
- `k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile`

Hardcoded project IDs (e.g., `projects/2/`) should be replaced with path-based API calls using `GITLAB_GROUP` and repo name.

### 6. Directory Structure After Changes

```
k8s-deployments/
├── config/
│   ├── configmap.schema.yaml    # NEW: Configuration contract
│   ├── local.env.example        # NEW: Template for local development
│   └── README.md                # NEW: Points to CONFIGURATION.md
├── scripts/
│   ├── lib/
│   │   └── preflight.sh         # NEW: Shared preflight functions
│   ├── generate-manifests.sh    # MODIFIED: Add preflight checks
│   ├── create-gitlab-mr.sh      # MODIFIED: Add preflight checks
│   ├── update-app-image.sh      # MODIFIED: Add preflight checks
│   ├── validate-cue-config.sh   # MODIFIED: Fix envs/ vs env.cue handling
│   ├── validate-manifests.sh    # No change needed (already robust)
│   └── test-cue-integration.sh  # MODIFIED: Make generic (discover apps)
├── jenkins/
│   ├── k8s-deployments-validation.Jenkinsfile  # MODIFIED: Preflight, fix URLs
│   └── pipelines/
│       ├── Jenkinsfile.promote       # MODIFIED: Preflight, standardize vars
│       └── Jenkinsfile.auto-promote  # MODIFIED: Preflight, standardize vars
├── docs/
│   ├── JENKINS_SETUP.md         # MODIFIED: Fix paths, reference CONFIGURATION.md
│   └── CONFIGURATION.md         # NEW: Single source of configuration docs
└── Jenkinsfile                  # MODIFIED: Preflight, standardize vars
```

```
example-app/
├── config/
│   ├── configmap.schema.yaml    # NEW: Configuration contract
│   ├── local.env.example        # NEW: Template for local development
│   └── README.md                # NEW: Points to docs
├── Jenkinsfile                  # MODIFIED: Preflight, standardize vars
└── docs/
    └── CONFIGURATION.md         # NEW: Configuration documentation
```

### 7. Implicit Contracts Documentation

Document in `docs/CONFIGURATION.md` for each subproject:

**Branch Naming Conventions**:
- Dev update MRs: `update-dev-{image_tag}` (created by example-app CI)
- Promotion MRs: `promote-{target_env}-{image_tag}` (created by k8s-deployments)

**Manifest Path Convention**:
- Pattern: `manifests/{app_cue_name}/{app_cue_name}.yaml`
- Example: `manifests/exampleApp/exampleApp.yaml`
- The `app_cue_name` is the camelCase CUE key (e.g., `exampleApp` not `example-app`)

**APP_CUE_NAME Requirement**:
- `validate-pipeline.sh` requires `APP_CUE_NAME` in `config/infra.env`
- This maps the repo name to the CUE manifest name
- Example: `APP_REPO_NAME=example-app` → `APP_CUE_NAME=exampleApp`

## Implementation Order

### Phase 1: k8s-deployments Configuration Foundation
1. Create `k8s-deployments/config/` directory structure
2. Create `k8s-deployments/scripts/lib/preflight.sh`
3. Create `k8s-deployments/docs/CONFIGURATION.md`

### Phase 2: k8s-deployments Script Updates
4. Add preflight checks to all scripts
5. Fix `validate-cue-config.sh` for branch-per-env structure
6. Make `test-cue-integration.sh` generic

### Phase 3: k8s-deployments Jenkinsfile Updates
7. Fix `k8s-deployments-validation.Jenkinsfile` (paths, preflight, vars)
8. Fix `Jenkinsfile.promote` (preflight, vars)
9. Fix `Jenkinsfile.auto-promote` (preflight, vars)
10. Fix root `Jenkinsfile` (preflight, vars)
11. Archive `Jenkinsfile.k8s-manifest-generator`

### Phase 4: example-app Updates
12. Create `example-app/config/` directory structure
13. Update `example-app/Jenkinsfile` (preflight, vars)
14. Create `example-app/docs/CONFIGURATION.md`

### Phase 5: Root Cleanup
15. Remove `scripts/04-operations/create-gitlab-mr.sh`
16. Remove `k8s-deployments/test-results/`

### Phase 6: Documentation Updates
17. Update `k8s-deployments/docs/JENKINS_SETUP.md` (fix paths)
18. Update `k8s-deployments/README.md` (reference CONFIGURATION.md)

### Phase 7: Validation
19. Run `validate-pipeline.sh` to verify no regression

## Success Criteria

1. **Preflight failures are clear**: Missing config produces actionable error message
2. **No hardcoded URLs**: All URLs come from environment variables
3. **Consistent variable names**: Match `config/infra.env` naming
4. **No duplicate scripts**: Single source of truth for each function
5. **validate-pipeline.sh passes**: No regression in end-to-end flow

## Risk Mitigation

- **Breaking Jenkins jobs**: Jenkinsfile changes require ConfigMap to have new variable names. Update ConfigMap creation scripts to use standardized names.
- **validate-pipeline.sh assumptions**: Verified that script uses APIs only, doesn't call subproject scripts directly.
- **Branch naming changes**: None proposed; existing conventions documented only.

## Out of Scope

- Changes to `config/infra.env` structure (root owns this)
- Changes to `validate-pipeline.sh` logic
- New features for k8s-deployments
- Changes to CUE schemas or manifest generation logic
