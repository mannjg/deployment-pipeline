# Cluster Configuration Files

This directory contains per-cluster configuration files for the multi-cluster deployment pipeline.

## Overview

Each `.env` file defines a complete cluster configuration including:
- Cluster identity (name, protection status)
- Namespace names for all components
- External hostnames for services
- Storage class configuration
- Repository paths and URLs

## Usage

**All scripts require a config file as the first argument:**

```bash
# Example: Deploy infrastructure to the alpha cluster
./scripts/01-infrastructure/deploy-all.sh config/clusters/alpha.env

# Example: Run demo on the reference cluster
./scripts/05-demos/demo-uc-e1-app-deployment.sh config/clusters/reference.env

# Example: Reset demo state
./scripts/03-pipelines/reset-demo-state.sh config/clusters/alpha.env
```

## Available Configurations

| File | Cluster | Protected | Description |
|------|---------|-----------|-------------|
| `reference.env` | reference | Yes | Current production cluster - protected from teardown |
| `alpha.env` | alpha | No | Test cluster template with -alpha suffix naming |

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

4. Run infrastructure deployment:
   ```bash
   ./scripts/01-infrastructure/deploy-all.sh config/clusters/mycluster.env
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
| `NEXUS_HOST_EXTERNAL` | Nexus ingress hostname |
| `ARGOCD_HOST_EXTERNAL` | ArgoCD ingress hostname |
| `DOCKER_REGISTRY_HOST` | Docker registry hostname (via Nexus) |

### Storage
| Variable | Description |
|----------|-------------|
| `STORAGE_CLASS` | Kubernetes storage class for persistent volumes |

## Protection Flag

The `PROTECTED` variable prevents accidental teardown of important clusters:

```bash
# In reference.env
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

## Backwards Compatibility

The existing `config/infra.env` file remains as the legacy configuration and will be updated to source from the appropriate cluster config in a future update.
