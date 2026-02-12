# 003 - MR-only environment branches

Date: 2026-02-12
Status: Accepted

## Decision
Environment branches (dev, stage, prod) are updated via merge requests only.

## Rationale
MR-only flow preserves auditability, protects promotion order, and keeps Jenkins manifest generation deterministic.
Direct pushes would bypass review and create non-reproducible deploy history.

## Alternatives considered
- Direct pushes: rejected due to audit gaps and increased risk of accidental deploys.
- Bot-managed fast-forwards: rejected until policy and tooling are mature enough.
