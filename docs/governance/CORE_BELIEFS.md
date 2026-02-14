# Core Beliefs

## How to update this document
- Trigger: update only when (1) drift is discovered, (2) intent changes, or (3) a belief graduates into a check.
- Process: fix the drift or record the decision first, then update the belief here.
- Rationale: each belief must say what would go wrong if violated.
- Dating: add or update the date on the same line as the belief.

## Beliefs
- Subtree publishing over submodules keeps GitLab history clean and preserves a one-way source of truth from GitHub. If violated, we get divergent histories and broken subtree syncs. (Added 2026-02-12)
- MR-only environment branches preserve auditability and Jenkins manifest generation order. If violated, we lose traceability and can deploy unreviewed changes. (Added 2026-02-12)
- CUE over raw YAML keeps rendered manifests visible in MRs before deployment, while enforcing schemas, typed defaults, and layered overrides. If violated, changes are harder to review pre-deploy and drift sneaks into manifests. (Added 2026-02-13)
- CLI wrappers over direct API calls keep common operations readable and maintainable (e.g., Jenkins crumbs, parameterized Git commands). Extend wrappers when new endpoints are needed; direct API calls are not allowed. If violated, API usage diverges and scripts become brittle. (Added 2026-02-13)
- Monorepo with subtree sync keeps GitHub as system of record and GitLab as execution mirror. If violated, execution repos drift and promotion flows break. (Added 2026-02-12)
- App definitions are environment-agnostic; env-specific overrides live in env.cue. If violated, app defaults leak environment assumptions and override behavior becomes unclear. (Added 2026-02-13)
- #App is the required app template to provide higher-level constructs (e.g., debug toggles) and consistent defaults. If violated, apps drift into ad-hoc config and templates lose leverage. (Added 2026-02-13)
- Defaults in #App must exist and be overridable via env.cue. If violated, environments lose safe baseline behavior or cannot override cleanly. (Added 2026-02-13)
- Namespace names must not be hardcoded; scripts and configs must accept external namespaces. If violated, the reference project cannot be deployed into unknown environments. (Added 2026-02-13)
- All script dependencies must be pre-installed in the Jenkins agent image and available on developer laptops; no runtime package installation (pip install, go get, etc.). If violated, scripts fail in airgapped environments or on machines without internet access. (Added 2026-02-13)
