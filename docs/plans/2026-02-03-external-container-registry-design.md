# External Container Registry Design

**Date:** 2026-02-03
**Status:** Draft

## Problem Statement

Kubelet/containerd runs on nodes (outside the cluster) and cannot:
- Resolve cluster DNS (e.g., `nexus.nexus-alpha.svc.cluster.local`)
- Trust certificates issued by cert-manager inside the cluster

This means Jenkins agent pods cannot pull images from an in-cluster Nexus registry. This is a fundamental Kubernetes architecture limitation, not a configuration issue.

## Solution: External Container Registry

Use an externally trusted registry for Docker images instead of in-cluster Nexus:
- Registry is a **prerequisite** that exists before bootstrap runs
- Anonymous pull (kubelet works without credential distribution)
- Authenticated push (credentials stored in Jenkins only)
- Nexus continues handling Maven artifacts only

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    External Prerequisites                        │
├─────────────────────────────────────────────────────────────────┤
│  Kubernetes Cluster        Container Registry                    │
│  (microk8s / RKE2)         (dso namespace / org registry)        │
│                                                                  │
│  - kubectl configured      - Anonymous pull enabled              │
│  - containerd trusts       - Push requires credentials           │
│    registry hostname       - Credentials known to operator       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Bootstrap Creates                             │
├─────────────────────────────────────────────────────────────────┤
│  GitLab    Jenkins    Nexus (Maven only)    ArgoCD               │
│                         │                                        │
│            ┌────────────┘                                        │
│            ▼                                                     │
│  Jenkins Credentials:                                            │
│  - container-registry (for docker push)                          │
│  - maven-registry (for maven deploy)                             │
└─────────────────────────────────────────────────────────────────┘
```

## Cluster Configuration

New section in `config/clusters/<cluster>.env`:

```bash
# =============================================================================
# Container Registry (for Docker images)
# =============================================================================
# External registry trusted by kubelet/containerd
# Local dev: registry in "dso" namespace, exposed via ingress
# Production: your organization's existing registry

CONTAINER_REGISTRY_HOST="registry-dso.jmann.local"
CONTAINER_REGISTRY_PATH_PREFIX="docker-internal/p2c"    # Supports multiple segments
CONTAINER_REGISTRY_CREDENTIAL_ID="container-registry"
CONTAINER_REGISTRY_REQUIRES_AUTH_FOR_PUSH="true"
CONTAINER_REGISTRY_REQUIRES_AUTH_FOR_PULL="false"

# =============================================================================
# Maven Registry (for Maven artifacts)
# =============================================================================
MAVEN_REGISTRY_HOST="registry-dso.jmann.local"          # Can be same as container
MAVEN_REGISTRY_PATH_PREFIX="maven-releases"
MAVEN_REGISTRY_CREDENTIAL_ID="maven-registry"
MAVEN_REGISTRY_REQUIRES_AUTH_FOR_PUSH="true"
MAVEN_REGISTRY_REQUIRES_AUTH_FOR_PULL="false"
```

**Image reference construction:**
```
${CONTAINER_REGISTRY_HOST}/${CONTAINER_REGISTRY_PATH_PREFIX}/${APP_NAME}:${TAG}
# e.g., registry-dso.jmann.local/docker-internal/p2c/example-app:latest
# e.g., registry.yourorg.com/p2c/example-app:latest
```

**Converged case:** When container and Maven registries are the same backing repo, both `*_HOST` values are identical. Path prefixes differentiate Docker vs Maven artifacts.

## Bootstrap Credential Flow

Bootstrap prompts for registry credentials interactively and stores them in Jenkins only.

```
┌─────────────────────────────────────────────────────────────────┐
│  Bootstrap Flow                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. Load cluster env file (registry hosts, paths, credential IDs)│
│                                                                  │
│  2. Prompt operator:                                             │
│     "Container registry credentials for registry-dso.jmann.local"│
│     Username: ________                                           │
│     Password: ________ (hidden)                                  │
│                                                                  │
│  3. Prompt operator:                                             │
│     "Maven registry credentials for registry-dso.jmann.local"    │
│     (Skip if same host and credentials as container registry)    │
│                                                                  │
│  4. Create Jenkins credentials via API:                          │
│     - ID: container-registry (username/password)                 │
│     - ID: maven-registry (username/password)                     │
│                                                                  │
│  5. Credentials exist ONLY in Jenkins credential store           │
│     - Not in env files                                           │
│     - Not in git                                                 │
│     - Not in Kubernetes secrets                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Skip logic:** If `MAVEN_REGISTRY_HOST == CONTAINER_REGISTRY_HOST` and user confirms same credentials, reuse or create single credential.

