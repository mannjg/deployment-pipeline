# JENKINS-29: Standardize Infrastructure Variable Naming - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename all infrastructure variables and Jenkins credential IDs from product names (Docker, Nexus) to functional names (container-registry, maven-repo), and remove the dead `DOCKER_REGISTRY_INTERNAL` remnant.

**Architecture:** Pure find-and-replace across ~40 files. No logic changes, no new features. All changes must be atomic (single commit) because `validateRequiredEnvVars()` in Jenkinsfiles will fail immediately if any file is out of sync.

**Tech Stack:** Shell scripts, Groovy (Jenkinsfile), YAML (K8s manifests), Markdown (docs)

**Worktree:** `.worktrees/jenkins-29` on branch `jenkins-29/standardize-infra-naming`

**Design doc:** `docs/plans/2026-02-09-jenkins-29-design.md`

---

## Rename Reference

Keep this table open — every task references it:

| Old Name | New Name |
|----------|----------|
| `DOCKER_REGISTRY_HOST` | `CONTAINER_REGISTRY_HOST` |
| `DOCKER_REGISTRY_EXTERNAL` | `CONTAINER_REGISTRY_EXTERNAL` |
| `DOCKER_REGISTRY_INTERNAL` | **(REMOVE)** |
| `NEXUS_URL_INTERNAL` | `MAVEN_REPO_URL_INTERNAL` |
| `NEXUS_URL_EXTERNAL` | `MAVEN_REPO_URL_EXTERNAL` |
| `NEXUS_HOST_INTERNAL` | `MAVEN_REPO_HOST_INTERNAL` |
| `NEXUS_HOST_EXTERNAL` | `MAVEN_REPO_HOST_EXTERNAL` |
| `NEXUS_HOST` (envsubst alias) | `MAVEN_REPO_HOST` |
| `DOCKER_REGISTRY` (envsubst alias) | `CONTAINER_REGISTRY` |
| `nexus-credentials` | `maven-repo-credentials` |
| `docker-registry-credentials` | `container-registry-credentials` |

**Design invariant:** `CONTAINER_REGISTRY_*` and `MAVEN_REPO_*` are independently configurable and MUST work whether they point to the same or different backing services.

---

### Task 1: Rename variables in config/infra.env

**Files:**
- Modify: `config/infra.env`

**Step 1: Apply renames and removal**

In `config/infra.env`, make these changes in the `# Nexus / Docker Registry` section (lines 78-94):

1. Rename section header: `# Nexus / Docker Registry` → `# Maven Repository / Container Registry`
2. Line 80: `NEXUS_HOST_INTERNAL=` → `MAVEN_REPO_HOST_INTERNAL=`
3. Line 81: `NEXUS_HOST_EXTERNAL=` → `MAVEN_REPO_HOST_EXTERNAL=`
4. Line 82: `DOCKER_REGISTRY_HOST=` → `CONTAINER_REGISTRY_HOST=`
5. Line 84: `NEXUS_URL_INTERNAL="http://${NEXUS_HOST_INTERNAL}:8081"` → `MAVEN_REPO_URL_INTERNAL="http://${MAVEN_REPO_HOST_INTERNAL}:8081"`
6. Line 85: `NEXUS_URL_EXTERNAL="https://${NEXUS_HOST_EXTERNAL}"` → `MAVEN_REPO_URL_EXTERNAL="https://${MAVEN_REPO_HOST_EXTERNAL}"`
7. Line 88: Remove `DOCKER_REGISTRY_INTERNAL="${NEXUS_HOST_INTERNAL}:5000"` entirely
8. Line 89: `DOCKER_REGISTRY_EXTERNAL="${DOCKER_REGISTRY_HOST}"` → `CONTAINER_REGISTRY_EXTERNAL="${CONTAINER_REGISTRY_HOST}"`
9. Keep `NEXUS_ADMIN_SECRET`, `NEXUS_ADMIN_USER_KEY`, `NEXUS_ADMIN_PASSWORD_KEY` unchanged (product-admin scope)
10. Keep `NEXUS_NAMESPACE` unchanged (product-admin scope)

**Step 2: Verify no old names remain**

Run: `grep -E 'DOCKER_REGISTRY_|NEXUS_URL_|NEXUS_HOST_' config/infra.env`
Expected: Only `NEXUS_NAMESPACE`, `NEXUS_ADMIN_*` lines remain.

