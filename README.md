# Kubernetes Deployments

This repository contains Kubernetes manifests for all environments.

## Structure

- `manifests/dev/` - Development environment
- `manifests/stage/` - Staging environment  
- `manifests/prod/` - Production environment
- `cue-templates/` - CUE templates for generating manifests

## Branches

- `dev` - Auto-deployed to dev namespace by ArgoCD
- `stage` - Deployed to stage via MR from dev
- `prod` - Deployed to prod via MR from stage

## Workflow

1. Jenkins CI/CD builds application image
2. Jenkins updates `dev` branch with new image version
3. ArgoCD automatically syncs to dev namespace
4. Create MR: dev → stage for promotion
5. After testing, create MR: stage → prod
