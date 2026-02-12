# Agent Alignment and Drift Prevention Plan

Follow-on to: `2026-02-12-harness-engineering-application-plan.md` (Sessions 1-6)

Inspired by: [Harness engineering: leveraging Codex in an agent-first world](https://openai.com/index/harness-engineering/) (OpenAI, 2026-02-11)

## Goal

Preserve design intent across agent sessions and prevent codebase drift by encoding beliefs, enforcing conventions mechanically, and establishing agent-driven quality loops.

## Non-goals

- CI-integrated enforcement (the agentic surface is main; target repos are non-agentic after subtree sync).
- Agent-to-agent review loops (PR volume doesn't justify this yet).
- Auto-merge of sweep fixes (start with human review, relax later).
- Re-architecting the CI/CD topology or changing tooling.

## Assumptions

- Sessions 1-6 from the harness-engineering application plan are complete or in progress.
- `docs/AGENTS.md`, `docs/INDEX.md`, and `scripts/05-quality/verify-invariants.sh` exist.
- CLAUDE.md remains the authoritative agent entry point.
- The agentic surface is this repo on main (bootstrap, demo scripts, pipeline tooling, CUE schemas, Jenkinsfiles). Once subtree-synced to GitLab, target repos are non-agentic.

## Definition of Done

- Design rationale is documented so agents understand why, not just what.
- Anti-patterns are concrete and negative-example-driven.
- Settled design decisions are recorded so agents don't relitigate them.
- Convention checks run mechanically and produce agent-readable remediation.
- Agent sessions include a lightweight preamble scan.
- A sweep protocol exists for periodic deep drift detection and belief maintenance.

## Key Concepts

### Core Beliefs
Short, opinionated statements of design rationale. They tell agents why decisions were made so agents don't "helpfully" refactor them away. Linked from AGENTS.md.

### Belief Lifecycle
Beliefs are living artifacts with three update triggers:
1. **Drift discovery** - Agent or human catches drift caused by a missing belief. Fix includes correcting the drift AND adding the missing belief.
2. **Intentional evolution** - A design decision genuinely changes. The old belief is updated with rationale for the change, not silently deleted.
3. **Graduation** - A belief that keeps getting violated is promoted from documentation into a mechanical check (documentation → warning → blocking).

### Agent-Driven Belief Discovery
Agents don't just enforce beliefs - they discover missing ones through three feedback loops:
1. **Convention consistency scanning** - Scan for pattern inconsistencies across the codebase itself. Output is a question ("is this intentional or drift?"), not a fix.
2. **Belief coverage analysis** - Read CORE_BELIEFS.md and check whether the codebase follows each belief. Output: coverage report with specific file references.
3. **Belief gap proposal** - When inconsistencies don't map to any existing belief, propose a candidate belief with evidence. Human approves or dismisses.

### Anti-Patterns
Concrete negative examples organized by area. Agents pattern-match well against "don't do this" with before/after. More effective than abstract rules.

---

## Recommended Order of Operations (Roadmap)

1. Session A1: Core Beliefs Document
2. Session A2: Anti-Patterns + Decision Records
3. Session A3: Tiered Mechanical Enforcement
4. Session A4: Session Preamble Scan
5. Session A5: Sweep Session Protocol
6. Session A6: First Real Sweep (Validation)

---

## Session A1: Core Beliefs Document

Outcome: A short, opinionated document capturing design rationale so agents understand intent across sessions.

Prerequisites: Session 1 (Knowledge Map) complete.

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
4. Link from `docs/AGENTS.md`.
5. Add entry to `docs/INDEX.md`.

Validation:
- Document fits on two screens maximum.
- Each belief has a rationale that explains what would go wrong if violated.
- An agent reading only AGENTS.md → CORE_BELIEFS.md could explain why the project is structured this way.

## Session A2: Anti-Patterns + Decision Records

Outcome: Concrete negative examples and a lightweight record of settled design decisions.

Prerequisites: A1 complete.

Steps:
1. Create `docs/ANTI_PATTERNS.md` organized by area:
   - Shell scripts (don't add abstraction layers, don't consolidate scripts serving different contexts, don't replace CLI wrappers with direct curl, don't inline credential access)
   - Jenkinsfiles (don't put logic in inline sh blocks over ~15 lines, don't hardcode URLs, don't skip GitLab commit status reporting, don't deploy from feature branches)
   - CUE schemas (don't reference env-specific values from app definitions, don't bypass the #App schema, don't remove defaults)
   - Operations (don't push directly to env branches, don't skip subtree sync order, don't hardcode namespace names)
2. Each anti-pattern includes a brief "wrong" and "right" example.
3. Create `docs/decisions/` directory.
4. Seed with 3-5 initial decision records for non-obvious design choices:
   - `001-subtree-over-submodules.md`
   - `002-cue-over-kustomize.md`
   - `003-mr-only-env-branches.md`
   - `004-cli-wrappers.md`
5. Each decision record: ~20 lines, covering what was decided, why, and what was rejected.
6. Link both from `docs/AGENTS.md` and add to `docs/INDEX.md`.

Validation:
- Anti-patterns include concrete code snippets showing wrong and right.
- Decision records answer "why not X?" for the most common alternatives an agent might propose.

## Session A3: Tiered Mechanical Enforcement

Outcome: Convention checks that catch drift before it spreads, with agent-readable remediation messages.

Prerequisites: Session 2-3 (verify-invariants.sh exists and is wired into workflow).

Steps:
1. Extend or complement `scripts/05-quality/verify-invariants.sh` with tiered checks:

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
   - `cue vet ./...` passes (already in verify-invariants.sh)
   - App CUE files don't reference env-specific values directly
   - Every field in #App has a default or is explicitly required

2. Each check failure message includes:
   - What was found (specific file and line)
   - What belief or convention it violates (reference to CORE_BELIEFS.md or ANTI_PATTERNS.md)
   - How to fix it (exact remediation command or pattern)

3. Support `--warn` mode (report only) and `--strict` mode (exit non-zero).

Validation:
- Script runs locally in under 60 seconds.
- Introduce a deliberate violation; confirm the output names the belief, the file, and the fix.
- `--warn` mode produces a report without failing.

## Session A4: Session Preamble Scan

Outcome: A lightweight check agents run at the start of every session, catching drift at the point of work.

Prerequisites: A3 complete.

Steps:
1. Create `scripts/05-quality/session-preamble.sh`.
2. Runs the Tier 1 and Tier 2 checks from A3 in warn-only mode.
3. Output is short and grep-friendly: a summary line plus specific violations if any.
4. Completes in under 15 seconds.
5. Document in CLAUDE.md that agents should run this at session start (or reference it from AGENTS.md as a recommended first step).
6. Include a belief coverage quick-check: parse CORE_BELIEFS.md and spot-check the most recently added beliefs against the codebase.

Validation:
- On a clean repo, output is a single "no issues found" line.
- On a repo with drift, output lists specific violations with file references.
- Does not block the agent from proceeding (warn-only).

## Session A5: Sweep Session Protocol

Outcome: A documented protocol for periodic deep drift detection and belief maintenance, designed to be run by an agent session.

Prerequisites: A1 + A3 complete.

Steps:
1. Create `docs/sweep-protocol.md` describing the sweep workflow:
   a. Run full mechanical checks (all tiers, strict mode).
   b. Run convention consistency scan: identify patterns used in majority of files but not all, flag outliers.
   c. Run belief coverage analysis: for each belief in CORE_BELIEFS.md, verify the codebase complies.
   d. Run belief gap analysis: identify recurring patterns not covered by any existing belief, propose candidates.
   e. Produce a sweep report with: violations found, fixes applied, belief updates proposed.

2. Create `scripts/05-quality/sweep-scan.sh` to automate the mechanical portions:
   - Full tier 1-4 checks
   - Convention consistency detection (find patterns used in >80% of files, flag the rest)
   - Belief coverage check (parse CORE_BELIEFS.md, verify each against codebase)
   - Output: structured report suitable for agent or human consumption

3. Define sweep triggers (not calendar-driven, change-driven):
   - After completing a roadmap session
   - After a batch of demo script updates
   - After significant structural changes
   - When a human suspects drift

4. Define the sweep output protocol:
   - Unambiguous violations: fix directly, commit with reference to belief
   - Ambiguous inconsistencies: document in sweep report, propose belief update for human review
   - Belief gap candidates: propose in sweep report with evidence (files, pattern counts)

Validation:
- An agent given only the sweep protocol doc can execute a sweep without additional guidance.
- Sweep report is actionable: each item has a clear next step.
- Sweep completes in under 5 minutes on the current repo.

## Session A6: First Real Sweep (Validation)

Outcome: Run the sweep protocol for real, validate it works, capture initial belief gaps.

Prerequisites: A5 complete.

Steps:
1. Run `scripts/05-quality/sweep-scan.sh` and review output.
2. Fix any unambiguous violations found.
3. Review belief gap candidates and decide which to add to CORE_BELIEFS.md.
4. Review convention inconsistencies and decide which to codify vs. leave as intentional variation.
5. Update CORE_BELIEFS.md, ANTI_PATTERNS.md, and mechanical checks based on findings.
6. Document lessons learned: what the sweep caught, what it missed, what needs adjustment.
7. Update the sweep protocol if the first run revealed gaps in the process.

Validation:
- At least one new belief or anti-pattern was discovered and added.
- The sweep report accurately reflected the state of the codebase.
- The protocol document was sufficient for the agent to execute without ambiguity.

---

## Risks and Mitigations

- **Risk:** Core beliefs become stale or contradictory.
  Mitigation: Belief lifecycle protocol requires rationale for changes. Sweep sessions include belief coverage analysis.

- **Risk:** Mechanical checks are too noisy and agents learn to ignore them.
  Mitigation: Start with high-confidence checks only. Each check must have clear remediation. Sweep sessions review check signal-to-noise ratio.

- **Risk:** Anti-patterns document grows unbounded.
  Mitigation: Anti-patterns that graduate to mechanical checks can be removed from the doc. Keep it under 100 lines.

- **Risk:** Sweep sessions become burdensome ritual.
  Mitigation: Sweeps are change-driven, not calendar-driven. Automate the mechanical portions. Keep the protocol lightweight.

- **Risk:** Belief gap proposals are low quality.
  Mitigation: Require evidence (file counts, pattern examples). Human always approves. Start conservative, expand as confidence grows.

---

## Relationship to Existing Plans

This plan builds on and extends the harness-engineering application plan:

| This Plan | Builds On |
|-----------|-----------|
| A1 (Core Beliefs) | Session 1 (Knowledge Map) - adds the "why" layer |
| A2 (Anti-Patterns) | Session 1 (Knowledge Map) - adds negative examples and decision records |
| A3 (Mechanical Enforcement) | Sessions 2-3 (Invariant Checks) - extends with tiered convention checks |
| A4 (Session Preamble) | Session 4 (Status Summary) - adds quality dimension to session start |
| A5-A6 (Sweep Protocol) | Sessions 5-6 (Doc Gardening + Scorecard) - adds belief maintenance loop |

## Sources

- [Harness engineering: leveraging Codex in an agent-first world](https://openai.com/index/harness-engineering/) - OpenAI, 2026-02-11
- [Building an AI-Native Engineering Team](https://developers.openai.com/codex/guides/build-ai-native-engineering-team/) - OpenAI Developer Docs
- [Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md/) - OpenAI Developer Docs