---

### Task 2: Rename variables in config/clusters/*.env

**Files:**
- Modify: `config/clusters/reference.env`
- Modify: `config/clusters/alpha.env`
- Modify: `config/clusters/beta.env`

Apply the same renames as Task 1 to each cluster config file. Each file has the same structure:

For each file:
1. Rename section header: `# Nexus / Docker Registry` → `# Maven Repository / Container Registry`
2. `NEXUS_HOST_INTERNAL=` → `MAVEN_REPO_HOST_INTERNAL=`
3. `NEXUS_URL_INTERNAL=` → `MAVEN_REPO_URL_INTERNAL=` (update `${NEXUS_HOST_INTERNAL}` ref → `${MAVEN_REPO_HOST_INTERNAL}`)
4. `NEXUS_URL_EXTERNAL=` → `MAVEN_REPO_URL_EXTERNAL=` (update `${NEXUS_HOST_EXTERNAL}` ref → `${MAVEN_REPO_HOST_EXTERNAL}`)
5. Remove `DOCKER_REGISTRY_INTERNAL=` line
6. `DOCKER_REGISTRY_EXTERNAL=` → `CONTAINER_REGISTRY_EXTERNAL=` (update `${DOCKER_REGISTRY_HOST}` ref → `${CONTAINER_REGISTRY_HOST}`)
7. `DOCKER_REGISTRY_HOST=` → `CONTAINER_REGISTRY_HOST=`
8. `NEXUS_HOST_EXTERNAL=` → `MAVEN_REPO_HOST_EXTERNAL=`

Also in the External Hostnames section:
9. `DOCKER_REGISTRY_HOST=` → `CONTAINER_REGISTRY_HOST=` (alpha:36, beta:37, reference:36)
10. `NEXUS_HOST_EXTERNAL=` → `MAVEN_REPO_HOST_EXTERNAL=` (alpha:34, beta:35, reference:34)

Note: `NEXUS_NAMESPACE`, `NEXUS_ADMIN_*` stay unchanged.

**Verify:** `grep -rE 'DOCKER_REGISTRY_|NEXUS_URL_|NEXUS_HOST_' config/clusters/*.env` — only `NEXUS_NAMESPACE`, `NEXUS_ADMIN_*` remain.

---

### Task 3: Rename variables in config/clusters/README.md

**Files:**
- Modify: `config/clusters/README.md`

1. Line 80: `NEXUS_HOST_EXTERNAL` → `MAVEN_REPO_HOST_EXTERNAL`, update description from "Nexus ingress hostname" to "Maven repository ingress hostname"
2. Line 82: `DOCKER_REGISTRY_HOST` → `CONTAINER_REGISTRY_HOST`, update description from "Docker registry hostname (via Nexus)" to "Container registry hostname"

---

### Task 4: Rename in K8s ConfigMap template

**Files:**
- Modify: `k8s/jenkins/pipeline-config.yaml`

1. Line 18: Comment `${NEXUS_HOST}` → `${MAVEN_REPO_HOST}`, update description
2. Line 20: Comment `${DOCKER_REGISTRY}` → `${CONTAINER_REGISTRY}`, update description
3. Line 53: `"${DOCKER_REGISTRY}/` → `"${CONTAINER_REGISTRY}/` (JENKINS_AGENT_IMAGE)
4. Line 57: Section header `# Nexus / Docker Registry Configuration` → `# Maven Repository / Container Registry Configuration`
5. Line 59: `NEXUS_URL_EXTERNAL: "https://${NEXUS_HOST}"` → `MAVEN_REPO_URL_EXTERNAL: "https://${MAVEN_REPO_HOST}"`
6. Line 60: `NEXUS_URL_INTERNAL:` → `MAVEN_REPO_URL_INTERNAL:`
7. Line 61: `DOCKER_REGISTRY_EXTERNAL: "${DOCKER_REGISTRY}"` → `CONTAINER_REGISTRY_EXTERNAL: "${CONTAINER_REGISTRY}"`
8. Line 62: Remove `DOCKER_REGISTRY_INTERNAL:` line entirely

**Verify:** `grep -E 'DOCKER_REGISTRY|NEXUS_URL|NEXUS_HOST' k8s/jenkins/pipeline-config.yaml` — no matches.

---

### Task 5: Rename in K8s Nexus manifest template

