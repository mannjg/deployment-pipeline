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
