# Jenkinsfile Quality Tickets (Post JENKINS-10..29)

Scope: Non-functional improvements only (code quality, maintainability, best practices). Target files include `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote`.

Priority: Must

Ticket: JENKINS-30 - Local shared helpers per repo
Goal: Remove duplicate Groovy helpers within each repo by centralizing in a local Jenkins shared library or `vars/` file scoped to that repo.
Reasoning: Highest drift risk. Same helper code exists in multiple Jenkinsfiles and can silently diverge.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Requirements:
- Do not introduce cross-repo runtime coupling. Each repo should have its own library copy.
- Preserve current behavior and logging.
Acceptance criteria:
- Duplicate helper functions removed from Jenkinsfiles and replaced by library calls.
- No functional changes; pipeline steps and outputs remain equivalent.
Notes:
- Suggested helpers to centralize: `withGitCredentials`, `validateRequiredEnvVars`, `reportGitLabStatus`, agent image parse-time guard.

Ticket: JENKINS-31 - Centralize pod template YAML per repo
Goal: Deduplicate Kubernetes pod template definitions in each repo.
Reasoning: Repeated YAML blocks already diverge; this is easy to drift and hard to maintain.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
Requirements:
- Do not share a single runtime library across repos.
- Reuse a local helper or a YAML file loaded within each repo.
Acceptance criteria:
- Pod template YAML lives in one place per repo.
- Jenkinsfiles reference the centralized template without behavioral changes.

Priority: Should

Ticket: JENKINS-32 - Extract large shell blocks into repo scripts
Goal: Move long multi-purpose `sh` blocks into `scripts/` for readability and testability.
Reasoning: Reduces Groovy quoting complexity and makes logic reusable.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Requirements:
- No changes in functional behavior.
- Script interfaces are stable, with clear inputs and outputs.
Acceptance criteria:
- Jenkinsfiles call scripts with the same parameters as before.
- Script logging mirrors current pipeline logs where relevant.

Ticket: JENKINS-33 - Standardize temp file creation and cleanup
Goal: Use a single helper for temp file creation in `WORKSPACE` and consistent cleanup.
Reasoning: Reduces ad-hoc patterns and prevents leftover files as new temp artifacts are added.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Requirements:
- Retain file locations in `WORKSPACE`.
- Cleanup should be deterministic and local to each repo.
Acceptance criteria:
- Temp file creation uses a shared helper or script.
- Cleanup is centralized and still runs in `post { always { ... } }`.

Ticket: JENKINS-34 - Tighten credential scope
Goal: Limit credentials exposure to the smallest practical scope using `withCredentials`.
Reasoning: Least-privilege hygiene and reduces accidental leakage in logs.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Requirements:
- Do not change credentials IDs or usage behavior.
- Avoid global `environment { ... = credentials(...) }` where possible.
Acceptance criteria:
- Credentials are only available in blocks that need them.
- No functional behavior changes.

Priority: Nice-to-have

Ticket: JENKINS-35 - Consolidate constants and logging helpers
Goal: Reduce repeated strings and log banners with simple constants or helper functions.
Reasoning: Improves readability and reduces small inconsistencies.
Scope:
- All Jenkinsfiles in scope
Acceptance criteria:
- Common strings are centralized.
- Log formatting remains consistent with current output.

Ticket: JENKINS-36 - Normalize GitLab API calls through a wrapper
Goal: Use a shared helper or script for GitLab API calls to standardize error handling and output.
Reasoning: Consistency and easier future updates, but not critical.
Scope:
- `example-app/Jenkinsfile`
- `k8s-deployments/Jenkinsfile`
- `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`
Acceptance criteria:
- GitLab API calls routed through a shared helper.
- Existing behavior and responses remain equivalent.
