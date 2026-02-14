# Repository Layout

```
deployment-pipeline/
├── AGENTS.md              # Canonical agent entry point
├── example-app/           # Sample Quarkus app (synced to GitLab p2c/example-app)
├── k8s-deployments/       # CUE-based K8s configs (synced to GitLab p2c/k8s-deployments)
├── scripts/               # Helper scripts (NOT synced to GitLab)
│   ├── 01-infrastructure/ # Infra setup and cluster bootstrap
│   ├── 02-configure/      # Service configuration and credentials
│   ├── 03-pipelines/      # Pipeline and webhook setup
│   ├── 04-operations/     # Operational CLIs and helper scripts
│   ├── 05-quality/        # Convention/invariant checks and preflight scans
│   ├── demo/              # End-to-end demo workflows (use case tests)
│   └── lib/               # Shared script libraries
├── infrastructure/        # Infrastructure manifests
│   ├── argocd/            # ArgoCD install and ingress
│   ├── cert-manager/      # TLS certificate management
│   ├── gitlab/            # GitLab deployment
│   ├── jenkins/           # Jenkins Helm values and manifests
│   │   └── agent/         # Custom Jenkins agent (Dockerfile, build script, CA cert)
│   └── nexus/             # Nexus deployment
├── config/                # Centralized configuration
│   └── clusters/          # Per-cluster configs (alpha.env, beta.env)
├── docs/                  # Documentation
│   ├── ARCHITECTURE.md    # System design details
│   ├── ENVIRONMENT_SETUP.md  # Environment branch setup
│   ├── GIT_REMOTE_STRATEGY.md  # Full git workflow details
│   ├── INDEX.md           # Documentation index
│   ├── OPERATIONS.md      # Operational commands and debugging
│   ├── REPO_LAYOUT.md     # This file
│   ├── STATUS.md          # Current state and service access
│   ├── WORKFLOWS.md       # CI/CD workflow details
│   ├── governance/        # Agent governance (beliefs, invariants, anti-patterns, sweep)
│   └── archives/          # Historical docs (may be stale)
└── CLAUDE.md              # Claude adapter (points to AGENTS.md)
```
