# E2E Pipeline Test - Quick Start Guide

## Prerequisites

Before running the E2E test, ensure you have:

1. ✅ Jenkins accessible with a configured build job
2. ✅ GitLab accessible with your repository
3. ✅ Kubernetes cluster running with ArgoCD installed
4. ✅ All three environments deployed (dev, stage, prod)
5. ✅ API tokens for Jenkins and GitLab

## 5-Minute Setup

### Step 1: Get Your API Tokens

**Jenkins Token**:
1. Go to Jenkins → Your User → Configure
2. Scroll to "API Token" section
3. Click "Add new Token"
4. Give it a name (e.g., "e2e-test")
5. Copy the generated token

**GitLab Token**:
1. Go to GitLab → User Settings → Access Tokens
2. Create token with scopes: `api`, `read_repository`, `write_repository`
3. Copy the generated token

### Step 2: Create Configuration

```bash
cd tests/e2e/config
cp e2e-config.template.sh e2e-config.sh
```

### Step 3: Edit Configuration

Edit `e2e-config.sh` and set these required values:

```bash
# Jenkins
export JENKINS_URL="http://jenkins.jenkins.svc.cluster.local"
export JENKINS_USER="admin"
export JENKINS_TOKEN="your-jenkins-token-here"
export JENKINS_JOB_NAME="example-app-build"

# GitLab
export GITLAB_URL="http://gitlab.gitlab.svc.cluster.local"
export GITLAB_TOKEN="your-gitlab-token-here"

# Branches (adjust if different)
export DEV_BRANCH="dev"
export STAGE_BRANCH="stage"
export PROD_BRANCH="main"

# Application
export APP_NAME="example-app"
export DEPLOYMENT_NAME="example-app"
export ARGOCD_APP_PREFIX="example-app"
```

### Step 4: Secure Configuration

```bash
chmod 600 e2e-config.sh
```

### Step 5: Run Test

```bash
cd tests/e2e
./test-full-pipeline.sh
```

## What Happens Next

The test will:

1. **Create a test commit** on dev branch
2. **Trigger Jenkins build** and wait for completion (~5-10 min)
3. **Verify dev deployment** is healthy (~2-5 min)
4. **Create MR dev→stage** and merge it (~1-2 min)
5. **Verify stage deployment** is healthy (~2-5 min)
6. **Create MR stage→prod** and merge it (~1-2 min)
7. **Verify prod deployment** is healthy (~2-5 min)

**Total time**: ~15-25 minutes

## Success Output

```
==========================================
  E2E PIPELINE TEST SUMMARY
==========================================

Stages Run: 6
Stages Passed: 6
Stages Failed: 0

Total Duration: 18 minutes 32 seconds

✓ ALL STAGES PASSED
```

## If Something Fails

1. **Check the error message** - it will tell you which stage failed
2. **Look in the state directory** - preserved when tests fail
3. **Review the troubleshooting section** in README.md
4. **Try running with verbose output**: `./test-full-pipeline.sh --verbose`

## Common Issues

### "JENKINS_TOKEN not set"
→ You forgot to set `JENKINS_TOKEN` in `e2e-config.sh`

### "GITLAB_TOKEN not set"
→ You forgot to set `GITLAB_TOKEN` in `e2e-config.sh`

### "Jenkins build failed"
→ Check your Jenkins job configuration and build logs

### "ArgoCD not syncing"
→ Check that ArgoCD is watching the correct Git branches

### "Merge request failed"
→ Check for merge conflicts or branch protection rules

## Advanced Usage

### Run specific stages only
```bash
# Run only stages 1-4
./test-full-pipeline.sh --start 1 --end 4

# Run only stage 3
./test-full-pipeline.sh --stage 3
```

### Keep test artifacts
```bash
./test-full-pipeline.sh --no-cleanup
```

### Continue on failures (for debugging)
```bash
./test-full-pipeline.sh --continue-on-failure
```

## Need Help?

1. Read the full [README.md](README.md) for detailed documentation
2. Check [E2E_TEST_IMPLEMENTATION.md](E2E_TEST_IMPLEMENTATION.md) for architecture
3. Review test artifacts in the state directory when tests fail

## Next Steps

After successful E2E test:

1. **Schedule regular runs** (daily or weekly)
2. **Add to CI/CD pipeline** (see README.md for examples)
3. **Monitor test duration** to detect slowdowns
4. **Customize timeouts** if needed for your environment

---

**Ready to test your pipeline?** Run `./test-full-pipeline.sh` now!
