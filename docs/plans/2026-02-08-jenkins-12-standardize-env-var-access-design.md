# JENKINS-12: Standardize Environment Variable Access Pattern

**Date:** 2026-02-08
**Ticket:** JENKINS-12 from `docs/plans/2026-02-07-jenkinsfile-review-tickets.md`
**Files:** `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

## Problem

Three different patterns for reading ConfigMap variables across Jenkinsfiles:

| Pattern | Where |
|---|---|
| `"${env.X ?: ''}"` | example-app & k8s-deployments `environment` blocks |
| `System.getenv('X')` | Jenkinsfile.promote `environment` block |
| `${env.JENKINS_AGENT_IMAGE}` (bare) | k8s-deployments pod YAML |

`System.getenv()` reads the JVM process environment at parse time; `env.` reads Jenkins' environment model at runtime. They can diverge. Bare `env.X` in string interpolation produces the string `"null"` when unset.

## Design

### Two Legitimate Patterns

**Pattern 1: `System.getenv()` with explicit null check — parse-time only**

Only for `JENKINS_AGENT_IMAGE`, which is interpolated into pod YAML before the `pipeline {}` block's `environment` is evaluated. All three Jenkinsfiles use (or will use) this pattern:

```groovy
// Agent image from system environment (set via ConfigMap envFrom)
// System.getenv() is required here because this runs at Groovy parse time,
// before the pipeline environment block is evaluated.
def agentImage = System.getenv('JENKINS_AGENT_IMAGE')
if (!agentImage) { error "JENKINS_AGENT_IMAGE not set - check pipeline-config ConfigMap" }
```

**Pattern 2: `"${env.X ?: ''}"` — all values in `environment {}` blocks**

Reads Jenkins' environment model at runtime. The `?: ''` prevents null interpolation.

### Changes Per File

**`example-app/Jenkinsfile` — No changes.**

Already uses both patterns correctly: `System.getenv()` with null check before `pipeline {}` (line 213-214), and `"${env.X ?: ''}"` in the `environment` block (lines 269-277).

**`k8s-deployments/Jenkinsfile` — 2 changes:**

1. Add `System.getenv()` + null check before `pipeline {}` block (before line 501), with comment explaining why `System.getenv()` is required.
2. Replace `${env.JENKINS_AGENT_IMAGE}` with `${agentImage}` in pod YAML (line 510).

The `environment` block (lines 554-564) already uses `"${env.X ?: ''}"` — no changes.

**`Jenkinsfile.promote` — 1 change (4 lines):**

Replace `System.getenv()` calls in `environment` block (lines 127-133) with `"${env.X ?: ''}"`:

```groovy
// Before:
GITLAB_URL = System.getenv('GITLAB_URL_INTERNAL')
GITLAB_GROUP = System.getenv('GITLAB_GROUP')
DEPLOYMENT_REPO = System.getenv('DEPLOYMENTS_REPO_URL')
DEPLOY_REGISTRY = System.getenv('DOCKER_REGISTRY_EXTERNAL')

// After:
GITLAB_URL = "${env.GITLAB_URL_INTERNAL ?: ''}"
GITLAB_GROUP = "${env.GITLAB_GROUP ?: ''}"
DEPLOYMENT_REPO = "${env.DEPLOYMENTS_REPO_URL ?: ''}"
DEPLOY_REGISTRY = "${env.DOCKER_REGISTRY_EXTERNAL ?: ''}"
```

The `System.getenv('JENKINS_AGENT_IMAGE')` before `pipeline {}` (line 65) is already correct — add explanatory comment if missing.

### Out of Scope

The `dind` sidecar arg `--insecure-registry=${env.DOCKER_REGISTRY_EXTERNAL?.replaceAll(...)}` in k8s-deployments pod YAML (line 532) has a similar parse-time issue but is not listed in the ticket. A null value there produces a no-op `--insecure-registry=null` flag — Docker ignores unknown registries rather than failing. Left for a separate fix if needed.

### Acceptance Criteria (from ticket)

- All `environment {}` blocks use the `"${env.X ?: ''}"` pattern
- `System.getenv()` is only used where required (agent image before pipeline block) and has a comment explaining why
- No bare `env.X` references in string interpolations where null would break