**Files:**
- Modify: `k8s/nexus/nexus-lightweight.yaml`

1. Line 7: Comment `${NEXUS_HOST}` → `${MAVEN_REPO_HOST}`
2. Line 8: Comment `${DOCKER_REGISTRY}` → `${CONTAINER_REGISTRY}`, update description
3. Line 22: `commonName: ${NEXUS_HOST}` → `commonName: ${MAVEN_REPO_HOST}`
4. Line 24: `- ${NEXUS_HOST}` → `- ${MAVEN_REPO_HOST}`
5. Line 36: `commonName: ${DOCKER_REGISTRY}` → `commonName: ${CONTAINER_REGISTRY}`
6. Line 38: `- ${DOCKER_REGISTRY}` → `- ${CONTAINER_REGISTRY}`
7. Line 151: `- ${NEXUS_HOST}` → `- ${MAVEN_REPO_HOST}`
8. Line 154: `host: ${NEXUS_HOST}` → `host: ${MAVEN_REPO_HOST}`
9. Line 179: `- ${DOCKER_REGISTRY}` → `- ${CONTAINER_REGISTRY}`
10. Line 182: `host: ${DOCKER_REGISTRY}` → `host: ${CONTAINER_REGISTRY}`

---

### Task 6: Rename Jenkins credential IDs in setup-jenkins-credentials.sh

**Files:**
- Modify: `scripts/01-infrastructure/setup-jenkins-credentials.sh`

1. Line 174: Rename function `setup_nexus_credentials` → `setup_maven_repo_credentials`
2. Line 175: Log message update: "Setting up Nexus credentials..." → "Setting up Maven repository credentials..."
3. Line 185: `"nexus-credentials"` → `"maven-repo-credentials"`
4. Line 188: Description: update to "Maven repository credentials for artifact deployment"
5. Line 190: `nexus-credentials:` → `maven-repo-credentials:` in warning
6. Line 213: Rename function `setup_docker_registry_credentials` → `setup_container_registry_credentials`
7. Line 214: Log message update
8. Line 223: `"docker-registry-credentials"` → `"container-registry-credentials"`
9. Line 226: Description: `"Docker Registry credentials for image push (${DOCKER_REGISTRY_HOST:-external registry})"` → `"Container registry credentials for image push (${CONTAINER_REGISTRY_HOST:-external registry})"`
10. Line 228-229: Update warning messages to use new ID
11. Line 247: Update function calls: `setup_nexus_credentials` → `setup_maven_repo_credentials`, `setup_docker_registry_credentials` → `setup_container_registry_credentials`

---

### Task 7: Rename in configure-jenkins-global-env.sh (Groovy list)

**Files:**
- Modify: `scripts/02-configure/configure-jenkins-global-env.sh`

1. Line 87: `"DOCKER_REGISTRY_EXTERNAL",` → `"CONTAINER_REGISTRY_EXTERNAL",`
2. Line 88: Remove `"DOCKER_REGISTRY_INTERNAL",` entirely
3. Line 93: `"NEXUS_URL_EXTERNAL",` → `"MAVEN_REPO_URL_EXTERNAL",`
4. Line 94: `"NEXUS_URL_INTERNAL",` → `"MAVEN_REPO_URL_INTERNAL",`
5. Line 185: Update echo message `"  - env.DOCKER_REGISTRY_* (for image pushing)"` → `"  - env.CONTAINER_REGISTRY_* (for image pushing)"`

---

### Task 8: Rename in configure-jenkins.sh (manual setup docs)

**Files:**
- Modify: `scripts/02-configure/configure-jenkins.sh`

1. Line 89-96: `nexus-credentials` → `maven-repo-credentials`, update description from "Nexus Repository Credentials" to "Maven Repository Credentials"
2. Line 98-105: `docker-registry-credentials` → `container-registry-credentials`, update description from "Docker Registry (Nexus) Credentials" to "Container Registry Credentials"

---

### Task 9: Rename in example-app/Jenkinsfile

**Files:**
- Modify: `example-app/Jenkinsfile`

