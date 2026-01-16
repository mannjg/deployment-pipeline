# Architecture

## Design Intent

This is a **reference implementation** for GitOps CI/CD in airgapped environments. While the demo uses a single example application, the architecture is designed for **multiple independent applications**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MULTI-APPLICATION ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  APPLICATION REPOS (many)          DEPLOYMENT REPO (one)       CLUSTERS     │
│  ┌──────────────┐                  ┌──────────────────┐       ┌─────────┐  │
│  │ example-app  │───┐              │ k8s-deployments  │       │   dev   │  │
│  │ user-service │───┼──MRs────────▶│  branch: dev     │──────▶│  stage  │  │
│  │ order-api    │───┘              │  branch: stage   │       │   prod  │  │
│  │ payment-svc  │                  │  branch: prod    │       └─────────┘  │
│  └──────────────┘                  └──────────────────┘                    │
│                                                                             │
│  Each app repo:                    Single source of truth:    ArgoCD:      │
│  - Source code                     - All app CUE configs      - Watches    │
│  - Tests                           - All env branches           branches   │
│  - deployment/app.cue              - All manifests            - Syncs      │
│  - App CI (Jenkins job)            - Promotion logic          - Health     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Principles

1. **App repos don't know about promotion** — App CI creates the initial MR to dev, then finishes. The k8s-deployments repo owns promotion logic.

2. **Environment branches are deployment state** — The dev/stage/prod branches in k8s-deployments represent what IS deployed (or will be after ArgoCD syncs).

3. **MRs are visibility gates** — Reviewers see CUE config diffs AND generated manifest diffs before any deployment.

4. **Event-driven promotion** — Merging to dev automatically creates a stage MR; merging to stage automatically creates a prod MR. No manual job triggers.

5. **ArgoCD owns health** — Jenkins doesn't wait for deployment health. ArgoCD syncs and reports health. Humans verify health before merging promotion MRs.

---

## System Components

### Infrastructure Layer

#### MicroK8s Cluster
- **Purpose**: Local Kubernetes cluster simulating production environment
- **Addons**:
  - `dns`: CoreDNS for service discovery
  - `storage`: Default storage class for PVCs
  - `ingress`: NGINX Ingress Controller for HTTP routing
  - `registry`: Local container registry (optional, using Nexus instead)
- **Networking**: Custom domain routing via /etc/hosts and Ingress

#### Ingress Configuration
```
*.local domains → NGINX Ingress Controller
  ├── gitlab.local → GitLab Service
  ├── jenkins.local → Jenkins Service
  ├── nexus.local → Nexus Service
  └── argocd.local → ArgoCD Server
```

### CI/CD Components

#### GitLab Community Edition
- **Purpose**: Source code management and webhook integration
- **Repositories**:
  - `example-app`: Sample Quarkus application
  - `k8s-deployments`: CUE-based deployment configurations
- **Features Used**:
  - Git repositories
  - Merge requests with diff views
  - Webhooks to Jenkins
  - Container registry
  - API for automation
- **Deployment**: Helm chart with persistent storage
- **Storage**: PVC for git data, registry, and PostgreSQL

#### Jenkins
- **Purpose**: Continuous Integration orchestration
- **Custom Agent Image**:
  ```dockerfile
  FROM jenkins/inbound-agent:latest
  - OpenJDK 21
  - Maven 3.9+
  - Docker CLI
  - CUE CLI (latest)
  ```
- **Plugins Required**:
  - Git
  - GitLab
  - Pipeline
  - Docker Pipeline
  - Credentials Binding
- **Jobs**:
  1. `example-app-ci`: Build, test, publish, create initial MR to k8s-deployments dev branch
  2. `promote-environment`: Create promotion MR (dev→stage or stage→prod) — called by auto-promote
  3. `k8s-deployments-auto-promote`: Webhook-triggered; detects which apps changed, triggers promote-environment
  4. `k8s-deployments-validation`: Validates CUE and manifests on k8s-deployments MRs
- **Deployment**: Helm chart with persistent storage for Jenkins home
- **Security**: Service account with Docker-in-Docker privileges

#### Nexus Repository OSS
- **Purpose**: Artifact and container registry
- **Repositories**:
  - `maven-releases`: Release artifacts
  - `maven-snapshots`: Snapshot artifacts
  - `docker-hosted`: Private Docker registry
- **Integration**:
  - Maven publishes JARs
  - Jib publishes container images
  - Jenkins authenticates with credentials
- **Deployment**: Helm chart with persistent storage
- **Storage**: Large PVC for artifact storage (50GB+)

#### ArgoCD
- **Purpose**: GitOps-based continuous delivery
- **Configuration**:
  - Three projects: dev, stage, prod
  - One Application per environment per app
  - Auto-sync enabled
  - Self-heal and prune enabled
