# Quality Scorecard

Sweep run: 2026-02-13T15:04:12Z
Command: `scripts/05-quality/sweep-scan.sh`

## Summary
- Mechanical checks: FAILED (212 issues reported)
- Convention consistency outliers: 8
- Belief coverage: 1 failure
- Doc freshness: OK (no stale docs)
- CUE validation: no errors reported in sweep output

## Mechanical Checks (Tier 1-4)
- Tier 1 flagged missing `set -euo pipefail` in several scripts (notably in `k8s-deployments/scripts/` and `scripts/debug/`).
- Tier 1 flagged missing `SCRIPT_DIR`/`PROJECT_ROOT` bootstraps across multiple scripts in `scripts/`.
- Tier 1 flagged multiple scripts over 400 lines (demo scripts, `scripts/04-operations/gitlab-cli.sh`, `scripts/04-operations/validate-manifests.sh`, and others).
- Tier 1 flagged hardcoded namespaces in `scripts/teardown.sh`, `scripts/bootstrap.sh`, and `scripts/debug/*`.
- Tier 2 flagged direct API `curl` usage across several pipeline/configure scripts and debug helpers.
- Tier 3 reported no Jenkinsfile enforcement errors.
- Tier 4 reported no CUE schema enforcement errors.

## Convention Consistency
- `set -euo pipefail` usage: 69/77 (89%). Outliers: `k8s-deployments/scripts/validate-cue-config.sh`, `k8s-deployments/scripts/test-cue-integration.sh`, `scripts/debug/test-k8s-validation.sh`, `scripts/debug/check-gitlab-plugin.sh`, `scripts/cluster-ctl.sh`, `scripts/03-pipelines/setup-gitlab-repos.sh`, `scripts/03-pipelines/setup-manifest-generator-job.sh`, `scripts/03-pipelines/setup-k8s-deployments-validation-job.sh`.
- `SCRIPT_DIR` bootstrap usage: 59/77 (76%).
- `PROJECT_ROOT` bootstrap usage: 42/77 (54%).
- `logging.sh` source usage: 6/77

## Belief Coverage
- Failure: Namespace names must not be hardcoded. Sweep found hardcoded namespaces in `scripts/teardown.sh`, `scripts/bootstrap.sh`, and `scripts/debug/*`.
- All other beliefs passed in the sweep output.

## Belief Gaps
- Sweep output reports belief gap analysis as manual review required. No new belief was added in this run, but the sweep did lead to two new anti-patterns (`#!/usr/bin/env bash` shebangs and no runtime installs).

## Doc Freshness
- All indexed docs are within the review window (no stale docs reported).

## Lessons Learned
- What the sweep caught: missing `set -euo pipefail`, missing bootstrap patterns, hardcoded namespaces, oversized scripts, and direct API `curl` usage.
- What it missed or could not decide: belief gap candidates (manual review still required) and which large scripts should be split versus tolerated as exceptions.
- Where manual judgment was required: deciding whether to add new beliefs for script size/bootstrapping and whether to refactor direct API calls now or defer.
- Tooling improvement: refined the sweep consistency patterns for `SCRIPT_DIR`/`PROJECT_ROOT` to reduce false negatives.

## Remediation Backlog
- Quick wins (low risk): add `set -euo pipefail` where missing; replace hardcoded namespaces with config-driven variables.
- Medium effort: add consistent `SCRIPT_DIR`/`PROJECT_ROOT` bootstraps where missing; standardize logging helper usage.
- Larger refactors: split oversized scripts in `scripts/demo/`, `scripts/04-operations/`, and `k8s-deployments/scripts/`.
- Policy-driven cleanup: replace direct API `curl` usage with `scripts/04-operations/gitlab-cli.sh` or `scripts/04-operations/jenkins-cli.sh` extensions where needed.