1. Line 282: `"${env.DOCKER_REGISTRY_EXTERNAL ?: ''}"` → `"${env.CONTAINER_REGISTRY_EXTERNAL ?: ''}"`
2. Line 285: `"${env.NEXUS_URL_INTERNAL ?: ''}"` → `"${env.MAVEN_REPO_URL_INTERNAL ?: ''}"`
3. Line 293: `credentials('nexus-credentials')` → `credentials('maven-repo-credentials')`
4. Line 294: `credentials('docker-registry-credentials')` → `credentials('container-registry-credentials')`
5. Line 311: `'DOCKER_REGISTRY_EXTERNAL'` → `'CONTAINER_REGISTRY_EXTERNAL'` in validateRequiredEnvVars list

Also update the variable names that reference these:
6. Line 284: Comment about "Maven repository" stays accurate
7. Line 293: `NEXUS_CREDENTIALS` → `MAVEN_REPO_CREDENTIALS` (pipeline env var name)
8. Line 294: `DOCKER_CREDENTIALS` → `CONTAINER_REGISTRY_CREDENTIALS` (pipeline env var name)
9. Lines using `NEXUS_CREDENTIALS_USR`/`NEXUS_CREDENTIALS_PSW` → `MAVEN_REPO_CREDENTIALS_USR`/`MAVEN_REPO_CREDENTIALS_PSW` (Jenkins auto-generated from env var name)
10. Lines using `DOCKER_CREDENTIALS_USR`/`DOCKER_CREDENTIALS_PSW` → `CONTAINER_REGISTRY_CREDENTIALS_USR`/`CONTAINER_REGISTRY_CREDENTIALS_PSW`

---

### Task 10: Rename in k8s-deployments/Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile`

1. Line 374: `export NEXUS_URL_INTERNAL="${env.NEXUS_URL_INTERNAL}"` → `export MAVEN_REPO_URL_INTERNAL="${env.MAVEN_REPO_URL_INTERNAL}"`
2. Line 375: `export DOCKER_REGISTRY_EXTERNAL="${env.DOCKER_REGISTRY_EXTERNAL}"` → `export CONTAINER_REGISTRY_EXTERNAL="${env.CONTAINER_REGISTRY_EXTERNAL}"`
3. Line 430: `REGISTRY="\${DOCKER_REGISTRY_EXTERNAL}"` → `REGISTRY="\${CONTAINER_REGISTRY_EXTERNAL}"`
4. Line 518: `credentialsId: 'nexus-credentials'` → `credentialsId: 'maven-repo-credentials'`
5. Line 598: `${env.DOCKER_REGISTRY_EXTERNAL?.replaceAll(` → `${env.CONTAINER_REGISTRY_EXTERNAL?.replaceAll(`
6. Line 624: `DOCKER_REGISTRY_EXTERNAL = "${env.DOCKER_REGISTRY_EXTERNAL ?: ''}"` → `CONTAINER_REGISTRY_EXTERNAL = "${env.CONTAINER_REGISTRY_EXTERNAL ?: ''}"`
7. Line 628: `NEXUS_URL_INTERNAL = "${env.NEXUS_URL_INTERNAL ?: ''}"` → `MAVEN_REPO_URL_INTERNAL = "${env.MAVEN_REPO_URL_INTERNAL ?: ''}"`
8. Line 647: `'DOCKER_REGISTRY_EXTERNAL'` → `'CONTAINER_REGISTRY_EXTERNAL'` in validateRequiredEnvVars list

---

### Task 11: Rename in k8s-deployments/jenkins/pipelines/Jenkinsfile.promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

1. Line 131: `"${env.DOCKER_REGISTRY_EXTERNAL ?: ''}"` → `"${env.CONTAINER_REGISTRY_EXTERNAL ?: ''}"`
2. Line 149: `'DOCKER_REGISTRY_EXTERNAL'` → `'CONTAINER_REGISTRY_EXTERNAL'` in validateRequiredEnvVars list

---

### Task 12: Rename in k8s-deployments/scripts/promote-artifact.sh

**Files:**
- Modify: `k8s-deployments/scripts/promote-artifact.sh`

