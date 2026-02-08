# Jenkinsfile Review - Improvement Tickets

**Date:** 2026-02-07
**Scope:** All Jenkinsfiles, supporting scripts, Jenkins agent Dockerfile
**Source:** Comprehensive review covering security, correctness, operability, idempotency, failure modes, and race conditions.

Tickets are grouped for efficient single-session execution and ordered so prerequisites come first.

---

## JENKINS-11: Remove vestigial Docker socket mount from example-app

**Files:** `example-app/Jenkinsfile`

**Problem:** Lines 228-233 mount the host Docker socket (`/var/run/docker.sock`) into the agent pod. This grants root-equivalent access to the host. The pipeline builds images via Quarkus/Jib (which pushes directly to the registry without a Docker daemon), so the socket mount is unused.

The k8s-deployments pipeline correctly uses a DinD sidecar instead.

**Fix:** Remove the `volumeMounts` and `volumes` entries for `docker-sock` from the pod YAML template.

**Acceptance criteria:**
- Pod YAML has no `docker-sock` volume or volumeMount
- `mvn clean package -Dquarkus.container-image.build=true -Dquarkus.container-image.push=true` still succeeds

---

## JENKINS-21: Refactor createPromotionMR into smaller functions

**Files:** `k8s-deployments/Jenkinsfile`

**Depends on:** JENKINS-15, JENKINS-16, JENKINS-17 (functional fixes to createPromotionMR should land first)

**Problem:** `createPromotionMR` (lines 274-468) is a 195-line function performing 5+ distinct operations: check existing MRs, extract image tags, promote artifacts, create branch + update config + generate manifests, push + create MR. This is difficult to read, test, and debug.

The promote pipeline (`Jenkinsfile.promote`) does the same work but structured as discrete pipeline stages, which is much clearer.

**Fix:** Extract into functions matching the logical steps:
- `findExistingPromotionMR(targetEnv)` → returns MR IID or null
- `extractSourceImageTag(sourceEnv)` → returns image tag
- `promoteArtifacts(sourceEnv, targetEnv, gitHash)` → returns new image tag
- `createPromotionBranch(sourceEnv, targetEnv, imageTag)` → creates branch, commits, pushes
- `createPromotionMR` becomes an orchestrator calling these functions

**Acceptance criteria:**
- No function exceeds ~50 lines
- Each function has a clear single responsibility
- Existing behavior is preserved (validate with a promotion dry-run)

---

## JENKINS-22: Remove dead credential cleanup and container naming consistency

**Files:** `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Problem (cleanup):** `withGitCredentials` carefully unsets `credential.helper`, `user.name`, and `user.email` in a `finally` block. The `post.always` block in example-app (line 500) also runs `git config --global --unset credential.helper`. But agents are ephemeral Kubernetes pods destroyed after the build. The cleanup is dead code.

Additionally, the `--global` fallback path (used by default since no caller passes `repoDir`) writes credentials to the global gitconfig shared across all `sh` steps in the pod.

**Problem (naming):** example-app uses `container('maven')`, k8s-deployments uses `container('pipeline')`, Jenkinsfile.promote uses `container('maven')`. All use the same agent image. The name should be consistent — `pipeline` is more accurate since the container runs git, curl, kubectl, argocd, and cue beyond maven.

**Fix:**
- Remove the `finally` block from `withGitCredentials` (or replace with a comment explaining ephemeral pods make cleanup unnecessary)
- Remove the `git config --global --unset` lines from `post.always` blocks
- Remove `rm -f /tmp/maven-settings.xml` from cleanup (ephemeral pod)
- Standardize container name to `pipeline` across all three Jenkinsfiles
- Consider always passing `repoDir` to `withGitCredentials` to avoid global config pollution (even in ephemeral pods, it's better practice to demonstrate)

**Acceptance criteria:**
- No credential cleanup code in `finally` blocks or `post.always`
- All Jenkinsfiles use `container('pipeline')`
- Pod YAML container name matches

---

## JENKINS-23: Eliminate ENV_BRANCHES duplication

**Files:** `k8s-deployments/Jenkinsfile`

**Problem:** `ENV_BRANCHES` is defined twice:
- `@Field static final List<String> ENV_BRANCHES = ['dev', 'stage', 'prod']` (line 5) — Groovy list
- `ENV_BRANCHES = 'dev,stage,prod'` (line 538) — pipeline environment variable (comma-separated string)

The `when` expression on line 831 uses `env.PROMOTE_BRANCHES.split(',')` to work with the string version. Meanwhile, Groovy code uses the `@Field` list. Same data, two representations.

**Fix:** Remove the `ENV_BRANCHES` pipeline environment variable. Add `PROMOTE_BRANCHES` as a `@Field` list:
```groovy
@Field static final List<String> PROMOTE_BRANCHES = ['dev', 'stage']
```
Update the `when` expression on line 831 to use the `@Field` constant directly:
```groovy
env.BRANCH_NAME in PROMOTE_BRANCHES
```

**Acceptance criteria:**
- `ENV_BRANCHES` is defined once (as `@Field`)
- `PROMOTE_BRANCHES` is defined as `@Field` (not pipeline env var)
- No `.split(',')` calls to convert strings to lists

---

## JENKINS-24: Pin Dockerfile base image and kubectl version

**Files:** `k8s/jenkins/agent/Dockerfile.agent`

**Problem:**
- Line 19: `FROM jenkins/inbound-agent:latest-jdk21` — floating tag means rebuilds produce different images
- Line 84: kubectl fetches `stable.txt` at build time — same Dockerfile produces different kubectl versions depending on build date

All other tools (Maven, CUE, ArgoCD, yq) are properly pinned.

**Fix:**
- Pin the base image to a specific version tag (e.g., `jenkins/inbound-agent:3261.v9c670a_4748a_9-1-jdk21`)
- Pin kubectl with an `ARG KUBECTL_VERSION=v1.31.4` matching the pattern used by CUE, ArgoCD, and yq
- Add a comment with the date pinned and how to check for updates

**Acceptance criteria:**
- No floating tags or dynamic version resolution in Dockerfile
- All tool versions are explicit `ARG`s or pinned in the `FROM` line
- Rebuilding the Dockerfile on different dates produces the same image (assuming base image tag is immutable)

---

## JENKINS-25: Replace grep-based JSON parsing with jq

**Files:** `k8s-deployments/scripts/create-gitlab-mr.sh`, `k8s-deployments/Jenkinsfile` (`createPromotionMR`)

**Problem:** JSON responses are parsed with `grep -o '"iid":[0-9]*' | cut -d':' -f2` (create-gitlab-mr.sh lines 88-89) and similar patterns. The agent image includes `jq`. Using grep for JSON is fragile (breaks on whitespace variations, nested objects, or field ordering changes).

**Fix:** Replace all grep/sed/cut JSON parsing with `jq`:
```bash
# Before
MR_IID=$(echo "$RESPONSE_BODY" | grep -o '"iid":[0-9]*' | head -1 | cut -d':' -f2)
MR_WEB_URL=$(echo "$RESPONSE_BODY" | grep -o '"web_url":"[^"]*"' | head -1 | cut -d'"' -f4)

