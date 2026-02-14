# Agent Entry Map

This file is the canonical agent entry point and table of contents. It is intentionally short and designed for progressive disclosure.

## Start Here
- `README.md` - High-level repo overview and quick links.
- `docs/INDEX.md` - Canonical doc index and freshness.
- `docs/plans/INDEX.md` - Plan index and status.

## Core System Knowledge
- `docs/ARCHITECTURE.md` - System design and components.
- `docs/WORKFLOWS.md` - CI/CD workflows, triggers, and promotion.
- `docs/GIT_REMOTE_STRATEGY.md` - Subtree publishing and GitHub/GitLab flow.
- `docs/ENVIRONMENT_SETUP.md` - Environment branch setup and demo reset.
- `docs/STATUS.md` - Current state, limitations, and service access.
- `docs/REPO_LAYOUT.md` - Repository layout and navigation.
- `docs/decisions/` - Decision records explaining why choices were made.

## Agent Governance
- `docs/governance/INVARIANTS.md` - Critical rules that must be enforced.
- `docs/governance/CORE_BELIEFS.md` - Design rationale and belief lifecycle.
- `docs/governance/ANTI_PATTERNS.md` - Concrete negative examples with approved alternatives.
- `docs/governance/sweep-protocol.md` - Sweep workflow for drift detection and doc freshness.

## Operations
- `docs/OPERATIONS.md` - Jenkins/GitLab operations and common commands.
- `scripts/04-operations/` - Operational CLIs and helper scripts.
- `scripts/04-operations/status-summary.sh` - One-command system state snapshot for agents.
- `scripts/05-quality/` - Convention checks and agent preflight scans.
- `scripts/05-quality/session-preamble.sh` - Recommended start-of-session scan (Tier 1-2 warn-only + belief quick-check).
- `scripts/05-quality/sweep-scan.sh` - Sweep scan automation (mechanical checks, consistency, beliefs, doc freshness).
- `scripts/demo/` - End-to-end demo workflows.
