# example-app Configuration Guide

This document describes the configuration requirements for the example-app CI/CD pipeline.

## Overview

The example-app Jenkins pipeline requires specific environment variables to be configured in the `pipeline-config` ConfigMap.

**Design Principle**: No fallback defaults. Missing configuration causes immediate failure with actionable error messages.

## Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GITLAB_URL_INTERNAL` | GitLab API URL (cluster-internal) | `http://gitlab.gitlab.svc.cluster.local` |
| `GITLAB_GROUP` | GitLab group/namespace for repositories | `p2c` |
| `DEPLOYMENTS_REPO_URL` | Full Git URL for k8s-deployments repo | `http://gitlab.gitlab.svc.cluster.local/p2c/k8s-deployments.git` |
| `CONTAINER_REGISTRY_EXTERNAL` | Container registry URL | `docker.jmann.local` |
| `JENKINS_AGENT_IMAGE` | Custom Jenkins agent image | `localhost:30500/jenkins-agent-custom:latest` |

## Required Credentials (Jenkins)

| Credential ID | Type | Description |
|---------------|------|-------------|
| `maven-repo-credentials` | Username/Password | Maven repository credentials for artifacts |
| `container-registry-credentials` | Username/Password | Container registry credentials for image push |
| `gitlab-credentials` | Username/Password | GitLab credentials for git operations |
| `gitlab-api-token-secret` | Secret Text | GitLab API token for MR creation |

## Pipeline Behavior

The example-app pipeline:
1. Builds the Quarkus application with Maven
2. Runs unit and integration tests
3. Publishes container image to registry
4. Publishes Maven artifact to Nexus
5. Creates MR to k8s-deployments dev branch

## Troubleshooting

### "GITLAB_URL_INTERNAL not set" Error

Ensure the `pipeline-config` ConfigMap contains `GITLAB_URL_INTERNAL`.

### Variable Name Mapping

If migrating from older variable names:

| Old Name (deprecated) | New Name (use this) |
|-----------------------|---------------------|
| `GITLAB_INTERNAL_URL` | `GITLAB_URL_INTERNAL` |
| `DOCKER_REGISTRY` | `CONTAINER_REGISTRY_EXTERNAL` |

## Related Documentation

- [k8s-deployments CONFIGURATION.md](../../k8s-deployments/docs/CONFIGURATION.md)
- [Root CLAUDE.md](../../CLAUDE.md)