# After
MR_IID=$(echo "$RESPONSE_BODY" | jq -r '.iid')
MR_WEB_URL=$(echo "$RESPONSE_BODY" | jq -r '.web_url')
```

Also replace `escape_json` (create-gitlab-mr.sh lines 60-63) with `jq -Rs '.'` which handles all control characters correctly.

**Acceptance criteria:**
- No `grep -o` on JSON responses in any script or Jenkinsfile
- `escape_json` function is replaced with `jq -Rs`
- MR descriptions containing tabs, carriage returns, or unicode don't break JSON payloads

---

## JENKINS-26: Handle Maven release artifact duplicate on re-run

**Files:** `example-app/Jenkinsfile`

**Problem:** In Build & Publish (lines 394-406), `mvn deploy` to `maven-releases` fails if a non-SNAPSHOT artifact with the same version already exists (Nexus rejects duplicates). The Docker image push via Jib is idempotent (same tag overwrites), but Maven deploy is not. Re-running a successful build fails at Maven deploy.

This also means the image is pushed before Maven deploy — if Maven fails, the image exists in the registry but the artifact doesn't exist in Nexus. The states are diverged.

**Fix (choose one):**
1. **Reorder:** Deploy Maven artifact before Docker image push. Maven is cheaper to retry and has no external side effects until committed.
2. **Check-before-deploy:** Query Nexus for existing artifact before deploying. Skip deploy if it exists with matching checksum.
3. **Allow redeploy:** Configure the Nexus `maven-releases` repo to allow redeployment (simplest, but weakens release immutability guarantees).

**Recommendation:** Option 1 (reorder) — simplest change, no Nexus config required, and failing early on the cheaper operation is better practice.

**Acceptance criteria:**
- Re-running a build that previously succeeded does not fail
- On partial failure, no state divergence between Nexus and Docker registry

---

## JENKINS-27: Close superseded MRs on new build

**Files:** `example-app/Jenkinsfile` (`deployToEnvironment` function)

**Problem:** If two commits to example-app/main land in quick succession, both builds create MRs to k8s-deployments dev with different image tags. The operator sees two open MRs and must know to merge only the latest. Stale MRs accumulate.

**Fix:** Before creating a new MR in `deployToEnvironment`, query GitLab for open MRs with the same `update-dev-` prefix targeting the same branch. Close them with a comment explaining they've been superseded:
```bash
# Close superseded MRs
EXISTING_MRS=$(curl -sf ... | jq -r '.[] | select(.source_branch | startswith("update-dev-")) | .iid')
for mr_iid in $EXISTING_MRS; do
    curl -sf -X PUT ... -d '{"state_event": "close"}' ...
    # Add comment: "Superseded by update-dev-${IMAGE_TAG}"