## Pipeline Usage

Jenkinsfiles use credentials for push operations. Pull is anonymous.

**Docker push (example-app Jenkinsfile):**
```groovy
stage('Push Image') {
    steps {
        withCredentials([usernamePassword(
            credentialsId: env.CONTAINER_REGISTRY_CREDENTIAL_ID,
            usernameVariable: 'REGISTRY_USER',
            passwordVariable: 'REGISTRY_PASS'
        )]) {
            sh '''
                echo "$REGISTRY_PASS" | docker login -u "$REGISTRY_USER" --password-stdin ${CONTAINER_REGISTRY_HOST}
                docker push ${CONTAINER_REGISTRY_HOST}/${CONTAINER_REGISTRY_PATH_PREFIX}/${APP_NAME}:${TAG}
                docker logout ${CONTAINER_REGISTRY_HOST}
            '''
        }
    }
}
```

**Maven deploy (example-app Jenkinsfile):**
```groovy
stage('Maven Deploy') {
    steps {
        withCredentials([usernamePassword(
            credentialsId: env.MAVEN_REGISTRY_CREDENTIAL_ID,
            usernameVariable: 'MAVEN_USER',
            passwordVariable: 'MAVEN_PASS'
        )]) {
            sh './mvnw deploy -DaltDeploymentRepository=releases::${MAVEN_REGISTRY_URL}'
        }
    }
}
```

## Local Registry Setup (dso namespace)

For local microk8s development, deploy a Docker registry in the "dso" namespace that mimics production behavior.

**Components:**
```
dso namespace
├── registry (Deployment)
│   └── Docker Distribution (registry:2)
│       - Configured with htpasswd auth for push
│       - Anonymous pull enabled
├── registry (Service)
│   └── ClusterIP on port 5000
├── registry-ingress (Ingress)
│   └── registry-dso.jmann.local → registry:5000
└── registry-htpasswd (Secret)
    └── htpasswd file with push credentials
```

**Node-level setup (`install-microk8s.sh`):**
- Add `registry-dso.jmann.local` to `/etc/hosts`
- Configure containerd trust: `/var/snap/microk8s/current/args/certs.d/registry-dso.jmann.local/hosts.toml`

**This is NOT part of bootstrap** - it's a prerequisite like the cluster itself. Implemented as separate script: `setup-local-registry.sh`

## Seed Image Strategy

No seed image push during bootstrap. The deployment uses a placeholder that intentionally doesn't exist:

```cue
exampleApp: {
    image: "registry-dso.jmann.local/docker-internal/p2c/example-app"
    tag:   "does-not-exist"
}
```

**Flow:**
1. ArgoCD deploys, pods fail with ImagePullBackOff (expected)
2. First example-app build pushes real image, updates env.cue via MR
3. After merge, ArgoCD syncs, pods start successfully

The `does-not-exist` tag makes it explicit this is a placeholder, not a missing image.

## Change Summary

| Component | Changes |
|-----------|---------|
| `config/clusters/*.env` | Add `CONTAINER_REGISTRY_*` and `MAVEN_REGISTRY_*` vars, remove `DOCKER_REGISTRY_*` |
| `install-microk8s.sh` | Add containerd trust config, update /etc/hosts for registry hostname |
| `setup-local-registry.sh` | **New** - deploys registry:2 to dso namespace with htpasswd auth |
| `bootstrap.sh` | Prompt for registry credentials, create Jenkins credentials |
| `k8s/jenkins/pipeline-config.yaml` | Replace Nexus docker vars with container/maven registry vars |
| `k8s/nexus/` | Remove Docker connector config (Maven only) |
| `example-app/Jenkinsfile` | Use `CONTAINER_REGISTRY_*` vars, `withCredentials` for push |
| `k8s-deployments/env.cue` | Image paths use new registry hostname |

## Production vs Local

| Aspect | Local (microk8s) | Production (RKE2) |
|--------|------------------|-------------------|
| Registry | `registry-dso.jmann.local` in dso namespace | Org's existing registry |
| Trust | Configured in `install-microk8s.sh` | Pre-existing (registry already trusted) |
| Credentials | Created during local setup | Provided by operator at bootstrap |
| Auth model | htpasswd (push), anonymous (pull) | Org's auth system |
