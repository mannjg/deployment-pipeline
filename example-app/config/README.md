# Configuration

This directory contains configuration contracts for example-app CI/CD pipeline.

## Files

- `configmap.schema.yaml` - Configuration contract defining required variables
- `local.env.example` - Template for local reference

## Usage

### For Jenkins Pipelines

Configure the `pipeline-config` ConfigMap with variables from `configmap.schema.yaml`.

### For Local Development

Local Maven builds typically don't need these environment variables.
They're primarily used by the Jenkins pipeline for deployment operations.

## Documentation

See [docs/CONFIGURATION.md](../docs/CONFIGURATION.md) for full documentation.
