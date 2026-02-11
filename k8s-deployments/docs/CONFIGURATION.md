# k8s-deployments Configuration Guide

This document describes the configuration requirements for the k8s-deployments subproject.

## Overview

k8s-deployments requires specific environment variables to be configured. These can be provided via:

1. **Jenkins ConfigMap** (`pipeline-config`) - For CI/CD pipelines
2. **Local environment file** (`config/local.env`) - For local development

**Design Principle**: No fallback defaults. Missing configuration causes immediate failure with actionable error messages.

## Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GITLAB_URL_INTERNAL` | GitLab API URL (cluster-internal) | `http://gitlab.gitlab.svc.cluster.local` |
| `GITLAB_GROUP` | GitLab group/namespace for repositories | `p2c` |
| `DEPLOYMENTS_REPO_URL` | Full Git URL for k8s-deployments repo | `http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git` |
| `CONTAINER_REGISTRY_EXTERNAL` | Container registry URL (what kubelet pulls from) | `docker.jmann.local` |
| `JENKINS_AGENT_IMAGE` | Custom Jenkins agent image | `localhost:30500/jenkins-agent-custom:latest` |

## Required Credentials (Jenkins)

| Credential ID | Type | Description |
|---------------|------|-------------|
| `gitlab-credentials` | Username/Password | GitLab username/password for git operations |
| `gitlab-token-secret` | Secret Text | GitLab API token for MR creation |
| `argocd-credentials` | Username/Password | ArgoCD admin credentials |

## Local Development Setup

1. Copy the example configuration:
   ```bash
   cp config/local.env.example config/local.env
   ```

2. Edit `config/local.env` with your values

3. Source before running scripts:
   ```bash
   source config/local.env
   ./scripts/generate-manifests.sh dev
   ```

## Jenkins ConfigMap Setup

Create or update the `pipeline-config` ConfigMap in Jenkins namespace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-config
  namespace: jenkins
data:
  GITLAB_URL_INTERNAL: "http://gitlab.gitlab.svc.cluster.local"
  GITLAB_GROUP: "p2c"
  DEPLOYMENTS_REPO_URL: "http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git"
  CONTAINER_REGISTRY_EXTERNAL: "docker.jmann.local"
  JENKINS_AGENT_IMAGE: "localhost:30500/jenkins-agent-custom:latest"
```

## Conventions

### Branch Naming

| Purpose | Pattern | Example |
|---------|---------|---------|
| Dev update MRs | `update-dev-{image_tag}` | `update-dev-1.0.0-abc123` |
| Promotion MRs | `promote-{target_env}-{image_tag}` | `promote-stage-1.0.0-abc123` |

### Manifest Paths

- **Pattern**: `manifests/{app_cue_name}/{app_cue_name}.yaml`
- **Example**: `manifests/exampleApp/exampleApp.yaml`
- **Note**: `app_cue_name` is the camelCase CUE key (e.g., `exampleApp` not `example-app`)

### APP_CUE_NAME Mapping

The root project's `validate-pipeline.sh` requires `APP_CUE_NAME` in `config/infra.env`:
- Maps repository name to CUE manifest name
- Example: `APP_REPO_NAME=example-app` → `APP_CUE_NAME=exampleApp`

## Pipeline Config

Declarative pipeline settings live in `config/pipeline.json` and define:
- Environment branch names and promotion sources
- Promotion branch prefix
- GitLab status context and project name
- Default app name for promotions

This file is read by Jenkinsfiles and scripts to avoid hardcoded rules.

## Troubleshooting

### "PREFLIGHT CHECK FAILED" Error

This error indicates missing configuration. The error message lists the missing variables.

**For Jenkins:**
1. Check that `pipeline-config` ConfigMap exists
2. Verify all required variables are present
3. Restart Jenkins to pick up ConfigMap changes

**For Local Development:**
1. Ensure `config/local.env` exists
2. Verify all required variables are set
3. Source the file: `source config/local.env`

### Variable Name Mapping

If migrating from older variable names:

| Old Name (deprecated) | New Name (use this) |
|-----------------------|---------------------|
| `GITLAB_INTERNAL_URL` | `GITLAB_URL_INTERNAL` |
| `DOCKER_REGISTRY` | `CONTAINER_REGISTRY_EXTERNAL` |
| `DEPLOYMENT_REPO` | `DEPLOYMENTS_REPO_URL` |

## Configuration Schema

The full configuration contract is defined in `config/configmap.schema.yaml`.

## Related Documentation

- [JENKINS_SETUP.md](JENKINS_SETUP.md) - Jenkins job configuration
- [Root CLAUDE.md](../../CLAUDE.md) - Project overview and conventions
