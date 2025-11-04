# E2E Pipeline Integration Test

Complete end-to-end integration test that validates the entire deployment pipeline from source code commit through production deployment, including GitLab merge request workflows and ArgoCD synchronization.

## Overview

This test suite exercises the **complete** pipeline workflow:

```
Source Code → Jenkins Build → Dev Deployment →
MR (dev→stage) → Stage Deployment →
MR (stage→prod) → Production Deployment
```

### What It Tests

1. **Source Code Management**: Creating commits, pushing branches, managing merge requests
2. **CI/CD Pipeline**: Triggering Jenkins builds, monitoring build status
3. **GitOps Deployment**: ArgoCD application sync and health monitoring
4. **Environment Promotion**: Merge request workflow with approvals
5. **Deployment Verification**: Kubernetes resource health across all environments
6. **End-to-End Consistency**: Verifying same version deployed across all environments

## Test Stages

The test is broken into 6 sequential stages:

### Stage 1: Trigger Build
- Creates a feature branch with test commit
- Merges to dev branch
- Triggers Jenkins build
- Waits for build completion
- **Duration**: ~5-10 minutes

### Stage 2: Verify Dev
- Checks ArgoCD application sync status
- Verifies Kubernetes deployment health
- Validates pod readiness
- Checks for errors/warnings
- **Duration**: ~2-5 minutes

### Stage 3: Promote to Stage
- Creates merge request: dev → stage
- Approves MR (if required)
- Merges MR
- Waits for merge completion
- **Duration**: ~1-2 minutes

### Stage 4: Verify Stage
- Checks ArgoCD application sync status
- Verifies Kubernetes deployment health
- Validates consistency with dev
- **Duration**: ~2-5 minutes

### Stage 5: Promote to Production
- Creates merge request: stage → prod
- Approves MR (if required)
- Optional safety wait
- Merges MR
- **Duration**: ~1-2 minutes

### Stage 6: Verify Production
- Checks ArgoCD application sync status
- Verifies Kubernetes deployment health
- Validates consistency across all environments
- Checks production-specific configurations
- **Duration**: ~2-5 minutes

**Total Duration**: ~15-25 minutes (varies based on build time and ArgoCD sync speed)

## Prerequisites

### 1. Access Credentials

You need API tokens for:

**Jenkins**:
- Create at: Jenkins → User → Configure → API Token
- Required permissions: Job read, build

**GitLab**:
- Create at: GitLab → User Settings → Access Tokens
- Required scopes: `api`, `read_repository`, `write_repository`

### 2. Environment Setup

The following must be operational:
- ✓ Kubernetes cluster accessible
- ✓ ArgoCD installed and configured
- ✓ Jenkins accessible with configured job
- ✓ GitLab accessible
- ✓ Git remote configured correctly
- ✓ All three environments (dev, stage, prod) deployed

### 3. Branch Structure

Your repository should have:
- `dev` branch (or configured DEV_BRANCH)
- `stage` branch (or configured STAGE_BRANCH)
- `main` or `master` branch (or configured PROD_BRANCH)

## Configuration

### 1. Copy Configuration Template

```bash
cd tests/e2e/config
cp e2e-config.template.sh e2e-config.sh
```

### 2. Edit Configuration

Edit `e2e-config.sh` and set required values:

```bash
# Required Jenkins settings
export JENKINS_URL="http://jenkins.jenkins.svc.cluster.local"
export JENKINS_USER="admin"
export JENKINS_TOKEN="your-jenkins-api-token-here"
export JENKINS_JOB_NAME="example-app-build"

# Required GitLab settings
export GITLAB_URL="http://gitlab.gitlab.svc.cluster.local"
export GITLAB_TOKEN="your-gitlab-token-here"

# Branch names (adjust if different)
export DEV_BRANCH="dev"
export STAGE_BRANCH="stage"
export PROD_BRANCH="main"

# Application names
export APP_NAME="example-app"
export DEPLOYMENT_NAME="example-app"
export ARGOCD_APP_PREFIX="example-app"
```

### 3. Secure Your Configuration

```bash
# Ensure config file is not committed
chmod 600 e2e-config.sh
echo "tests/e2e/config/e2e-config.sh" >> .gitignore
```

## Usage

### Basic Usage

Run the complete E2E test:

```bash
cd tests/e2e
./test-full-pipeline.sh
```

### Advanced Options

```bash
# Show help
./test-full-pipeline.sh --help

# Run with verbose output
./test-full-pipeline.sh --verbose

# Keep test artifacts even on success
./test-full-pipeline.sh --no-cleanup

# Continue on failures (for debugging)
./test-full-pipeline.sh --continue-on-failure

# Run specific stages only
./test-full-pipeline.sh --start 1 --end 4  # Up to stage verification

# Run single stage
./test-full-pipeline.sh --stage 3  # Only promote to stage

# Different cleanup modes
./test-full-pipeline.sh --cleanup always     # Always clean up
./test-full-pipeline.sh --cleanup on-success # Clean up only if all pass
./test-full-pipeline.sh --cleanup on-failure # Clean up only if any fail
./test-full-pipeline.sh --cleanup never      # Never clean up
```

