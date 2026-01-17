# Simplified k8s-deployments Pipeline Implementation Plan

**Date:** 2026-01-17
**Status:** Ready for implementation

## Goal

Simplify the k8s-deployments CI/CD pipeline by removing broken webhook-dependent workflows and consolidating into a single branch-based workflow. Fix validation scripts to work with the simplified architecture.

## Background

The current k8s-deployments Jenkinsfile has 4 workflows:
- **BRANCH_INDEX** - Works: validates CUE, generates manifests
- **VALIDATE** - Broken: calls non-existent `k8s-deployments-validation` job
- **DEPLOY** - Broken: never triggers (needs `MR_EVENT=merge` webhook parameter)
- **CLEANUP** - No-op

The simplified approach:
- Single workflow that runs on all branches
- Detects environment branches (dev/stage/prod) for deployment + auto-promotion
- No webhook parameters needed - just reacts to branch state
- Pre-merge validation still works via commit status on branch builds

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         SIMPLIFIED PIPELINE FLOW                          │
└──────────────────────────────────────────────────────────────────────────┘

Feature Branch (update-dev-*, promote-stage-*, etc.):
┌─────────────────────────────────────────┐
│  1. Validate CUE configuration          │
│  2. Generate manifests                  │
│  3. Commit manifests back to branch     │
│  4. Report status to GitLab (commit)    │  ← Blocks MR merge if failed
└─────────────────────────────────────────┘

Environment Branch (dev, stage, prod):
┌─────────────────────────────────────────┐
│  1. Validate CUE configuration          │
│  2. Generate manifests                  │
│  3. Commit manifests back to branch     │
│  4. Login to ArgoCD                     │
│  5. Refresh ArgoCD application          │
│  6. Wait for sync + health              │
│  7. Create promotion MR (if dev/stage)  │  ← Auto-promotion
└─────────────────────────────────────────┘
```

## Tasks

### Task 1: Simplify k8s-deployments Jenkinsfile

**File:** `k8s-deployments/Jenkinsfile`

**Changes:**

1. Remove the `WORKFLOW` detection logic and MR_EVENT parameters
2. Remove the VALIDATE workflow stage (calls non-existent job)
3. Remove the DEPLOY workflow stage (never triggers)
4. Keep BRANCH_INDEX logic as the main pipeline
5. Add environment branch detection after manifest generation
6. Move ArgoCD refresh/wait logic into conditional stage
7. Move promotion MR creation into conditional stage

**New structure:**

```groovy
pipeline {
    // ... agent, options, environment ...
    
    stages {
        stage('Validate & Generate Manifests') {
            steps {
                // Validate CUE configuration
                // Generate manifests
                // Commit and push manifests back to branch
            }
        }
        
        stage('Deploy to Environment') {
            when {
                expression { env.BRANCH_NAME in ['dev', 'stage', 'prod'] }
            }
            steps {
                // Login to ArgoCD
                // Refresh ArgoCD app for this environment
                // Wait for sync + health
            }
        }
        
        stage('Create Promotion MR') {
            when {
                expression { env.BRANCH_NAME in ['dev', 'stage'] }
            }
            steps {
                // Create MR to next environment
                // dev → stage, stage → prod
            }
        }
    }
}
```

**Remove:**
- `params.MR_IID`, `params.MR_EVENT`, `params.SOURCE_BRANCH`, `params.TARGET_BRANCH`
- `env.WORKFLOW` detection logic
- `stage('Detect Workflow')`
- `stage('Branch Indexing Workflow')` - logic moves to main flow
- `stage('Validation Workflow')` - broken, remove entirely
- `stage('Deployment Workflow')` - logic moves to conditional stages
- `stage('Cleanup Workflow')` - no longer needed

**Keep/Adapt:**
- `refreshArgoCDApps()` helper function
- `waitForArgoCDSync()` helper function
- `createPromotionMR()` helper function - adapt to use BRANCH_NAME for source env
- Git credentials handling
- ArgoCD login logic

---

### Task 2: Update validate-pipeline.sh for Auto-Promotion

**File:** `scripts/test/validate-pipeline.sh`

**Changes:**

1. Remove `trigger_promotion_job()` function calls
2. Remove `wait_for_promotion_job()` function
3. Add `wait_for_promotion_mr()` function that waits for auto-created MR
4. Update promotion flow to wait for MR instead of triggering job

**Before:**
```bash
# Stage promotion
trigger_promotion_job "dev" "stage"
wait_for_promotion_job
merge_env_mr "stage"
```

**After:**
```bash
# Stage promotion (MR auto-created by k8s-deployments CI)
wait_for_promotion_mr "stage"
merge_env_mr "stage"
```

**New function:**
```bash
wait_for_promotion_mr() {
    local target_env="$1"
    local timeout="${PROMOTION_MR_TIMEOUT:-120}"
    
    # Wait for MR targeting $target_env to appear
    # MR is created by k8s-deployments CI after successful deployment
    # Branch pattern: promote-{target_env}-* (created from source env)
}
```

**Functions to remove:**
- `get_jenkins_crumb()` - only used for promotion job
- `trigger_promotion_job()` - no longer needed
- `wait_for_promotion_job()` - no longer needed

**Functions to keep:**
- `merge_env_mr()` - still needed to merge auto-created MRs
- All other existing functions

---

### Task 3: Fix Test Library for Branch Builds

**File:** `scripts/test/lib/k8s-deployments-tests.sh`

**Changes:**

1. Replace `wait_for_jenkins_validation()` with `wait_for_branch_build()`
2. Update function to query MultiBranch Pipeline branch job
3. Update all test cases to use new function

**Before:**
```bash
wait_for_jenkins_validation() {
    # Queried: /job/${K8S_DEPLOYMENTS_VALIDATION_JOB}/lastBuild/api/json
    # K8S_DEPLOYMENTS_VALIDATION_JOB doesn't exist!
}
```

**After:**
```bash
wait_for_branch_build() {
    local branch="$1"
    local timeout="${2:-${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-300}}"
    
    local job_path="job/k8s-deployments/job/${branch}"
    
    # Get last build number before we started
    # Poll until new build appears and completes
    # Return success/failure based on build result
}
```

**Test case updates:**

Each test case currently calls `wait_for_jenkins_validation`. Update to:
```bash
# After pushing branch
wait_for_branch_build "${branch}" || { cleanup_test ...; return 1; }