- **Repository Access**: SSH key or token for GitLab
- **Applications**:
  ```yaml
  example-app-dev → k8s-deployments:dev → namespace:dev
  example-app-stage → k8s-deployments:stage → namespace:stage
  example-app-prod → k8s-deployments:prod → namespace:prod
  ```
- **Deployment**: Official manifests from ArgoCD project

### Application Layer

#### Example Quarkus Application
- **Framework**: Quarkus 3.28+
- **Build Tool**: Maven
- **Containerization**: Jib (no Docker build required)
- **Testing**:
  - Unit tests: Standard JUnit 5
  - Integration tests: @QuarkusTest with TestContainers
- **Deployment Config**: `deployment/app.cue` (co-located with source)

#### K8s Deployments Repository
- **Purpose**: Single source of truth for all Kubernetes configurations
- **Technology**: CUE language for type-safe configuration
- **Structure**:
  ```
  k8s-deployments/
  ├── cue.mod/                    # CUE module definition
  ├── k8s/                        # Base Kubernetes schemas
  │   ├── deployment.cue
  │   ├── service.cue
  │   └── configmap.cue
  ├── services/
  │   ├── base/
  │   │   ├── schema.cue          # #AppConfig schema
  │   │   └── defaults.cue        # Default values
  │   ├── core/
  │   │   └── app.cue             # #App template
  │   ├── apps/                   # Application definitions
  │   │   └── example-app.cue     # Merged from source repo
  │   └── resources/              # K8s resource templates
  │       ├── deployment.cue
  │       ├── service.cue
  │       └── configmap.cue
  ├── envs/                       # Environment configurations
  │   ├── dev.cue                 # Dev values (1 replica, dev-latest tag)
  │   ├── stage.cue               # Stage values (2 replicas, rc tag)
  │   └── prod.cue                # Prod values (3 replicas, version tag)
  └── manifests/                  # Rendered YAML (committed on env branches)
      ├── dev/
      ├── stage/
      └── prod/
  ```
- **Branches**:
  - `dev`: Automatically updated on every merge
  - `stage`: Updated via MR from dev
  - `prod`: Updated via MR from stage

## Data Flow

### Build and Deploy Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Developer Workflow                                            │
└──────────────────────────────────────────────────────────────────┘
  Developer commits to feature branch
         │
         ▼
  GitLab webhook → Jenkins
         │
         ▼
  Jenkins runs unit tests
         │
         ▼
  Developer creates MR
         │
         ▼
  GitLab webhook → Jenkins
         │
         ▼
  Jenkins runs integration tests (TestContainers)
         │
         ▼
  MR approved and merged
         │
         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 2. Build and Publish                                             │
└──────────────────────────────────────────────────────────────────┘
  Jenkins: Maven build
         │
         ├─> Publish JARs to Nexus (maven-releases)
         │
         └─> Jib builds image → Push to Nexus (docker-hosted)
         │
         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. Deployment Update                                             │
