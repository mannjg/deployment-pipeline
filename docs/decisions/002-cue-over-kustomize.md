# 002 - CUE over Kustomize

Date: 2026-02-12
Status: Accepted

## Decision
Use CUE for schema validation, defaults, and overlays instead of Kustomize.

## Rationale
CUE provides typed schemas, composable defaults, and enforceable constraints across environments.
Kustomize lacks strong typing and makes validation and drift detection harder.

## Alternatives considered
- Kustomize: rejected due to weaker schema guarantees and limited validation.
- Raw YAML with scripts: rejected due to high drift risk and manual guardrails.