### Running Individual Stages

You can run stages independently (useful for debugging):

```bash
# Ensure state directory exists from previous run
export E2E_STATE_DIR="/path/to/state/dir"

# Run specific stage
cd stages
./01-trigger-build.sh
./02-verify-dev.sh
# ... etc
```

## Understanding Results

### Success Output

```
==========================================
  E2E PIPELINE TEST SUMMARY
==========================================

Stages Run: 6
Stages Passed: 6
Stages Failed: 0

Total Duration: 18 minutes 32 seconds

✓ ALL STAGES PASSED

Test artifacts location: /path/to/state/20250104-143022
```

### Failure Output

```
==========================================
  E2E PIPELINE TEST SUMMARY
==========================================

Stages Run: 4
Stages Passed: 3
Stages Failed: 1

Total Duration: 12 minutes 15 seconds

✗ SOME STAGES FAILED

Test artifacts location: /path/to/state/20250104-143022
```

### Test Artifacts

When tests fail, artifacts are preserved in the state directory:

```
state/20250104-143022/
├── test_start_timestamp.txt      # Test start time
├── feature_branch.txt             # Created feature branch name
├── commit_sha.txt                 # Test commit SHA
├── dev_commit_sha.txt             # Dev branch commit
├── build_number.txt               # Jenkins build number
├── build_status.txt               # Build result
├── stage_mr_iid.txt              # Stage MR number
├── stage_commit_sha.txt          # Stage branch commit
├── prod_mr_iid.txt               # Prod MR number
├── prod_commit_sha.txt           # Prod branch commit
└── total_duration.txt            # Total test time
```

## Troubleshooting

### Jenkins Build Fails

**Symptoms**: Stage 1 fails during build

**Check**:
```bash
# View last 50 lines of build console
export JENKINS_URL="..."
export JENKINS_USER="..."
export JENKINS_TOKEN="..."
./lib/jenkins-api.sh
get_build_console_output "job-name" "build-number" 50
```

**Common Causes**:
- Build configuration issues
- Missing dependencies
- Test failures in build
- Insufficient resources

### ArgoCD Not Syncing

**Symptoms**: Stage 2, 4, or 6 fails with "not synced"

**Check**:
```bash
microk8s kubectl get application -n argocd
microk8s kubectl describe application example-app-dev -n argocd
```

**Common Causes**:
- ArgoCD not watching correct branch
- Repository credentials expired
- Manifest generation errors
- CUE compilation failures

### Merge Request Fails

**Symptoms**: Stage 3 or 5 fails to create/merge MR

**Check**:
```bash
# Check GitLab API connectivity
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/user"

# Check MR status
curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID"
```

**Common Causes**:
- Merge conflicts
- Protected branch rules
- Insufficient permissions
- Required approvals not met

### Deployment Not Healthy

**Symptoms**: Pods not ready, deployment failing

**Check**:
```bash
# Check pod status
microk8s kubectl get pods -n dev -l app=example-app

# Check pod logs
microk8s kubectl logs -n dev -l app=example-app --tail=50

# Check events
microk8s kubectl get events -n dev --sort-by='.lastTimestamp'
```

**Common Causes**:
- Image pull failures
- Configuration errors
- Resource constraints
- Health check failures

### Timeout Issues

**Symptoms**: Stages timeout waiting for operations

**Solution**: Increase timeouts in configuration:

```bash
export JENKINS_BUILD_TIMEOUT=900      # 15 minutes
export ARGOCD_SYNC_TIMEOUT=600        # 10 minutes
export POD_READY_TIMEOUT=600          # 10 minutes
```

## Cleanup

The test automatically cleans up artifacts based on cleanup mode:

### What Gets Cleaned Up

- Feature branches (local and remote)
- Merge requests (closed, not deleted)
- Old E2E test branches (older than 1 day)

### What Stays

- Environment branches (dev, stage, prod) - **never modified**
- Committed changes - **remain in Git history**
- Deployed applications - **continue running**

### Manual Cleanup

If tests fail and artifacts are left behind:

```bash
# List E2E test branches
git branch -a | grep e2e-test-

# Delete specific branch
git branch -D e2e-test-1704380422
git push origin --delete e2e-test-1704380422

# Close specific MR
curl --request PUT \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --header "Content-Type: application/json" \
  --data '{"state_event": "close"}' \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/merge_requests/$MR_IID"

# Clean all old E2E branches (older than 1 day)
./lib/git-operations.sh
cleanup_e2e_branches 1
```

## CI/CD Integration

### GitLab CI

Add to `.gitlab-ci.yml`:

```yaml
e2e-pipeline-test:
  stage: test
  script:
    - cd k8s-deployments/tests/e2e
    - cp config/e2e-config.ci.sh config/e2e-config.sh
    - ./test-full-pipeline.sh --cleanup always
  only:
    - schedules  # Run on schedule
  tags:
    - kubernetes
```

### GitHub Actions

Add to `.github/workflows/e2e-test.yml`:

