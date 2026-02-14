# Sweep Protocol

Purpose: Run periodic deep drift detection, belief maintenance, and doc freshness checks.

## When to run
- After completing a roadmap session
- After a batch of demo script updates
- After significant structural changes
- When a human suspects drift

## Sweep steps
1. Run the mechanical checks (all tiers, strict mode).
2. Run the convention consistency scan (patterns used by the majority, flag outliers).
3. Run belief coverage analysis (each belief in `docs/governance/CORE_BELIEFS.md` must be traceable to the codebase).
4. Run belief gap analysis (identify patterns without a matching belief; propose candidates).
5. Run doc freshness check against `docs/INDEX.md`.
6. Produce a sweep report with violations found, fixes applied, belief updates proposed, and stale docs.

## How to run
1. Execute the sweep scan script:
   `scripts/05-quality/sweep-scan.sh`
2. Save the output as the sweep report (example):
   `scripts/05-quality/sweep-scan.sh | tee sweep-report-$(date +%F).txt`
3. Review the report and follow the output protocol below.

## Output protocol
- Unambiguous violations: fix directly, commit with reference to the belief or anti-pattern.
- Ambiguous inconsistencies: document in the sweep report and propose a belief update for human review.
- Belief gap candidates: propose in the sweep report with evidence (files and pattern counts).
- Stale docs: list with last-reviewed date and owning area.

## Expected artifacts
- Sweep report (plain text) with:
  - Mechanical check status (Tier 1-4)
  - Convention consistency outliers
  - Belief coverage pass/fail
  - Belief gap candidates
  - Doc freshness status

## Notes
- The sweep is change-driven, not calendar-driven.
- Keep the report actionable: every item must include the next step.
- Belief coverage checks should minimize false positives; refine the checks when noisy results appear.
- Refining a check (to reduce noise or improve precision) counts as a sweep outcome and should be noted in the report.