1. Line 70: Doc comment `NEXUS_URL_INTERNAL` → `MAVEN_REPO_URL_INTERNAL`
2. Line 71: Doc comment `DOCKER_REGISTRY_EXTERNAL` → `CONTAINER_REGISTRY_EXTERNAL`
3. Line 135: `NEXUS_URL="${NEXUS_URL:-${NEXUS_URL_INTERNAL:?NEXUS_URL_INTERNAL not set` → `NEXUS_URL="${NEXUS_URL:-${MAVEN_REPO_URL_INTERNAL:?MAVEN_REPO_URL_INTERNAL not set`
4. Line 136: `DOCKER_REGISTRY="${DOCKER_REGISTRY_EXTERNAL:?DOCKER_REGISTRY_EXTERNAL not set` → `CONTAINER_REGISTRY="${CONTAINER_REGISTRY_EXTERNAL:?CONTAINER_REGISTRY_EXTERNAL not set`
5. Line 434: `"${DOCKER_REGISTRY}/` → `"${CONTAINER_REGISTRY}/`
6. Line 435: `"${DOCKER_REGISTRY}/` → `"${CONTAINER_REGISTRY}/`
7. Line 443: `docker login "$DOCKER_REGISTRY"` → `docker login "$CONTAINER_REGISTRY"`
8. All other references to `$DOCKER_REGISTRY` local var → `$CONTAINER_REGISTRY`