# After merging to environment branch
wait_for_branch_build "${target_env}" || { cleanup_test ...; return 1; }
```

---

### Task 4: Update validate-k8s-deployments-pipeline.sh

**File:** `scripts/test/validate-k8s-deployments-pipeline.sh`

**Changes:**

1. Remove reference to `K8S_DEPLOYMENTS_VALIDATION_JOB`
2. Update to use `wait_for_branch_build()` from test library
3. Verify test flow works with simplified pipeline

**Minimal changes expected** - most logic is in the test library.

---

### Task 5: Update config/infra.env

**File:** `config/infra.env`

**Changes:**

Add timeout configuration:
```bash
# k8s-deployments Pipeline Configuration
K8S_DEPLOYMENTS_BUILD_TIMEOUT="${K8S_DEPLOYMENTS_BUILD_TIMEOUT:-300}"
PROMOTION_MR_TIMEOUT="${PROMOTION_MR_TIMEOUT:-120}"
```

**No need to add:**
- `K8S_DEPLOYMENTS_VALIDATION_JOB` - not needed with simplified approach

---

## Implementation Order

1. **Task 1: Jenkinsfile** - Create simplified pipeline on a test branch first
2. **Task 2: validate-pipeline.sh** - Adapt to auto-promotion
3. **Task 3: Test library** - Fix wait_for_branch_build()
4. **Task 4: validate-k8s-deployments-pipeline.sh** - Should work with fixed library
5. **Task 5: config/infra.env** - Add timeout configs

## Testing Strategy

1. After Task 1: Manually verify k8s-deployments builds work on feature and environment branches
2. After Task 2: Run `validate-pipeline.sh` end-to-end
3. After Task 3-4: Run `validate-k8s-deployments-pipeline.sh --test=T1` (single test)
4. Final: Run both validation scripts successfully

## Rollback Plan

- Keep `promote-environment` job intact as manual fallback
- If auto-promotion fails, can manually trigger promotion job
- Jenkinsfile changes can be reverted via git

## Files Changed Summary

| File | Action |
|------|--------|
| `k8s-deployments/Jenkinsfile` | Major refactor - simplify workflows |
| `scripts/test/validate-pipeline.sh` | Moderate - remove promotion job triggers |
| `scripts/test/lib/k8s-deployments-tests.sh` | Moderate - fix wait function |
| `scripts/test/validate-k8s-deployments-pipeline.sh` | Minor - use updated library |
| `config/infra.env` | Minor - add timeout configs |

## Success Criteria

1. `validate-pipeline.sh` completes successfully (full example-app → prod flow)
2. `validate-k8s-deployments-pipeline.sh` completes at least one test (T1)
3. No broken code paths in k8s-deployments Jenkinsfile
4. Pre-merge validation still blocks MR merge on failure (GitLab commit status)
