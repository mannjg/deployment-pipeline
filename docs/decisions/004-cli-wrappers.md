# 004 - CLI wrappers for external systems

Date: 2026-02-12
Status: Accepted

## Decision
Use `scripts/04-operations/*-cli.sh` wrappers instead of direct API calls.

## Rationale
Wrappers centralize auth, retries, and consistent error messages.
Direct API calls fragment behavior and leak credentials into ad-hoc scripts.

## Alternatives considered
- Direct curl per script: rejected due to duplicated auth logic and inconsistent handling.
- Language SDKs: rejected due to runtime dependencies and airgap constraints.
