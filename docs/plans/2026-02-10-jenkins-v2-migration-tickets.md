# Jenkins v2 Migration Tickets

Goal: Migrate from current Jenkinsfile-heavy orchestration to a thin Jenkinsfile + repo-local pipeline CLI, without changing functional outcomes.

Priority: Must

Ticket: JENKINS-V2-01 - Extract Jenkinsfile shell blocks into scripts
Goal: Move large multi-purpose `sh` blocks into repo scripts and call them from Jenkinsfiles.
Reasoning: Establishes a stable CLI surface for future refactors while preserving behavior.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Acceptance criteria:
- Jenkinsfiles call scripts with the same inputs/outputs as current inline blocks.
- No behavioral changes in pipeline outcomes.

Ticket: JENKINS-V2-02 - Introduce repo-local pipeline CLI
Goal: Add `scripts/pipeline` (or equivalent) with subcommands mapping to current pipeline steps.
Reasoning: Creates a single entrypoint for CI/CD logic that can be versioned and tested.
Scope:
- Both repos (separately; do not create cross-repo runtime dependency).
Acceptance criteria:
- Jenkinsfiles invoke `scripts/pipeline <command>` rather than direct script fragments.
- Commands delegate to existing scripts without changing behavior.

Ticket: JENKINS-V2-03 - Consolidate GitLab API operations into a helper
Goal: Replace inline curl/jq GitLab API usage with a shared helper script.
Reasoning: Reduces duplication and standardizes error handling.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Acceptance criteria:
- All GitLab API operations go through a single helper in each repo.
- Log output and behavior remain equivalent.

Priority: Should

Ticket: JENKINS-V2-04 - Centralize promotion flow behind a single command
Goal: Implement a unified promotion command that handles branch creation, MR creation, and optional artifact promotion.
Reasoning: Reduces duplicated logic and clarifies promotion behavior.
Scope:
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Acceptance criteria:
- Both pipelines call the same promotion command with parameters.
- Behavior remains consistent with current flows.

Ticket: JENKINS-V2-05 - Introduce declarative pipeline config
Goal: Add a single config file (e.g., `pipeline.yaml`) for environment rules, promotion matrix, and registry settings.
Reasoning: Removes hardcoded branching logic from Groovy/shell.
Scope:
- Both repos (separately).
Acceptance criteria:
- Jenkinsfiles/scripts read config values instead of hardcoded rules.
- No behavior changes.

Priority: Nice-to-have

Ticket: JENKINS-V2-06 - Treat manifests as build artifacts
Goal: Generate manifests in CI and store as artifacts or in an artifact registry, instead of committing generated manifests back to feature branches.
Reasoning: Eliminates CI feedback loops and reduces repo churn.
Scope:
- `k8s-deployments/Jenkinsfile`
Acceptance criteria:
- Manifests are generated and stored externally.
- Environment updates reference stored artifacts, not committed manifests.
- Equivalent deployment behavior with ArgoCD.

Ticket: JENKINS-V2-07 - Add local run parity for pipeline commands
Goal: Ensure `scripts/pipeline` commands can be run locally with documented inputs.
Reasoning: Improves testability and developer feedback loop.
Scope:
- Both repos.
Acceptance criteria:
- `scripts/pipeline help` documents required env vars and usage.
- Local execution works with mocked or documented dependencies.