└──────────────────────────────────────────────────────────────────┘
  Jenkins: Checkout k8s-deployments (dev branch)
         │
         ├─> Extract deployment/app.cue from source repo
         │   └─> Copy to services/apps/example-app.cue
         │
         ├─> Update image tag in envs/dev.cue
         │
         ├─> Run generate-manifests.sh dev
         │   └─> CUE renders manifests/dev/*.yaml
         │
         └─> Commit and push to dev branch
         │
         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 4. GitOps Deployment                                             │
└──────────────────────────────────────────────────────────────────┘
  GitLab: dev branch updated
         │
         ▼
  ArgoCD: Detects change (polling or webhook)
         │
         ▼
  ArgoCD: Syncs example-app-dev Application
         │
         ▼
  Kubernetes: Deployment updated in dev namespace
         │
         ▼
  Application running with new version
         │
         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 5. Environment Promotion                                         │
└──────────────────────────────────────────────────────────────────┘
  Jenkins: Create promotion MR job triggered
         │
         ├─> Checkout k8s-deployments
         │
         ├─> Render manifests for both dev and stage
         │
         ├─> Generate full kubectl diff
         │
         ├─> Create GitLab MR: dev → stage (DRAFT)
         │   └─> Include manifest diff in description
         │
         └─> Repeat for stage → prod when stage updates
```

### Configuration Merge Flow

When application code includes CUE changes:

```
example-app/deployment/app.cue
         │
         │ (on merge to main)
         ▼
Jenkins: update-deployment job
         │
         ├─> Git clone k8s-deployments (dev branch)
         │
         ├─> Copy deployment/app.cue
         │   └─> To services/apps/example-app.cue
         │
         ├─> CUE validates against #AppConfig schema
         │
         ├─> Generate manifests for dev
         │   └─> CUE applies: base → app → env → resources
         │
         └─> Commit: "Update example-app to v1.2.3"
                      "- Updated image tag"
                      "- Merged CUE config from commit abc123"
```

## Security Model

### Credential Management

- **Jenkins Credentials**:
  - GitLab API token (for repository access and MR creation)
  - Nexus credentials (for publishing)
  - Git SSH key (for committing to k8s-deployments)
- **ArgoCD Credentials**:
  - GitLab repository access (SSH key or token)
- **Registry Authentication**:
  - Nexus Docker registry credentials
  - Stored in Kubernetes secrets
  - Mounted in Jenkins pods

### Network Security

- **Ingress**: TLS termination (can add Let's Encrypt)
- **Service Mesh**: Not implemented (future consideration)
- **Network Policies**: Not implemented (future consideration)

### RBAC

- **Jenkins Service Account**: Permissions for Docker operations
- **ArgoCD Service Account**: Permissions to deploy to all namespaces
- **Application Namespaces**: Isolated (dev, stage, prod)

## Scalability Considerations

### Current Limitations

- **Single cluster**: All environments in one MicroK8s instance
- **No HA**: Single replicas of GitLab, Jenkins, Nexus, ArgoCD
- **Local storage**: No distributed storage

### Production Adaptations

For production use, consider:

1. **Separate clusters** for dev/stage/prod
2. **HA deployments** of all infrastructure components
3. **External storage** (NFS, Ceph, cloud storage)
4. **External secrets** management (Vault, External Secrets Operator)
5. **Multi-region** deployments
6. **Load balancing** and auto-scaling
7. **Monitoring** (Prometheus, Grafana)
8. **Logging** (ELK/EFK stack)
9. **Backup** and disaster recovery

## Technology Choices

### Why CUE?

- **Type safety**: Catch configuration errors at build time
- **DRY principle**: Reuse and compose configurations
- **Validation**: Built-in schema validation
- **Templating**: More powerful than Helm/Kustomize
- **Programmable**: Logic in configuration

### Why GitOps (ArgoCD)?

- **Declarative**: Desired state in Git
- **Auditable**: All changes tracked in Git history
- **Rollback**: Easy to revert via Git
- **Security**: Cluster credentials not in CI system
- **Consistency**: Single source of truth

### Why Nexus?

- **All-in-one**: Maven + Docker + other formats
- **Open source**: Community edition free
- **Mature**: Well-established in enterprise
- **Proxy capability**: Can proxy Maven Central, Docker Hub

### Why Jenkins?

- **Flexibility**: Highly customizable pipelines
- **Ecosystem**: Massive plugin ecosystem
- **Docker support**: First-class Docker integration
- **Jenkinsfile**: Pipeline as code
- **Integration**: Works well with GitLab

## Performance Characteristics

### Build Times

- **Unit tests**: ~30 seconds
- **Integration tests**: ~2 minutes (TestContainers)
- **Maven build**: ~1 minute
- **Jib image build**: ~30 seconds
- **CUE rendering**: ~5 seconds
- **Total pipeline**: ~4-5 minutes

### Deployment Times

- **ArgoCD sync detection**: ~30 seconds (polling) or ~5 seconds (webhook)
- **Kubernetes rollout**: ~30 seconds (depends on readiness probes)
- **Total deployment**: ~1-2 minutes

### Storage Requirements

- **GitLab**: ~10GB (includes Git repos + registry)
- **Jenkins**: ~5GB (build artifacts, workspace)
- **Nexus**: ~50GB+ (grows with artifacts)
- **ArgoCD**: ~1GB
- **MicroK8s**: ~20GB (images, container storage)
- **Total**: ~90GB+ recommended

## Monitoring and Observability

### Current State

Basic monitoring via:
- Kubernetes metrics
- ArgoCD UI (application sync status)
- Jenkins build history
- GitLab pipeline status

### Future Additions

- **Prometheus**: Metrics collection
- **Grafana**: Dashboards
- **Loki**: Log aggregation
- **Jaeger**: Distributed tracing
- **Alertmanager**: Alert routing

## Disaster Recovery

### Backup Strategy

1. **Git repositories**: Already distributed, backed up by cloning
2. **Nexus artifacts**: PVC backup recommended
3. **Jenkins configuration**: PVC backup or Configuration as Code
4. **ArgoCD applications**: Stored in Git (k8s/argocd/)

### Recovery Procedures

1. Reinstall MicroK8s
2. Run setup scripts
3. Restore Nexus PVC from backup
4. Reconfigure ArgoCD applications
5. Trigger ArgoCD sync for all environments
