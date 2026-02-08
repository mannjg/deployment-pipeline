# JENKINS-13: Fix validateRequiredEnvVars — check ConfigMap names, fix error message

**Date:** 2026-02-08
**Ticket:** JENKINS-13
**Depends on:** JENKINS-12 (completed: 86b6b2b)

## Problem

Four issues with `validateRequiredEnvVars` across all three Jenkinsfiles:

1. **Jenkinsfile.promote** validates derived pipeline env names (`GITLAB_URL`, `DEPLOYMENT_REPO`, `DEPLOY_REGISTRY`) instead of ConfigMap names (`GITLAB_URL_INTERNAL`, `DEPLOYMENTS_REPO_URL`, `DOCKER_REGISTRY_EXTERNAL`). Error message points at the wrong variable names.

2. **Error message** says "ConfigMap variables" but the variables could come from ConfigMap, system env, or Jenkins config. Should say "pipeline environment variables".

3. **k8s-deployments/Jenkinsfile line 622** has a redundant `if (!env.GITLAB_URL)` check after already validating `GITLAB_URL_INTERNAL` on line 589.

4. **Jenkinsfile.promote** doesn't validate `JENKINS_AGENT_IMAGE` despite using it, unlike the other two Jenkinsfiles.

Additionally, two related inconsistencies found during brainstorming:

5. **`GITLAB_GROUP`** is not validated as required in any Jenkinsfile, despite being used without fallback in some paths. Hardcoded `?: 'p2c'` fallbacks mask this and don't translate to new targets.

6. **`APP_GROUP = 'p2c'`** is hardcoded in example-app and Jenkinsfile.promote for the container registry path prefix. k8s-deployments correctly uses `CONTAINER_REGISTRY_PATH_PREFIX` from ConfigMap. The other two Jenkinsfiles should match.

## Changes

### 1. Fix error message (all three files)

**Files:** `example-app/Jenkinsfile`, `k8s-deployments/Jenkinsfile`, `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

```groovy
// Before:
error "Missing required ConfigMap variables: ${missing.join(', ')}. Check pipeline-config ConfigMap in Jenkins namespace."

// After:
error "Missing required pipeline environment variables: ${missing.join(', ')}. Check pipeline-config ConfigMap in Jenkins namespace."
```

### 2. Fix Jenkinsfile.promote validation list (line 152)

```groovy
// Before:
validateRequiredEnvVars(['GITLAB_URL', 'GITLAB_GROUP', 'DEPLOYMENT_REPO', 'DEPLOY_REGISTRY'])

// After:
validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'GITLAB_GROUP', 'DEPLOYMENTS_REPO_URL', 'DOCKER_REGISTRY_EXTERNAL', 'CONTAINER_REGISTRY_PATH_PREFIX'])
```

### 3. Add GITLAB_GROUP and CONTAINER_REGISTRY_PATH_PREFIX to example-app validation (line 298)

```groovy
// Before:
validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'DEPLOYMENTS_REPO_URL', 'DOCKER_REGISTRY_EXTERNAL'])

// After:
validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'GITLAB_GROUP', 'DEPLOYMENTS_REPO_URL', 'DOCKER_REGISTRY_EXTERNAL', 'CONTAINER_REGISTRY_PATH_PREFIX'])
```

### 4. Add GITLAB_GROUP to k8s-deployments validation (line 589)

```groovy
// Before:
validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'DOCKER_REGISTRY_EXTERNAL', 'CONTAINER_REGISTRY_PATH_PREFIX'])

// After:
validateRequiredEnvVars(['JENKINS_AGENT_IMAGE', 'GITLAB_URL_INTERNAL', 'GITLAB_GROUP', 'DOCKER_REGISTRY_EXTERNAL', 'CONTAINER_REGISTRY_PATH_PREFIX'])
```

### 5. Remove redundant GITLAB_URL check (k8s-deployments/Jenkinsfile lines 622-624)

Delete this block — already validated via `GITLAB_URL_INTERNAL` on line 589:

```groovy
// DELETE:
if (!env.GITLAB_URL) {
    error "GITLAB_URL_INTERNAL not set. Configure pipeline-config ConfigMap."
}
```

### 6. Replace hardcoded APP_GROUP with ConfigMap variable

**example-app/Jenkinsfile line 266:**
```groovy
// Before:
APP_GROUP = 'p2c'

// After:
APP_GROUP = "${env.CONTAINER_REGISTRY_PATH_PREFIX ?: ''}"
```

**Jenkinsfile.promote line 137:**
```groovy
// Before:
APP_GROUP = 'p2c'

// After:
APP_GROUP = "${env.CONTAINER_REGISTRY_PATH_PREFIX ?: ''}"
```

### 7. Clean up dead GITLAB_GROUP fallbacks

Since GITLAB_GROUP is now validated as required, remove all `?: 'p2c'` fallbacks and ternary fallbacks:

**example-app/Jenkinsfile (lines 333, 482, 499):**
```groovy
// Before (3 occurrences):
"${env.GITLAB_GROUP ?: 'p2c'}/example-app"

// After:
"${env.GITLAB_GROUP}/example-app"
```

**k8s-deployments/Jenkinsfile (lines 301, 632):**
```groovy
// Before:
def projectPath = env.GITLAB_GROUP ? "${env.GITLAB_GROUP}/k8s-deployments" : "p2c/k8s-deployments"

// After:
def projectPath = "${env.GITLAB_GROUP}/k8s-deployments"
```

**k8s-deployments/Jenkinsfile (lines 891, 909):**
```groovy
// Before:
"${env.GITLAB_GROUP ?: 'p2c'}/k8s-deployments"

// After:
"${env.GITLAB_GROUP}/k8s-deployments"
```

## Acceptance Criteria

- All three Jenkinsfiles validate the same base ConfigMap variable names where applicable
- `GITLAB_GROUP` and `CONTAINER_REGISTRY_PATH_PREFIX` validated in all three Jenkinsfiles
- Error message accurately describes what to check ("pipeline environment variables")
- No redundant validation checks
- No hardcoded `'p2c'` fallbacks in any Jenkinsfile
- `APP_GROUP` derived from `CONTAINER_REGISTRY_PATH_PREFIX` ConfigMap variable
- Multi-segment path prefixes (e.g., `internal/sandbox/user`) work correctly
