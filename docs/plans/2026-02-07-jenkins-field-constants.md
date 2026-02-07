# JENKINS-06: Add @Field Constants for Branch Prefix Patterns - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract hardcoded branch prefix patterns and environment lists into `@Field` constants for discoverability and single-definition.

**Architecture:** Add `import groovy.transform.Field` and `@Field` constant declarations at the top of each Jenkinsfile (before helper functions or `pipeline {}` block). Replace hardcoded string literals at usage sites. No behavioral change.

**Tech Stack:** Jenkins Declarative Pipeline, Groovy `@Field` annotation

---

### Task 1: Add @Field constants and update Jenkinsfile (main)

**Files:**
- Modify: `k8s-deployments/Jenkinsfile`

**Step 1: Add import and @Field declarations**

Insert at line 1 (before the existing comment block):

```groovy
import groovy.transform.Field

@Field static final String UPDATE_BRANCH_PREFIX = 'update-'
@Field static final String PROMOTE_BRANCH_PREFIX = 'promote-'
@Field static final List<String> ENV_BRANCHES = ['dev', 'stage', 'prod']

```

**Step 2: Update getTargetEnvironment() (lines 96, 100, 104, 107)**

```groovy
// Line 96: if (branchName in ['dev', 'stage', 'prod']) {
// Change to:
if (branchName in ENV_BRANCHES) {

// Line 100: if (branchName.startsWith('update-dev-')) {
// Change to:
if (branchName.startsWith("${UPDATE_BRANCH_PREFIX}dev-")) {

// Line 104: if (branchName.startsWith('promote-stage-')) {
// Change to:
if (branchName.startsWith("${PROMOTE_BRANCH_PREFIX}stage-")) {

// Line 107: if (branchName.startsWith('promote-prod-')) {
// Change to:
if (branchName.startsWith("${PROMOTE_BRANCH_PREFIX}prod-")) {
```

**Step 3: Update getMRTargetEnvironment() (lines 131, 148)**

```groovy
// Line 131: def isEnvBranch = branchName in ['dev', 'stage', 'prod']
// Change to:
def isEnvBranch = branchName in ENV_BRANCHES

// Line 148: if (targetBranch in ['dev', 'stage', 'prod']) {
// Change to:
if (targetBranch in ENV_BRANCHES) {
```

**Step 4: Update createPromotionMR() (lines 300, 378)**

```groovy
// Line 300: ...select(.source_branch | startswith("promote-${targetEnv}-"))...
// Change to:
// ...select(.source_branch | startswith("${PROMOTE_BRANCH_PREFIX}${targetEnv}-"))...

// Line 378: PROMOTION_BRANCH="promote-${targetEnv}-\${TIMESTAMP}"
// Change to:
PROMOTION_BRANCH="${PROMOTE_BRANCH_PREFIX}${targetEnv}-\${TIMESTAMP}"
```

**Step 5: Update Initialize stage (line 588)**

```groovy
// Line 588: env.IS_ENV_BRANCH = (env.BRANCH_NAME in ['dev', 'stage', 'prod']) ? 'true' : 'false'
// Change to:
env.IS_ENV_BRANCH = (env.BRANCH_NAME in ENV_BRANCHES) ? 'true' : 'false'
```

**Step 6: Update Prepare Merge Preview stage (line 630)**

```groovy
// Line 630: def isPromoteBranch = env.BRANCH_NAME.startsWith('promote-')
// Change to:
def isPromoteBranch = env.BRANCH_NAME.startsWith(PROMOTE_BRANCH_PREFIX)
```

**Step 7: Update Generate Manifests stage (line 687)**

```groovy
// Line 687: !env.BRANCH_NAME.startsWith('promote-')
// Change to:
!env.BRANCH_NAME.startsWith(PROMOTE_BRANCH_PREFIX)
```

