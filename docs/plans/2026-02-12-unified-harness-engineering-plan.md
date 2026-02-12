# Unified Harness Engineering Plan

Supersedes:
- `2026-02-12-harness-engineering-application-plan.md` (deprecated)
- `2026-02-12-agent-alignment-plan.md` (deprecated)

Inspired by: [Harness engineering: leveraging Codex in an agent-first world](https://openai.com/index/harness-engineering/) (OpenAI, 2026-02-11)

## Goal

Make this repo legible, enforceable, and self-correcting for AI agents by:
1. Making the system of record explicit (knowledge map, doc index, freshness).
2. Documenting design intent so agents understand why, not just what.
3. Encoding conventions as mechanical checks with agent-readable remediation.
4. Establishing agent-driven quality loops for drift detection and belief maintenance.

## Non-goals

- Re-architecting the CI/CD topology or changing the Git remote strategy.
- Switching tooling (Jenkins/GitLab/ArgoCD/Nexus).
- Agent-to-agent review loops (PR volume doesn't justify this yet).
- Auto-merge of sweep fixes (start with human review, relax later).

## Assumptions

- CLAUDE.md is the Claude Code adapter (invariants inline + pointer to AGENTS.md).
- AGENTS.md (repo root) is the shared, agent-agnostic project map.
- Environment branches (dev/stage/prod) remain MR-only.
- The agentic surface is this repo on main (bootstrap, demo scripts, pipeline tooling, CUE schemas, Jenkinsfiles). Once subtree-synced to GitLab, target repos are non-agentic.

## Definition of Done

- There is a short, up-to-date entry map for agents (AGENTS.md) with doc index and freshness tracking.
- Design rationale is documented so agents understand why, not just what.
- Anti-patterns are concrete and negative-example-driven.
- Settled design decisions are recorded so agents don't relitigate them.
- Convention checks run mechanically and produce agent-readable remediation.
- CI enforces CUE validation and manifest checks in target repo pipelines.
- Agent sessions include a lightweight preamble scan.
- Agents can fetch system state with one command.
- A sweep protocol exists for periodic deep drift detection and belief maintenance.
- The sweep has been run at least once and validated.

## Key Concepts

### Core Beliefs
Short, opinionated statements of design rationale. They tell agents why decisions were made so agents don't "helpfully" refactor them away. Linked from AGENTS.md.

### Belief Lifecycle
Beliefs are living artifacts with three update triggers:
1. **Drift discovery** - Agent or human catches drift caused by a missing belief. Fix includes correcting the drift AND adding the missing belief.
2. **Intentional evolution** - A design decision genuinely changes. The old belief is updated with rationale for the change, not silently deleted.
3. **Graduation** - A belief that keeps getting violated is promoted from documentation into a mechanical check (documentation -> warning -> blocking).

### Agent-Driven Belief Discovery
Agents don't just enforce beliefs - they discover missing ones through three feedback loops:
1. **Convention consistency scanning** - Scan for pattern inconsistencies across the codebase itself. Output is a question ("is this intentional or drift?"), not a fix.
2. **Belief coverage analysis** - Read CORE_BELIEFS.md and check whether the codebase follows each belief. Output: coverage report with specific file references.
3. **Belief gap proposal** - When inconsistencies don't map to any existing belief, propose a candidate belief with evidence. Human approves or dismisses.

### Two Enforcement Surfaces
- **Agentic surface (main):** Enforced by session preamble scans and periodic sweep sessions. Covers shell scripts, Jenkinsfiles, CUE schemas, docs, pipeline tooling.
- **CI surface (target repos):** Enforced by Jenkins pipeline stages. Covers CUE validation and manifest checks in k8s-deployments and example-app after subtree sync.

---

## Recommended Order of Operations (Roadmap)

1. ~~Session 1: Knowledge Map + Plan Index~~ (DONE)
2. Session 2: Core Beliefs + Anti-Patterns
3. Session 3: Tiered Mechanical Enforcement
4. Session 4: Session Preamble Scan
5. Session 5: CI Enforcement (Target Repos)
6. Session 6: Agent-Oriented Status Summary
7. Session 7: Sweep Protocol + Doc Gardening
8. Session 8: First Real Sweep + Quality Scorecard

---

## Session 1: Knowledge Map + Plan Index (DONE)

Outcome: A small, discoverable map of docs and plans so agents can bootstrap fast.

Completed deliverables:
- `AGENTS.md` (repo root) as shared, agent-agnostic entry map.
- `CLAUDE.md` as thin Claude Code adapter (invariants inline + pointer to AGENTS.md).
- `docs/INDEX.md` listing canonical docs, purpose, ownership, and last-reviewed dates.
- `docs/plans/INDEX.md` listing plan documents and current status.
- Topic docs extracted from old CLAUDE.md: `docs/INVARIANTS.md`, `docs/ENVIRONMENT_SETUP.md`, `docs/OPERATIONS.md`, `docs/STATUS.md`, `docs/REPO_LAYOUT.md`.
- `README.md` updated to point to AGENTS.md.
- `docs/ARCHITECTURE.md` updated with project overview.

Multi-agent entry point architecture:
- `AGENTS.md` (root) is the shared map. All agent-specific files point here.
- `CLAUDE.md` is the Claude Code adapter: critical invariants inline + pointer to AGENTS.md.
- Future agent adapters (e.g., `.cursorrules`) follow the same pattern.

## Session 2: Core Beliefs + Anti-Patterns

Outcome: Design rationale, concrete anti-patterns, and initial decision records so agents understand intent across sessions.

Prerequisites: Session 1 complete.

Steps:
1. Create `docs/CORE_BELIEFS.md` (~50-80 lines).
2. Include a "How to update this document" section at the top describing the belief lifecycle protocol.
3. Capture initial beliefs with one-line rationale and date added. Initial set:
   - Why subtree publishing over submodules (unidirectional flow, clean GitLab history)
   - Why MR-only env branches (Jenkins manifest generation, auditability)
   - Why CUE over raw YAML (schema enforcement, typed defaults, layered overrides)
   - Why shell scripts over Python/Go (airgap portability, no runtime dependencies)
   - Why "boring" tech choices (composability, training-set representation, agent legibility)
   - Why CLI wrappers over direct API calls (single point of change, consistent auth)
   - Why monorepo with subtree sync (GitHub is source of truth, GitLab is execution)
4. Create `docs/ANTI_PATTERNS.md` organized by area:
   - Shell scripts (don't add abstraction layers, don't consolidate scripts serving different contexts, don't replace CLI wrappers with direct curl, don't inline credential access)
   - Jenkinsfiles (don't put logic in inline sh blocks over ~15 lines, don't hardcode URLs, don't skip GitLab commit status reporting, don't deploy from feature branches)
   - CUE schemas (don't reference env-specific values from app definitions, don't bypass the #App schema, don't remove defaults)
   - Operations (don't push directly to env branches, don't skip subtree sync order, don't hardcode namespace names)
5. Each anti-pattern includes a brief "wrong" and "right" example.
6. Create `docs/decisions/` directory and seed with 3-5 initial decision records:
   - `001-subtree-over-submodules.md`
   - `002-cue-over-kustomize.md`
   - `003-mr-only-env-branches.md`
   - `004-cli-wrappers.md`
7. Each decision record: ~20 lines, covering what was decided, why, and what was rejected.
8. Link CORE_BELIEFS.md, ANTI_PATTERNS.md, and decisions/ from AGENTS.md and docs/INDEX.md.

Validation:
- CORE_BELIEFS.md fits on two screens maximum.
- Each belief has a rationale that explains what would go wrong if violated.
- Anti-patterns include concrete code snippets showing wrong and right.
- Decision records answer "why not X?" for the most common alternatives an agent might propose.
- An agent reading AGENTS.md -> CORE_BELIEFS.md could explain why the project is structured this way.

## Session 3: Tiered Mechanical Enforcement

Outcome: Convention checks that catch drift before it spreads, with agent-readable remediation messages.

Prerequisites: Session 2 complete (beliefs exist to check against).

Note on script naming: `verify-invariants.sh` (from the deprecated plan) checks non-negotiable rules (MR-only env branches, subtree sync order, CUE validation). `verify-conventions.sh` checks style and pattern consistency (shellcheck, naming, file size, CLI wrapper usage). These are two scripts with different severity: invariants block, conventions warn. Session 3 creates the conventions script; the invariant checks from `docs/INVARIANTS.md` should be encoded in a separate `verify-invariants.sh` if not already present.

Steps:
1. Create `scripts/05-quality/verify-conventions.sh` with tiered checks:

   **Tier 1 - Structural rules (file/directory level):**
   - Script naming conventions (verb-noun.sh pattern)
   - Required elements in shell scripts (shebang, `set -euo pipefail`, standard source patterns)
   - File size limits (flag scripts over threshold as decomposition candidates)
   - Directory placement rules (operational scripts in 04-operations/, etc.)
   - No hardcoded namespace names outside config files

   **Tier 2 - Pattern consistency (content level):**
   - shellcheck on all `.sh` files
   - Logging patterns (use scripts/lib/logging.sh, not raw echo for user-facing output)
   - Credential access patterns (use scripts/lib/credentials.sh, not inline kubectl get secret)
   - CLI wrapper usage (use jenkins-cli.sh and gitlab-cli.sh, not raw curl)

   **Tier 3 - Jenkinsfile enforcement:**
   - No inline sh blocks over threshold line count
   - No hardcoded URLs (must use environment variables)
   - Credential access only via withCredentials blocks
   - Environment branch builds don't regenerate manifests
   - Feature branch builds don't deploy to live environments

   **Tier 4 - CUE schema enforcement:**
   - `cue vet ./...` passes
   - App CUE files don't reference env-specific values directly
   - Every field in #App has a default or is explicitly required

2. Each check failure message includes:
   - What was found (specific file and line)
   - What belief or convention it violates (reference to CORE_BELIEFS.md or ANTI_PATTERNS.md)
   - How to fix it (exact remediation command or pattern)

3. Support `--warn` mode (report only) and `--strict` mode (exit non-zero).
4. Support `--tier N` to run only specific tiers (useful for preamble scan in Session 4).

Validation:
- Script runs locally in under 60 seconds.
- Introduce a deliberate violation; confirm the output names the belief, the file, and the fix.
- `--warn` mode produces a report without failing.

## Session 4: Session Preamble Scan

Outcome: A lightweight check agents run at the start of every session, catching drift at the point of work.

Prerequisites: Session 3 complete.

Steps:
1. Create `scripts/05-quality/session-preamble.sh`.
2. Runs Tier 1 and Tier 2 checks from Session 3 in warn-only mode.
3. Output is short and grep-friendly: a summary line plus specific violations if any.
4. Completes in under 15 seconds.
5. Include a belief coverage quick-check: parse CORE_BELIEFS.md and spot-check the most recently added beliefs against the codebase.
6. Document in AGENTS.md as a recommended first step for agent sessions.

Validation:
- On a clean repo, output is a single "no issues found" line.
- On a repo with drift, output lists specific violations with file references.
- Does not block the agent from proceeding (warn-only).

## Session 5: CI Enforcement (Target Repos)

Outcome: CUE validation and manifest checks enforced in Jenkins pipelines for the target repos (non-agentic surface).

Prerequisites: Session 3 complete (Tier 4 checks exist and are tested).

Note: This session covers the CI surface (k8s-deployments, example-app pipelines after subtree sync). The agentic surface (main repo) is covered by Session 4 (preamble scan). These are complementary, not redundant.

Steps:
1. Add a Jenkins stage or job step in the k8s-deployments Jenkinsfile that runs CUE validation (`cue vet ./...`).
2. Ensure manifest validation (`scripts/04-operations/validate-manifests.sh`) runs as a blocking gate.
3. Update `docs/WORKFLOWS.md` with the new gate locations.

Validation:
- CI fails on deliberate CUE validation error (dry-run).
- CI logs show actionable guidance on failure.

## Session 6: Agent-Oriented Status Summary

Outcome: Agents can fetch the system state with one command.

Prerequisites: None (independent of other sessions, can run in parallel).

Steps:
1. Create `scripts/04-operations/status-summary.sh`.
2. Output: GitLab/Jenkins/Argo/Nexus availability, key job status, and active deployments.
3. Keep output short, grep-friendly, and stable.

Validation:
- Script runs without arguments.
- Output fits on one screen and has no empty/unstable lines.

## Session 7: Sweep Protocol + Doc Gardening

Outcome: A documented protocol for periodic deep drift detection and belief maintenance, including doc freshness checking.

Prerequisites: Session 2 (beliefs exist) + Session 3 (mechanical checks exist).

Steps:
1. Create `docs/sweep-protocol.md` describing the sweep workflow:
   a. Run full mechanical checks (all tiers, strict mode).
   b. Run convention consistency scan: identify patterns used in majority of files but not all, flag outliers.
   c. Run belief coverage analysis: for each belief in CORE_BELIEFS.md, verify the codebase complies.
   d. Run belief gap analysis: identify recurring patterns not covered by any existing belief, propose candidates.
   e. Run doc freshness check against docs/INDEX.md (flag docs past review window).
   f. Produce a sweep report with: violations found, fixes applied, belief updates proposed, stale docs identified.

2. Create `scripts/05-quality/sweep-scan.sh` to automate the mechanical portions:
   - Full tier 1-4 checks
   - Convention consistency detection (find patterns used in >80% of files, flag the rest)
   - Belief coverage check (parse CORE_BELIEFS.md, verify each against codebase)
   - Doc freshness check (parse docs/INDEX.md, flag entries past 90-day review window)
   - Output: structured report suitable for agent or human consumption

3. Define sweep triggers (change-driven, not calendar-driven):
   - After completing a roadmap session
   - After a batch of demo script updates
   - After significant structural changes
   - When a human suspects drift

4. Define the sweep output protocol:
   - Unambiguous violations: fix directly, commit with reference to belief
   - Ambiguous inconsistencies: document in sweep report, propose belief update for human review
   - Belief gap candidates: propose in sweep report with evidence (files, pattern counts)
   - Stale docs: list with last-reviewed date and owning area

Validation:
- An agent given only the sweep protocol doc can execute a sweep without additional guidance.
- Sweep report is actionable: each item has a clear next step.
- Sweep completes in under 5 minutes on the current repo.

## Session 8: First Real Sweep + Quality Scorecard

Outcome: Run the sweep protocol for real, validate it works, capture initial belief gaps, and produce the first quality scorecard.

Prerequisites: Session 7 complete.

Steps:
1. Run `scripts/05-quality/sweep-scan.sh` and review output.
2. Fix any unambiguous violations found.
3. Review belief gap candidates and decide which to add to CORE_BELIEFS.md.
4. Review convention inconsistencies and decide which to codify vs. leave as intentional variation.
5. Update CORE_BELIEFS.md, ANTI_PATTERNS.md, and mechanical checks based on findings.
6. Generate `docs/reports/quality-scorecard.md` from the sweep results:
   - Convention checks pass/fail by tier
   - Belief coverage summary
   - Doc freshness summary
   - CUE validation result
7. Link scorecard from docs/INDEX.md.
8. Document lessons learned: what the sweep caught, what it missed, what needs adjustment.
9. Update the sweep protocol if the first run revealed gaps in the process.

Validation:
- At least one new belief or anti-pattern was discovered and added.
- The sweep report accurately reflected the state of the codebase.
- The scorecard is generated in under 30 seconds locally.
- The protocol document was sufficient for the agent to execute without ambiguity.

---

## Risks and Mitigations

- **Risk:** Convention checks are too strict and block legitimate work.
  Mitigation: Start in warn-only mode (Session 4 preamble). Strict mode is opt-in. Sweep sessions review signal-to-noise ratio.

- **Risk:** Core beliefs become stale or contradictory.
  Mitigation: Belief lifecycle protocol requires rationale for changes. Sweep sessions include belief coverage analysis.

- **Risk:** Mechanical checks are too noisy and agents learn to ignore them.
  Mitigation: Start with high-confidence checks only. Each check must have clear remediation.

- **Risk:** Anti-patterns document grows unbounded.
  Mitigation: Anti-patterns that graduate to mechanical checks can be removed from the doc. Keep it under 100 lines.

- **Risk:** Sweep sessions become burdensome ritual.
  Mitigation: Sweeps are change-driven, not calendar-driven. Automate the mechanical portions. Keep the protocol lightweight.

- **Risk:** Belief gap proposals are low quality.
  Mitigation: Require evidence (file counts, pattern examples). Human always approves. Start conservative.

- **Risk:** Docs become another maintenance burden.
  Mitigation: Keep freshness rules simple. Automate checks. Sweep catches staleness.

---

## Provenance

This plan merges two earlier plans:
- **Harness engineering application plan** (Sessions 1-6): Focused on knowledge map, invariant checks, CI enforcement, status summary, doc gardening, and quality scorecard.
- **Agent alignment and drift prevention plan** (Sessions A1-A6): Focused on core beliefs, anti-patterns, tiered enforcement, session preamble, and sweep protocol.

Merging rationale:
- Session 2 (basic invariant checks) and A3 (tiered enforcement) targeted the same script. A3 is a superset; building the basic version first would be wasted work.
- Session 5 (doc gardening) and A5 (sweep protocol) overlapped. The sweep protocol includes doc gardening as one of its loops.
- Session 6 (quality scorecard) and A6 (first sweep) overlapped. The scorecard is a natural output of the sweep.
- Session 3 (CI enforcement) and A4 (session preamble) target different surfaces (CI vs agentic). Both are needed but were clarified as complementary.
- A1+A2 (beliefs and anti-patterns) needed to come before enforcement checks (can't check against beliefs that don't exist yet).

## Sources

- [Harness engineering: leveraging Codex in an agent-first world](https://openai.com/index/harness-engineering/) - OpenAI, 2026-02-11
- [Building an AI-Native Engineering Team](https://developers.openai.com/codex/guides/build-ai-native-engineering-team/) - OpenAI Developer Docs
- [Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md/) - OpenAI Developer Docs
