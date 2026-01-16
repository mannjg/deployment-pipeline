# Archived Files

This directory contains files that have been archived but preserved for reference.

## Jenkinsfile.k8s-manifest-generator

**Archived**: 2026-01-16
**Reason**: Redundant with current event-driven MR workflow

This Jenkinsfile used SCM polling to detect changes and generate manifests automatically.
The current architecture uses event-driven webhooks and MR-based workflows instead.

If you need to reference the SCM polling approach, this file shows how it was implemented.
