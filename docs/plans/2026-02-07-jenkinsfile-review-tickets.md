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

## JENKINS-13: Fix validateRequiredEnvVars — check ConfigMap names, fix error message

**Files:** `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Depends on:** JENKINS-12 (env var pattern standardization)

**Problem:** Three issues with `validateRequiredEnvVars`:

1. **Jenkinsfile.promote (line 150)** validates derived names (`GITLAB_URL`, `DEPLOYMENT_REPO`, `DEPLOY_REGISTRY`) instead of ConfigMap names (`GITLAB_URL_INTERNAL`, `DEPLOYMENTS_REPO_URL`, `DOCKER_REGISTRY_EXTERNAL`). Error message says "Missing required ConfigMap variables: GITLAB_URL" — misleading.

2. **Error message** says "ConfigMap variables" but the variables could come from ConfigMap, system env, or Jenkins config. Should say "pipeline environment variables".

3. **k8s-deployments/Jenkinsfile (lines 589-591)** has a redundant `if (!env.GITLAB_URL)` check after already validating `GITLAB_URL_INTERNAL` on line 556.

4. **Jenkinsfile.promote** doesn't validate `JENKINS_AGENT_IMAGE` despite using it (line 65), unlike the other two Jenkinsfiles.

**Fix:**
- All three Jenkinsfiles should validate the raw ConfigMap/system variable names
- Change error message to "Missing required pipeline environment variables"
- Remove the redundant `GITLAB_URL` check in k8s-deployments/Jenkinsfile
- Add `JENKINS_AGENT_IMAGE` to Jenkinsfile.promote's validation list (note: since it's read via `System.getenv()` before the pipeline block, the existing `if (!agentImage)` check on line 66 already catches this — but adding it to the validation list is consistent)

**Acceptance criteria:**
- All three Jenkinsfiles validate the same base variable names where applicable
- Error message accurately describes what to check
- No redundant validation checks

---

## JENKINS-14: Fix reportGitLabStatus JSON injection and use jq

**Files:** `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`

**Problem:** `reportGitLabStatus` (duplicated in both files) constructs a JSON payload by interpolating `state`, `description`, and `context` directly into a string. Special characters in any parameter would break the JSON or allow injection. The function also uses Groovy interpolation of `${GITLAB_TOKEN}` inside `sh """` (overlaps with JENKINS-10).

**Fix:** Use `jq -n` to construct the JSON payload safely:
```bash
jq -n --arg state "$STATE" --arg desc "$DESC" --arg ctx "$CTX" \
    '{state: $state, description: $desc, context: $ctx}'
```

Also apply the JENKINS-10 credential fix to the `GITLAB_TOKEN` reference in this function.

**Acceptance criteria:**
- JSON payload is constructed with `jq`, not string interpolation
- Function handles special characters in context/description without breaking
- GitLab token is not leaked in build logs

---

## JENKINS-15: Fix promote-artifact.sh output parsing

**Files:** `k8s-deployments/Jenkinsfile` (`createPromotionMR` function)

**Problem:** Lines 358-363 capture the promoted image tag by piping `promote-artifact.sh` through `2>&1 | tee /tmp/promote.log | tail -1`. The "protocol" is that the last line of combined stdout+stderr is the image tag. Validation on line 369 tries to catch bad output via string matching (`contains("ERROR")`, `contains("[")`, `contains("not set")`).

This is fragile: any stderr warning from a subcommand appearing on the last line would be accepted as an image tag, or a valid tag containing matched substrings would be rejected.

**Fix:** Have `promote-artifact.sh` write the promoted image tag to a well-known file (e.g., `/tmp/promoted-image-tag`) and exit with a meaningful code. The Jenkinsfile reads the file separately:
```groovy
def rc = sh(script: "bash ./scripts/promote-artifact.sh ... 2>&1 | tee /tmp/promote.log", returnStatus: true)
if (rc != 0) { error "Artifact promotion failed..." }
newImageTag = readFile('/tmp/promoted-image-tag').trim()
```

**Acceptance criteria:**
- Image tag is communicated via file, not stdout parsing
- Script exit code determines success/failure
- String-matching validation is removed

---

## JENKINS-16: Fix partial failure in createPromotionMR — artifact promoted but no MR

**Files:** `k8s-deployments/Jenkinsfile` (`createPromotionMR` function)

**Depends on:** JENKINS-15 (output parsing fix)

**Problem:** Lines 421-424 exit with 0 if there are "no changes to promote" after artifact promotion has already completed (lines 347-375). Artifacts are retagged in Nexus and Docker registry, but no MR is created. The operator sees "No changes to promote" with no indication that artifacts were modified. On re-run, `promote-artifact.sh` may behave differently (duplicate detection).

**Fix:** Move the "no changes" check *before* artifact promotion, or ensure the "no changes" path logs clearly that artifacts were promoted and an MR was not needed. Consider: if config is identical but the image tag changed, there *are* changes — the "no changes" case should only apply when both config and image are already in sync.

**Acceptance criteria:**
- If artifacts are promoted, an MR is always created (or the reason for skipping is explicit and logged)
- If config is already in sync AND no image change, skip both artifact promotion and MR creation
- Operator can distinguish "nothing to do" from "promoted but no MR needed"

---

## JENKINS-17: Use deterministic branch names in createPromotionMR

**Files:** `k8s-deployments/Jenkinsfile` (`createPromotionMR` function)

**Problem:** Line 383-384 uses `TIMESTAMP=$(date +%Y%m%d-%H%M%S)` for promotion branch names. If a pipeline fails after pushing the branch but before creating the MR, re-running creates a second orphaned branch. Over time, failed retries accumulate orphaned branches in GitLab.

`deployToEnvironment` in example-app/Jenkinsfile correctly uses deterministic names (`update-dev-${IMAGE_TAG}`) with delete-before-push (line 157).

**Fix:** Use the image tag or git hash in the branch name instead of a timestamp:
```bash
PROMOTION_BRANCH="promote-${targetEnv}-${imageTag}"
```
Add delete-before-push to match the `deployToEnvironment` pattern.

**Acceptance criteria:**
- Re-running a failed promotion produces the same branch name
- Remote branch is deleted before push (handles retry case)
- No timestamp-based branch names in any Jenkinsfile

---

## JENKINS-18: Skip MR creation when deployToEnvironment has no changes

**Status: Implemented**

**Files:** `example-app/Jenkinsfile` (`deployToEnvironment` function)

**Problem:** Line 148 uses `git commit ... || echo "No changes to commit"`. If the image tag matches what's already on the branch (e.g., rebuild of same commit), the commit silently no-ops. Lines 152-169 then push an empty branch and create an MR with no diff. The operator sees "MR created successfully" for an empty MR.

**Fix:** After the commit attempt, check if HEAD actually moved. If not, skip the push and MR creation:
```bash
if git diff --quiet HEAD origin/${environment}; then
    echo "No changes vs ${environment} - skipping MR creation"
    exit 0
fi
```

**Acceptance criteria:**
- Rebuilding the same commit does not create an empty MR
- Log output clearly states why MR creation was skipped
- Normal flow (with changes) is unaffected

---

## JENKINS-19: Add error handling for git push in Generate Manifests stage

**Files:** `k8s-deployments/Jenkinsfile`

**Problem:** Line 727 pushes generated manifests to the feature branch with no error handling beyond `set -e`. If the push fails (force-push protection, network error, auth failure), the pipeline continues and reports success via GitLab status. The MR shows stale manifests.

**Fix:** Check the push exit code and fail the stage explicitly:
```bash
git push origin HEAD:${GIT_BRANCH#origin/} || {
    echo "ERROR: Failed to push generated manifests"
    exit 1
}
```

Also consider: if the push fails, should the GitLab commit status report the *original* commit SHA (pre-manifest-generation) or the new one? Currently `FINAL_COMMIT_SHA` is set after the push block (line 735), so on push failure it would be unset and the post block would fall back to `ORIGINAL_COMMIT_SHA` — which is correct. Document this.

**Acceptance criteria:**
- Push failure causes stage failure
- GitLab commit status reports against the correct SHA on both success and failure

---

## JENKINS-20: Prevent manifest push from triggering redundant webhook build

**Files:** `k8s-deployments/Jenkinsfile`

**Problem:** Line 727 pushes manifests to the feature branch, which triggers the GitLab webhook, which triggers the auto-promote router, which could trigger another k8s-deployments build. The second build queues (due to `disableConcurrentBuilds`), runs, finds no changes, and exits. Not broken, but wastes resources and confuses operators who see two builds per change.

**Options:**
1. Add `[ci skip]` or `[jenkins-ci]` to the commit message AND check for it in the Initialize stage
2. Configure the GitLab webhook to ignore pushes from the Jenkins user
3. Accept the extra build (it's cheap and self-correcting)

**Recommendation:** Option 1 is the most portable. The commit message already contains `[jenkins-ci]` (line 723). Add a check in the Initialize stage:
```groovy
def lastCommitMsg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
if (lastCommitMsg.contains('[jenkins-ci]')) {
    currentBuild.result = 'NOT_BUILT'
    currentBuild.description = 'Skipped: CI-generated commit'
    return
}
```

**Acceptance criteria:**
- Manifest push commit does not trigger a second build
- Manual pushes and MR merges still trigger builds normally

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
