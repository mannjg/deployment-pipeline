# Jenkins Quality + v2 Migration Roadmap

Goal: Sequence the non-functional Jenkinsfile improvements and the v2 migration work into a single ordered roadmap with dependencies.

Guiding principle: Stabilize and de-duplicate first, then extract into scripts/CLI, then consolidate promotion and config, and finally tackle optional architectural shifts.

Testing approach: Treat smoke tests as a confidence gate, not a per-ticket ritual.
Smoke suite (recommended): UC-E1, UC-C1, UC-D2, UC-D3.
Micro-smoke (optional, faster): UC-E1 only.
Full regression: `scripts/demo/run-all-demos.sh`.
Reset strategy: `scripts/03-pipelines/reset-demo-state.sh` between smoke runs unless batching with `--no-reset`.

Smoke run procedure (alpha + beta):
1) Ensure alpha and beta are fully torn down:
   - `scripts/teardown.sh <alpha-config>`
   - `scripts/teardown.sh <beta-config>`
2) Bootstrap alpha: `scripts/bootstrap.sh <alpha-config>`
3) Run smoke (or micro-smoke) on alpha:
   - Micro-smoke: `scripts/demo/demo-uc-e1-app-deployment.sh`
   - Smoke: `scripts/demo/run-all-demos.sh <alpha-config> UC-E1 UC-C1 UC-D2 UC-D3`
4) Teardown alpha: `scripts/teardown.sh <alpha-config>`
5) Bootstrap beta: `scripts/bootstrap.sh <beta-config>`
6) Run smoke (or micro-smoke) on beta (same commands as alpha, with beta config)
7) Teardown beta: `scripts/teardown.sh <beta-config>`

When to run smoke:
- After a cluster of low-risk refactors (e.g., JENKINS-30/31/35 done together).
- After any change that touches promotion or MR logic (e.g., JENKINS-36, JENKINS-V2-03/04).
- At phase boundaries (end of Phase 1, Phase 2, Phase 3).

When smoke can be skipped:
- Pure structural refactors with no behavioral changes (helpers, logging, pod template centralization).

## Phase 1: Quality Baseline (lowest risk, highest leverage)

Ticket: JENKINS-30 - Local shared helpers per repo
Depends on: None
Outcome: Centralized helper functions within each repo (no cross-repo coupling).
Test: Run smoke suite once.

Ticket: JENKINS-31 - Centralize pod template YAML per repo
Depends on: None
Outcome: Single source of pod template YAML per repo.
Test: Run smoke suite once.

Ticket: JENKINS-33 - Standardize temp file creation and cleanup
Depends on: JENKINS-30 (shared helper location)
Outcome: Consistent temp file usage and cleanup patterns.
Test: Run smoke suite once.

Ticket: JENKINS-34 - Tighten credential scope
Depends on: None
Outcome: Reduced credential exposure; unchanged behavior.
Test: Run smoke suite once.

Ticket: JENKINS-35 - Consolidate constants and logging helpers
Depends on: JENKINS-30 (shared helper location)
Outcome: Cleaner Jenkinsfiles, consistent logging.
Test: Run smoke suite once.

Ticket: JENKINS-36 - Normalize GitLab API calls through a wrapper
Depends on: JENKINS-30 (shared helper location)
Outcome: Consistent GitLab API calls, shared error handling.
Test: Run smoke suite; ensure MR-creating demos pass (UC-C1 or UC-E1).

## Phase 2: Extraction + CLI Surface (bridge to v2)

Ticket: JENKINS-V2-01 - Extract Jenkinsfile shell blocks into scripts
Depends on: Phase 1 complete (especially JENKINS-30/35)
Outcome: Large `sh` blocks moved into scripts, stable callable interface.
Test: Run smoke suite once.

Ticket: JENKINS-V2-02 - Introduce repo-local pipeline CLI
Depends on: JENKINS-V2-01
Outcome: Jenkinsfiles call `scripts/pipeline <command>` instead of ad-hoc script fragments.
Test: Run smoke suite; spot-check a direct CLI invocation per repo.

Ticket: JENKINS-V2-03 - Consolidate GitLab API operations into a helper
Depends on: JENKINS-36 (if already done) or JENKINS-V2-01
Outcome: All GitLab API calls routed through a single helper.
Test: Run MR-creating demos (UC-C1 and UC-E1).

## Phase 3: Workflow Consolidation (v2 core)

Ticket: JENKINS-V2-04 - Centralize promotion flow behind a single command
Depends on: JENKINS-V2-01, JENKINS-V2-02
Outcome: Unified promotion logic used by both promotion pipelines.
Test: Run UC-E1 plus UC-D5 (skip env) to validate promotions.

Ticket: JENKINS-V2-05 - Introduce declarative pipeline config
Depends on: JENKINS-V2-02, JENKINS-V2-04
Outcome: Promotion rules, env mappings, and registry settings moved to config.
Test: Run smoke suite; verify config-driven behavior in logs.

## Phase 4: Optional Evolution (nice-to-have)

Ticket: JENKINS-V2-06 - Treat manifests as build artifacts
Depends on: JENKINS-V2-01, JENKINS-V2-04
Outcome: Manifests generated and stored externally; fewer CI feedback loops.
Test: Run UC-C3 or UC-C4 plus UC-E1.

Ticket: JENKINS-V2-07 - Add local run parity for pipeline commands
Depends on: JENKINS-V2-02
Outcome: `scripts/pipeline` runnable locally with documented inputs.
Test: Run `scripts/pipeline help` and one local command with mocked env; smoke suite optional.

## Notes
- If you want to merge phases, the safest combination is Phase 1 + Phase 2.
- Avoid doing Phase 4 before Phase 3; otherwise you risk breaking the promotion flow.
- Full regression recommended at the end of each phase: run `scripts/demo/run-all-demos.sh`.
