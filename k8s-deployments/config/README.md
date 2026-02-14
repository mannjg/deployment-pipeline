# Configuration

This directory contains configuration contracts and templates for k8s-deployments.

## Files

- `configmap.contract.yaml` - Configuration contract defining required variables
- `local.env.example` - Template for local development

## Usage

### For Jenkins Pipelines

Configure the `pipeline-config` ConfigMap with variables from `configmap.contract.yaml`.

### For Local Development

```bash
cp config/local.env.example config/local.env
# Edit config/local.env with your values
source config/local.env
```

## Documentation

See [docs/CONFIGURATION.md](../docs/CONFIGURATION.md) for full configuration documentation.