done
```

**Acceptance criteria:**
- When a new deployment MR is created, any prior open MRs with the same prefix to the same target are closed
- Closed MRs have a comment indicating which MR superseded them
- Already-merged MRs are not affected

---

## JENKINS-28: Replace /tmp/maven-settings.xml with scoped credential pattern

**Files:** `example-app/Jenkinsfile`

**Problem:** `createMavenSettings()` (lines 182-197) writes Nexus credentials to `/tmp/maven-settings.xml`. Cleanup in `post.always` does `rm -f /tmp/maven-settings.xml`, but on abort/timeout, cleanup may not run. In the ephemeral pod model this is harmless, but it's a bad pattern to demonstrate in a reference implementation.

**Fix:** Use Jenkins' `configFileProvider` step or generate the settings file inline within the `sh` block that uses it (so it's scoped to that execution). Alternatively, use Maven's `-Dusername` and `-Dpassword` properties if the Nexus plugin supports it. Since JENKINS-22 removes the dead cleanup code, this ticket focuses on the creation pattern.

**Acceptance criteria:**
- Maven settings file is scoped to the block that needs it (not written to a shared temp path)
- No cleanup code needed for the settings file

---

## JENKINS-29: Standardize infrastructure variable and credential naming

**Files:** `config/infra.env`, `config/clusters/*.env`, `scripts/02-configure/configure-jenkins-global-env.sh`, `scripts/01-infrastructure/setup-jenkins-credentials.sh`, `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`, and ~17 scripts under `scripts/`

**Problem:** Infrastructure variable names mix product names (Docker, Nexus) with functional names (container, maven). The preference is functional names — they describe *what the thing does*, not *what product provides it*:

- `DOCKER_REGISTRY_EXTERNAL` / `DOCKER_REGISTRY_INTERNAL` — these are container registries, not necessarily Docker
- `NEXUS_URL_INTERNAL` / `NEXUS_URL_EXTERNAL` — used as Maven repository URLs, not Nexus-specific operations
- `nexus-credentials` / `docker-registry-credentials` — Jenkins credential IDs that reference products instead of roles

This inconsistency makes it harder to swap implementations (e.g., replace Nexus with Artifactory, or use a non-Docker registry) and confuses new users about what each variable controls.

**Environment variable renames:**

| Current Name | New Name | Rationale |
|-------------|----------|-----------|
| `DOCKER_REGISTRY_EXTERNAL` | `CONTAINER_REGISTRY_EXTERNAL` | Functional: container registry, not Docker-specific |
| `DOCKER_REGISTRY_INTERNAL` | `CONTAINER_REGISTRY_INTERNAL` | Same |
| `DOCKER_REGISTRY_HOST` | `CONTAINER_REGISTRY_HOST` | Same (infra.env only) |
| `NEXUS_URL_INTERNAL` | `MAVEN_REPO_URL_INTERNAL` | Functional: Maven artifact repository |
| `NEXUS_URL_EXTERNAL` | `MAVEN_REPO_URL_EXTERNAL` | Same |
| `NEXUS_HOST_INTERNAL` | `MAVEN_REPO_HOST_INTERNAL` | Same (infra.env only) |
| `NEXUS_HOST_EXTERNAL` | `MAVEN_REPO_HOST_EXTERNAL` | Same (infra.env only) |

**Jenkins credential ID renames:**

| Current ID | New ID | Rationale |
|-----------|--------|-----------|
| `nexus-credentials` | `maven-repo-credentials` | Functional role, not product name |
| `docker-registry-credentials` | `container-registry-credentials` | Functional role, not product name |

**Out of scope:** Nexus product-admin resources (`nexus-admin-credentials` K8s secret, `NEXUS_NAMESPACE`, `NEXUS_ADMIN_*` vars, `configure-nexus.sh`). These configure the Nexus server itself — the product name is correct there.

**Fix:**
1. Rename variables in `config/infra.env` and `config/clusters/*.env`
2. Update the Groovy list in `configure-jenkins-global-env.sh`
3. Update credential IDs in `setup-jenkins-credentials.sh`
4. Update all three Jenkinsfiles (pipeline `environment` blocks, `credentials()` calls, validation lists, usage)
5. Update all scripts that reference the old names
6. Update `CLAUDE.md` and docs if they reference old names

**Acceptance criteria:**
- No `DOCKER_REGISTRY_*` or `NEXUS_URL_*` variable names in infra.env, ConfigMap config, or Jenkinsfiles
- `CONTAINER_REGISTRY_*` used consistently for registry URLs
- `MAVEN_REPO_URL_*` used consistently for artifact repository URLs
- Jenkins credential IDs use functional names (`maven-repo-credentials`, `container-registry-credentials`)
- `setup-jenkins-credentials.sh` creates credentials with new IDs
- All scripts and Jenkinsfiles use the new names
- Bootstrap and demo scripts still work end-to-end