**Step 8: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "refactor(jenkins): extract @Field constants for branch prefixes in k8s-deployments Jenkinsfile"
```

---

### Task 2: Add @Field constants and update Jenkinsfile.promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote`

**Step 1: Add import and @Field declaration**

Insert at line 1 (before the existing JSDoc comment):

```groovy
import groovy.transform.Field

@Field static final String PROMOTE_BRANCH_PREFIX = 'promote-'

```

**Step 2: Update branch name construction (lines 246, 317)**

```groovy
// Line 246: FEATURE_BRANCH="promote-${params.TARGET_ENV}-${PROMOTE_IMAGE_TAG}"
// Change to:
FEATURE_BRANCH="${PROMOTE_BRANCH_PREFIX}${params.TARGET_ENV}-${PROMOTE_IMAGE_TAG}"

// Line 317: FEATURE_BRANCH="promote-${params.TARGET_ENV}-${PROMOTE_IMAGE_TAG}"
// Change to:
FEATURE_BRANCH="${PROMOTE_BRANCH_PREFIX}${params.TARGET_ENV}-${PROMOTE_IMAGE_TAG}"
```

**Step 3: Update output message (line 335)**

```groovy
// Line 335: ...promote-${params.TARGET_ENV}-${env.PROMOTE_IMAGE_TAG} -> ${params.TARGET_ENV}...
// Change to:
// ...${PROMOTE_BRANCH_PREFIX}${params.TARGET_ENV}-${env.PROMOTE_IMAGE_TAG} -> ${params.TARGET_ENV}...
```

**Step 4: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "refactor(jenkins): extract @Field constants for branch prefixes in Jenkinsfile.promote"
```

---

### Task 3: Add @Field constants and update Jenkinsfile.auto-promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote`

**Step 1: Add import and @Field declaration**

Insert at line 1 (before the existing JSDoc comment):

```groovy
import groovy.transform.Field

@Field static final List<String> ENV_BRANCHES = ['dev', 'stage', 'prod']

```

**Step 2: Update validBranches (line 54)**

```groovy
// Line 54: def validBranches = ['dev', 'stage', 'prod']
// Change to:
def validBranches = ENV_BRANCHES
```

Note: The `choices: ['dev', 'stage', 'prod']` on line 34 stays untouched (semantic identifier in parameter block).

**Step 3: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote
git commit -m "refactor(jenkins): extract @Field constants for env branches in Jenkinsfile.auto-promote"
```

---

### Task 4: Add @Field constants and update k8s-deployments-validation.Jenkinsfile

**Files:**
- Modify: `k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile`

**Step 1: Add import and @Field declaration**

Insert at line 1 (before the existing comment):

```groovy
import groovy.transform.Field

@Field static final List<String> ENV_BRANCHES = ['dev', 'stage', 'prod']

```

**Step 2: Update environment list references (lines 156, 188, 260)**

```groovy
// Line 156: def environments = params.VALIDATE_ALL_ENVS ? ['dev', 'stage', 'prod'] : [params.BRANCH_NAME]
// Change to:
def environments = params.VALIDATE_ALL_ENVS ? ENV_BRANCHES : [params.BRANCH_NAME]

// Line 188: def environments = params.VALIDATE_ALL_ENVS ? ['dev', 'stage', 'prod'] : [params.BRANCH_NAME]
// Change to:
def environments = params.VALIDATE_ALL_ENVS ? ENV_BRANCHES : [params.BRANCH_NAME]

// Line 260: def environments = params.VALIDATE_ALL_ENVS ? ['dev', 'stage', 'prod'] : [params.BRANCH_NAME]
// Change to:
def environments = params.VALIDATE_ALL_ENVS ? ENV_BRANCHES : [params.BRANCH_NAME]
```

**Step 3: Commit**

```bash
git add k8s-deployments/jenkins/k8s-deployments-validation.Jenkinsfile
git commit -m "refactor(jenkins): extract @Field constants for env branches in validation Jenkinsfile"
```
