# Deployment Pipeline

Local GitOps CI/CD pipeline demonstration using Jenkins, GitLab, ArgoCD, and Nexus on MicroK8s.

## Quick Start

**For AI agents:** Start with [AGENTS.md](AGENTS.md) - it contains the canonical entry point and table of contents. `CLAUDE.md` points there.

**For humans:** See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for system design and [docs/WORKFLOWS.md](docs/WORKFLOWS.md) for CI/CD processes.

## What's Here

- `example-app/` - Sample Quarkus application
- `k8s-deployments/` - CUE-based Kubernetes configurations
- `infrastructure/` - Infrastructure manifests (GitLab, Jenkins, Nexus, ArgoCD)
- `scripts/` - Setup and helper scripts
- `docs/` - Documentation

## Git Strategy

This repo uses monorepo-with-subtree-publishing. GitHub receives the complete repo; GitLab receives subtrees for CI/CD. See [docs/GIT_REMOTE_STRATEGY.md](docs/GIT_REMOTE_STRATEGY.md).