Note: `NEXUS_USER`/`NEXUS_PASSWORD` in this script are env vars from `withCredentials` in the calling Jenkinsfile. They will change name when the credential ID changes (Task 10 changes `nexus-credentials` → `maven-repo-credentials`, so the Jenkinsfile's `usernameVariable`/`passwordVariable` names can stay as `NEXUS_USER`/`NEXUS_PASSWORD` since those are just local var names within the `withCredentials` block, OR we can rename them too). Since the Jenkinsfile controls the var names via `usernameVariable: 'NEXUS_USER'`, those stay unless we change the Jenkinsfile. Leave them — they're scoped to the `withCredentials` block and don't leak.

---

### Task 13: Rename in bootstrap.sh

**Files:**
- Modify: `scripts/bootstrap.sh`

1. Line 105: `"NEXUS_HOST_EXTERNAL"` → `"MAVEN_REPO_HOST_EXTERNAL"` (required vars check)
2. Line 230: `${DOCKER_REGISTRY_HOST}` → `${CONTAINER_REGISTRY_HOST}`
3. Line 237: `${DOCKER_REGISTRY_HOST}` → `${CONTAINER_REGISTRY_HOST}`
4. Line 246: `NEXUS_HOST_EXTERNAL` → `MAVEN_REPO_HOST_EXTERNAL` (in export list)
5. Line 247: `export DOCKER_REGISTRY_HOST` → `export CONTAINER_REGISTRY_HOST`
6. Line 257: `export NEXUS_HOST="${NEXUS_HOST_EXTERNAL}"` → `export MAVEN_REPO_HOST="${MAVEN_REPO_HOST_EXTERNAL}"`
7. Line 259: `export DOCKER_REGISTRY="${DOCKER_REGISTRY_HOST}"` → `export CONTAINER_REGISTRY="${CONTAINER_REGISTRY_HOST}"`
8. Line 629: `${DOCKER_REGISTRY_HOST}` → `${CONTAINER_REGISTRY_HOST}`
9. Line 813: `$NEXUS_HOST_EXTERNAL` → `$MAVEN_REPO_HOST_EXTERNAL`, `${DOCKER_REGISTRY_HOST:-}` → `${CONTAINER_REGISTRY_HOST:-}`
10. Line 837: `${NEXUS_HOST_EXTERNAL}` → `${MAVEN_REPO_HOST_EXTERNAL}`

---

### Task 14: Rename in apply-infrastructure.sh

**Files:**
- Modify: `scripts/01-infrastructure/apply-infrastructure.sh`

1. Line 42: Replace backwards-compat shim `NEXUS_HOST="${NEXUS_HOST_EXTERNAL:-${NEXUS_HOST:-}}"` → `MAVEN_REPO_HOST="${MAVEN_REPO_HOST_EXTERNAL:-${MAVEN_REPO_HOST:-}}"`
2. Line 49: `echo "Nexus:   https://$NEXUS_HOST"` → `echo "Nexus:   https://$MAVEN_REPO_HOST"`
3. Line 152: `$NEXUS_HOST` → `$MAVEN_REPO_HOST`

---

### Task 15: Rename in remaining scripts

**Files:**
- Modify: `scripts/02-configure/configure-nexus.sh`
- Modify: `scripts/03-pipelines/reset-demo-state.sh`
- Modify: `scripts/03-pipelines/setup-gitlab-env-branches.sh`
- Modify: `scripts/03-pipelines/setup-gitlab-repos.sh`
- Modify: `scripts/04-operations/check-health.sh`
- Modify: `scripts/demo/demo-uc-d4-3rd-party-upgrade.sh`
- Modify: `scripts/demo/demo-uc-e1-app-deployment.sh`
- Modify: `k8s/jenkins/agent/build-agent-image.sh`

**configure-nexus.sh:**
1. Line 18: `NEXUS_URL_EXTERNAL` → `MAVEN_REPO_URL_EXTERNAL`
2. Line 324: `${DOCKER_REGISTRY_HOST}` → `${CONTAINER_REGISTRY_HOST}`

**reset-demo-state.sh:**
1. Line 548: `${DOCKER_REGISTRY_HOST:?DOCKER_REGISTRY_HOST not set}` → `${CONTAINER_REGISTRY_HOST:?CONTAINER_REGISTRY_HOST not set}`

**setup-gitlab-env-branches.sh:**
1. Line 147: `${DOCKER_REGISTRY_HOST:?DOCKER_REGISTRY_HOST must be set` → `${CONTAINER_REGISTRY_HOST:?CONTAINER_REGISTRY_HOST must be set`
2. Line 167: `DOCKER_REGISTRY="${DOCKER_REGISTRY_HOST}"` → `CONTAINER_REGISTRY="${CONTAINER_REGISTRY_HOST}"`
3. Line 240: `${DOCKER_REGISTRY}` → `${CONTAINER_REGISTRY}`

**setup-gitlab-repos.sh:**
1. Line 133: Update echo message: `nexus-credentials, docker-registry-credentials` → `maven-repo-credentials, container-registry-credentials`

**check-health.sh:**
1. Line 206: `$NEXUS_URL_EXTERNAL` → `$MAVEN_REPO_URL_EXTERNAL`
2. Line 215: `$DOCKER_REGISTRY_EXTERNAL` → `$CONTAINER_REGISTRY_EXTERNAL`
3. Line 218: `$DOCKER_REGISTRY_EXTERNAL` → `$CONTAINER_REGISTRY_EXTERNAL`, update message text

**demo-uc-d4-3rd-party-upgrade.sh:**
1. Line 448: `${DOCKER_REGISTRY_EXTERNAL}` → `${CONTAINER_REGISTRY_EXTERNAL}`

**demo-uc-e1-app-deployment.sh:**
1. Line 195: `${NEXUS_URL_EXTERNAL:?NEXUS_URL_EXTERNAL not set` → `${MAVEN_REPO_URL_EXTERNAL:?MAVEN_REPO_URL_EXTERNAL not set`
2. Line 789: `${DOCKER_REGISTRY_EXTERNAL:?DOCKER_REGISTRY_EXTERNAL not set}` → `${CONTAINER_REGISTRY_EXTERNAL:?CONTAINER_REGISTRY_EXTERNAL not set}`
3. Line 1134: `${NEXUS_URL_EXTERNAL:?NEXUS_URL_EXTERNAL not set` → `${MAVEN_REPO_URL_EXTERNAL:?MAVEN_REPO_URL_EXTERNAL not set`

**build-agent-image.sh:**
1. Line 22: `${DOCKER_REGISTRY_HOST:?DOCKER_REGISTRY_HOST not set}` → `${CONTAINER_REGISTRY_HOST:?CONTAINER_REGISTRY_HOST not set}`

---

### Task 16: Update supporting config files

**Files:**
- Modify: `example-app/config/local.env.example`
- Modify: `example-app/config/configmap.schema.yaml`
- Modify: `k8s-deployments/config/local.env.example`
- Modify: `k8s-deployments/config/configmap.schema.yaml`

**local.env.example (both):**
1. `DOCKER_REGISTRY_EXTERNAL=` → `CONTAINER_REGISTRY_EXTERNAL=`

**configmap.schema.yaml (example-app):**
1. `DOCKER_REGISTRY_EXTERNAL:` → `CONTAINER_REGISTRY_EXTERNAL:`
2. `nexus-credentials:` → `maven-repo-credentials:`
3. `docker-registry-credentials:` → `container-registry-credentials:`

**configmap.schema.yaml (k8s-deployments):**
1. `DOCKER_REGISTRY_EXTERNAL:` → `CONTAINER_REGISTRY_EXTERNAL:`

---

### Task 17: Update documentation

**Files:**
- Modify: `example-app/docs/CONFIGURATION.md`
- Modify: `k8s-deployments/docs/CONFIGURATION.md`
- Modify: `CLAUDE.md`

**example-app/docs/CONFIGURATION.md:**
1. Line 18: `DOCKER_REGISTRY_EXTERNAL` → `CONTAINER_REGISTRY_EXTERNAL`, update description
2. Line 25: `nexus-credentials` → `maven-repo-credentials`, update description to "Maven repository credentials for artifacts"
3. Line 26: `docker-registry-credentials` → `container-registry-credentials`, update description to "Container registry credentials for image push"
4. Line 33: "Publishes Docker image to Nexus registry" → "Publishes container image to registry"
5. Line 52: Migration table: `DOCKER_REGISTRY` → `CONTAINER_REGISTRY_EXTERNAL` (update the "New Name" column)

**k8s-deployments/docs/CONFIGURATION.md:**
1. Line 21: `DOCKER_REGISTRY_EXTERNAL` → `CONTAINER_REGISTRY_EXTERNAL`, update description
2. Line 61: ConfigMap example: `DOCKER_REGISTRY_EXTERNAL:` → `CONTAINER_REGISTRY_EXTERNAL:`
3. Line 109: Migration table: `DOCKER_REGISTRY` → `CONTAINER_REGISTRY_EXTERNAL` (update the "New Name" column)

**CLAUDE.md:**
1. Update "Nexus" component description: `Maven artifacts and Docker registry` → `Maven artifacts`
2. Update Service Access table: `Docker Registry` row — update URL and purpose
3. Update `Centralized Config` example if it references old names
4. Update any other references to old variable names

---

### Task 18: Final verification

**Step 1: Search for any remaining old names**

Run these from the worktree root. Each should return zero matches (or only matches in docs/plans/ design/ticket files, or `NEXUS_NAMESPACE`/`NEXUS_ADMIN_*` product-admin scope):

```bash
grep -rn 'DOCKER_REGISTRY_EXTERNAL' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'DOCKER_REGISTRY_INTERNAL' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'DOCKER_REGISTRY_HOST' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'NEXUS_URL_INTERNAL' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'NEXUS_URL_EXTERNAL' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'NEXUS_HOST_INTERNAL' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'nexus-credentials' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
grep -rn 'docker-registry-credentials' --include='*.sh' --include='*.yaml' --include='*.groovy' --include='*.md' . | grep -v docs/plans/ | grep -v docs/archives/
```

Also search Jenkinsfiles specifically (no extension filter since they have no extension):
```bash
grep -rn 'DOCKER_REGISTRY_EXTERNAL\|DOCKER_REGISTRY_INTERNAL\|NEXUS_URL_INTERNAL\|NEXUS_URL_EXTERNAL\|nexus-credentials\|docker-registry-credentials' \
  example-app/Jenkinsfile k8s-deployments/Jenkinsfile k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
```

Expected: Zero matches for all searches.

**Step 2: Verify new names are consistent**

```bash
grep -rn 'CONTAINER_REGISTRY_EXTERNAL' --include='*.sh' --include='*.yaml' . | head -20
grep -rn 'MAVEN_REPO_URL_INTERNAL' --include='*.sh' --include='*.yaml' . | head -20
grep -rn 'maven-repo-credentials' . | head -10
grep -rn 'container-registry-credentials' . | head -10
```

Expected: Matches in all expected files.

**Step 3: Commit**

```bash
git add -A
git status  # review all changes
git commit -m "feat(jenkins): standardize infra variable and credential naming (JENKINS-29)

Rename product-specific names to functional names:
- DOCKER_REGISTRY_* → CONTAINER_REGISTRY_*
- NEXUS_URL_* → MAVEN_REPO_URL_*
- NEXUS_HOST_* → MAVEN_REPO_HOST_*
- nexus-credentials → maven-repo-credentials
- docker-registry-credentials → container-registry-credentials

Remove dead DOCKER_REGISTRY_INTERNAL (abandoned Nexus Docker connector).
Remove backwards-compat shims for old variable names.
Update envsubst aliases, K8s templates, and documentation."
```

---

### Task 19: Update ticket backlog

**Files:**
- Modify: `docs/plans/2026-02-07-jenkinsfile-review-tickets.md`

Remove the JENKINS-29 ticket section from the backlog (it's now implemented).
