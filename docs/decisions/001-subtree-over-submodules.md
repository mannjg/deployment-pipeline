# 001 - Subtree over submodules

Date: 2026-02-12
Status: Accepted

## Decision
Use Git subtrees to publish to GitLab execution repos instead of Git submodules.

## Rationale
Subtrees preserve a clean, linear GitLab history and keep GitHub as the single source of truth.
This avoids submodule pointer drift and reduces agent confusion about where changes land.

## Alternatives considered
- Submodules: rejected due to pointer drift, extra checkout steps, and frequent sync errors.
- Mirror-only GitLab: rejected because we need controlled promotion and Jenkins pipeline hooks.
