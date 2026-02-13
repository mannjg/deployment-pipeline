# Core Beliefs

## How to update this document
- Trigger: update only when (1) drift is discovered, (2) intent changes, or (3) a belief graduates into a check.
- Process: fix the drift or record the decision first, then update the belief here.
- Rationale: each belief must say what would go wrong if violated.
- Dating: add or update the date on the same line as the belief.

## Beliefs
- Subtree publishing over submodules keeps GitLab history clean and preserves a one-way source of truth from GitHub. If violated, we get divergent histories and broken subtree syncs. (Added 2026-02-12)
- MR-only environment branches preserve auditability and Jenkins manifest generation order. If violated, we lose traceability and can deploy unreviewed changes. (Added 2026-02-12)
- CUE over raw YAML enforces schemas, typed defaults, and layered overrides. If violated, drift sneaks into manifests and validation becomes manual. (Added 2026-02-12)
- Shell scripts over Python/Go keep the tooling airgap-portable and dependency-free. If violated, demos and ops scripts fail in constrained environments. (Added 2026-02-12)
- Prefer boring tech choices so automation is composable and agent-legible. If violated, agents misread intent and maintenance becomes expert-only. (Added 2026-02-12)
- CLI wrappers over direct API calls centralize auth and error handling. Extend the wrappers when new endpoints are needed; only allow direct API calls with a documented exception. If violated, creds and API behavior diverge across scripts. (Added 2026-02-12)
- Monorepo with subtree sync keeps GitHub as system of record and GitLab as execution mirror. If violated, execution repos drift and promotion flows break. (Added 2026-02-12)