```yaml
name: E2E Pipeline Test
on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM
  workflow_dispatch:

jobs:
  e2e-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run E2E Test
        env:
          JENKINS_TOKEN: ${{ secrets.JENKINS_TOKEN }}
          GITLAB_TOKEN: ${{ secrets.GITLAB_TOKEN }}
        run: |
          cd k8s-deployments/tests/e2e
          cp config/e2e-config.ci.sh config/e2e-config.sh
          ./test-full-pipeline.sh --cleanup always
```

### Jenkins

Create a Jenkins pipeline job:

```groovy
pipeline {
    agent any
    triggers {
        cron('H 2 * * *')  // Daily at ~2 AM
    }
    stages {
        stage('E2E Test') {
            steps {
                dir('k8s-deployments/tests/e2e') {
                    sh '''
                        cp config/e2e-config.ci.sh config/e2e-config.sh
                        ./test-full-pipeline.sh --cleanup always
                    '''
                }
            }
        }
    }
}
```

## Architecture

### Test Flow Diagram

```
┌─────────────────┐
│  Test Start     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 1. Trigger Build│
│  - Create commit│
│  - Push to dev  │
│  - Start Jenkins│
│  - Wait for build
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 2. Verify Dev   │
│  - Check ArgoCD │
│  - Check K8s    │
│  - Check health │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 3. Promote Stage│
│  - Create MR    │
│  - Approve MR   │
│  - Merge MR     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 4. Verify Stage │
│  - Check ArgoCD │
│  - Check K8s    │
│  - Compare w/dev│
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 5. Promote Prod │
│  - Create MR    │
│  - Approve MR   │
│  - Safety wait  │
│  - Merge MR     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 6. Verify Prod  │
│  - Check ArgoCD │
│  - Check K8s    │
│  - Compare all  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Test Complete  │
│  - Summary      │
│  - Cleanup      │
└─────────────────┘
```

### Directory Structure

```
tests/e2e/
├── README.md                      # This file
├── test-full-pipeline.sh          # Main orchestrator
├── config/
│   ├── e2e-config.template.sh     # Configuration template
│   └── e2e-config.sh              # Your config (gitignored)
├── lib/
│   ├── gitlab-api.sh              # GitLab API wrapper
│   ├── jenkins-api.sh             # Jenkins API wrapper
│   └── git-operations.sh          # Git helper functions
├── stages/
│   ├── 01-trigger-build.sh        # Stage 1
│   ├── 02-verify-dev.sh           # Stage 2
│   ├── 03-promote-stage.sh        # Stage 3
│   ├── 04-verify-stage.sh         # Stage 4
│   ├── 05-promote-prod.sh         # Stage 5
│   └── 06-verify-prod.sh          # Stage 6
└── state/                         # Test artifacts (created at runtime)
    └── YYYYMMDD-HHMMSS/           # Timestamped state dirs
```

### Library Dependencies

The E2E test reuses existing test framework libraries:

```
tests/
├── lib/
│   ├── common.sh                  # Logging, utilities
│   ├── assertions.sh              # Test assertions
│   └── cleanup.sh                 # Cleanup functions
└── e2e/
    └── lib/
        ├── gitlab-api.sh          # E2E specific
        ├── jenkins-api.sh         # E2E specific
        └── git-operations.sh      # E2E specific
```

## Security Considerations

1. **API Tokens**: Store securely, never commit to repository
2. **Cleanup**: Always clean up test branches and MRs
3. **Production Safety**: Production merges have additional safety checks
4. **Test Isolation**: Each test run uses unique branch names
5. **Read-only Operations**: Where possible, tests verify without modifying state

## Best Practices

1. **Run Regularly**: Schedule daily or weekly runs
2. **Monitor Duration**: Track execution time to detect slowdowns
3. **Check Artifacts**: Review state directories when tests fail
4. **Update Configuration**: Keep timeouts appropriate for your setup
5. **Version Control**: Track changes to test configuration template
6. **Document Failures**: Record common failure patterns and solutions

## FAQ

**Q: How long does the test take?**
A: Typically 15-25 minutes, depending on build time and deployment speed.

**Q: Can I run this in production?**
A: Yes, but carefully. The test actually deploys to production. Consider running against a non-production cluster first.

**Q: What if the test fails halfway?**
A: Artifacts are preserved for debugging. Use `--continue-on-failure` to see all failures.

**Q: Can I test only part of the pipeline?**
A: Yes, use `--start` and `--end` to run specific stage ranges.

**Q: Does this test actual application functionality?**
A: No, this tests the pipeline and deployment infrastructure. Add application-specific tests separately.

**Q: How do I debug a specific stage?**
A: Run that stage individually with the state directory from a previous run, and add `--verbose`.

## Contributing

To improve the E2E test suite:

1. Test additions should follow the stage pattern
2. New API integrations go in `lib/` directory
3. Configuration options go in template file
4. Update this README with new features

## Support

For issues or questions:
- Check troubleshooting section above
- Review test artifacts in state directory
- Check logs from Jenkins, GitLab, ArgoCD, Kubernetes
- Review existing test framework documentation in `tests/README.md`
