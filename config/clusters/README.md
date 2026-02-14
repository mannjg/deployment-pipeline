# Cluster Configuration Files

This directory contains per-cluster configuration files for the multi-cluster deployment pipeline.

## Overview

Each `.env` file defines a complete cluster configuration including:
- Cluster identity (name, protection status)
- Namespace names for all components
- External hostnames for services
- Storage class configuration
- Repository paths and URLs

## Deployment Topologies

The configs represent two distinct deployment topologies:

**Multi-namespace** (`alpha.env`): Each infrastructure component gets its own namespace (`gitlab-alpha`, `jenkins-alpha`, `nexus-alpha`, `argocd-alpha`), plus separate environment namespaces (`dev-alpha`, `stage-alpha`, `prod-alpha`). Best for isolation and resource visibility.

**Single-namespace** (`beta.env`): All infrastructure components share one namespace (`infra-beta`), with separate environment namespaces (`dev-beta`, `stage-beta`, `prod-beta`). Simpler to manage, fewer namespaces to create.

Both topologies use separate namespaces for dev/stage/prod environments.

## Usage

**All scripts require a config file as the first argument:**

```bash
# Bootstrap a cluster
./scripts/bootstrap.sh config/clusters/alpha.env

# Run demos
./scripts/demo/run-all-demos.sh config/clusters/alpha.env

# Reset demo state
./scripts/03-pipelines/reset-demo-state.sh config/clusters/alpha.env
```

## Available Configurations

| File | Cluster | Topology | Protected | Description |
|------|---------|----------|-----------|-------------|
| `alpha.env` | alpha | Multi-namespace | No | Separate namespace per component with `-alpha` suffix |
| `beta.env` | beta | Single-namespace | No | Shared `infra-beta` namespace for all infrastructure |

## Creating a New Cluster Configuration

1. Copy an existing config file:
   ```bash
   cp config/clusters/alpha.env config/clusters/mycluster.env
   ```

2. Edit the new file and update:
   - `CLUSTER_NAME` - unique identifier for your cluster
   - `PROTECTED` - set to "true" for production clusters
   - All namespace suffixes (e.g., `-mycluster`)
   - All external hostnames (e.g., `gitlab-mycluster.jmann.local`)

3. Add DNS entries for the new hostnames (or update /etc/hosts)

4. Run bootstrap:
   ```bash
   ./scripts/bootstrap.sh config/clusters/mycluster.env
   ```

## Configuration Variables

### Cluster Identity
| Variable | Description |
|----------|-------------|
| `CLUSTER_NAME` | Unique cluster identifier |
| `PROTECTED` | When "true", teardown scripts will refuse to run |

### Namespaces
| Variable | Description |
|----------|-------------|
| `GITLAB_NAMESPACE` | GitLab deployment namespace |
| `JENKINS_NAMESPACE` | Jenkins deployment namespace |
| `NEXUS_NAMESPACE` | Nexus repository namespace |
| `ARGOCD_NAMESPACE` | ArgoCD deployment namespace |
| `DEV_NAMESPACE` | Development environment namespace |
| `STAGE_NAMESPACE` | Staging environment namespace |
| `PROD_NAMESPACE` | Production environment namespace |

### External Hostnames
| Variable | Description |
|----------|-------------|
| `GITLAB_HOST_EXTERNAL` | GitLab ingress hostname |
| `JENKINS_HOST_EXTERNAL` | Jenkins ingress hostname |
| `MAVEN_REPO_HOST_EXTERNAL` | Maven repository ingress hostname |
| `ARGOCD_HOST_EXTERNAL` | ArgoCD ingress hostname |
| `CONTAINER_REGISTRY_HOST` | Container registry hostname |

### Storage
| Variable | Description |
|----------|-------------|
| `STORAGE_CLASS` | Kubernetes storage class for persistent volumes |

## Protection Flag

The `PROTECTED` variable prevents accidental teardown of important clusters:

```bash
PROTECTED="true"

# Teardown script behavior:
if [[ "$PROTECTED" == "true" ]]; then
    echo "ERROR: Cannot teardown protected cluster: $CLUSTER_NAME"
    exit 1
fi
```

Set `PROTECTED="true"` for any cluster that:
- Contains important data
- Serves production traffic
- Should not be accidentally destroyed
