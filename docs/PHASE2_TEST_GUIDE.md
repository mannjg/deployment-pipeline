# Phase 2 Testing Guide

**Date:** 2025-11-04
**Test:** Automatic deployment config synchronization

---

## Test Scenario

We've committed changes that test the automatic sync functionality:

**Commit:** `1dab04e` - "test: Add Redis configuration for caching (testing sync)"

**Changes Made:**
1. **Code change**: Added TODO comment for Redis caching in `GreetingService.java`
2. **Config change**: Added Redis environment variables in `deployment/app.cue`:
   - `REDIS_URL`: redis://redis.cache.svc.cluster.local:6379
   - `REDIS_TIMEOUT_SECONDS`: 5
3. **Format fix**: Updated `deployment/app.cue` to match current architecture

This simulates the real-world scenario where a developer adds a feature requiring infrastructure changes.

---

## How to Trigger the Build

### Option 1: Manual Trigger via Jenkins UI (Recommended)

1. Open Jenkins UI: `http://jenkins.local`
2. Navigate to the `example-app-ci` job
3. Click "Build Now"
4. Wait for build to start

### Option 2: Trigger via Script

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
./scripts/trigger-build.sh
```

### Option 3: Push to Local GitLab (if configured)

```bash
# Add local GitLab remote if not already configured
git remote add gitlab http://gitlab.local/example/example-app.git

# Push to trigger webhook
git push gitlab main
```

---

## What to Monitor

### Step 1: Jenkins Console Output

Open the build console output and watch for these key sections:

#### 🔍 **Sync Operation Section** (New!)

Look for this section around line ~50-80 in console output:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Syncing deployment configuration...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Source: /workspace/deployment/app.cue
Target: services/apps/example-app.cue

Validating synced configuration...
✓ Synced configuration is valid

Configuration changes:
  Deployment configuration updated:
  +       name: "REDIS_URL"
  +       value: "redis://redis.cache.svc.cluster.local:6379"
  +   },
  +   {
  +       name: "REDIS_TIMEOUT_SECONDS"
  +       value: "5"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Expected:**
- ✅ Source and target paths shown
- ✅ CUE validation passes
- ✅ Diff shows the new Redis environment variables
- ❌ If validation fails, build should stop here

#### 🔍 **Image Update Section**

```
Updated image in envs/dev.cue:
image: "docker.local/example/example-app:1.0.0-SNAPSHOT-XXXXXXX"
```

**Expected:**
- ✅ Image tag includes git commit hash
- ✅ Uses docker.local (external registry for kubelets)

#### 🔍 **Manifest Generation Section**

```
Generating manifests for environment: dev
Exporting resources: configmap debugService deployment service
Successfully generated manifests/dev/example-app.yaml
Resources: configmap debugService deployment service
```

**Expected:**
- ✅ All resources exported successfully
- ✅ No CUE errors
- ❌ If generation fails, check for CUE syntax errors

#### 🔍 **Git Commit Section**

```
[update-dev-1.0.0-SNAPSHOT-XXXXXXX YYYYYYY] Update example-app to 1.0.0-SNAPSHOT-XXXXXXX

Automated deployment update from application CI/CD pipeline.

Changes:
- Synced services/apps/example-app.cue from source repository
- Updated dev environment image to 1.0.0-SNAPSHOT-XXXXXXX
- Regenerated Kubernetes manifests
```

**Expected:**
- ✅ Commit message mentions sync operation
- ✅ Three types of changes listed
- ✅ Build and git metadata included

#### 🔍 **MR Creation Section**

```
Creating GitLab Merge Request...
✓ Merge Request created successfully
MR IID: !XX
MR URL: http://gitlab.local/example/k8s-deployments/-/merge_requests/XX
```

**Expected:**
- ✅ MR created successfully
- ✅ MR URL provided

---

### Step 2: Check k8s-deployments Merge Request

1. Open the MR URL from Jenkins console output
2. Navigate to "Changes" tab

#### Expected Files Changed:

**✅ 1. services/apps/example-app.cue** (synced from app repo)
```diff
+ {
+     name: "REDIS_URL"
+     value: "redis://redis.cache.svc.cluster.local:6379"
+ },
+ {
+     name: "REDIS_TIMEOUT_SECONDS"
+     value: "5"
+ },
```

**✅ 2. envs/dev.cue** (image updated)
```diff
- image: "docker.local/example/example-app:1.0.0-SNAPSHOT-old123"
+ image: "docker.local/example/example-app:1.0.0-SNAPSHOT-new456"
```

**✅ 3. manifests/dev/example-app.yaml** (regenerated)
```diff
  env:
  - name: QUARKUS_HTTP_PORT
    value: "8080"
  - name: QUARKUS_LOG_CONSOLE_ENABLE
    value: "true"
+ - name: REDIS_URL
+   value: redis://redis.cache.svc.cluster.local:6379
+ - name: REDIS_TIMEOUT_SECONDS
+   value: "5"
```

**Expected:**
- ✅ All three files show changes
- ✅ **services/apps/example-app.cue exists and has Redis vars**
- ✅ Manifest includes new environment variables
- ✅ No syntax errors or validation failures

---

### Step 3: Verify Manifest Content

Click on `manifests/dev/example-app.yaml` in the MR and verify:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-app
  namespace: dev
spec:
  template:
    spec:
      containers:
      - name: example-app
        image: docker.local/example/example-app:1.0.0-SNAPSHOT-XXXXXXX
        env:
        - name: QUARKUS_HTTP_PORT
          value: "8080"
        - name: QUARKUS_LOG_CONSOLE_ENABLE
          value: "true"
        - name: REDIS_URL                           # ← NEW!
          value: redis://redis.cache.svc.cluster.local:6379
        - name: REDIS_TIMEOUT_SECONDS               # ← NEW!
          value: "5"
        - name: ENVIRONMENT
          value: dev
```

**Expected:**
- ✅ REDIS environment variables present
- ✅ Correct image tag
- ✅ Valid Kubernetes YAML

---

### Step 4: Merge and Verify Deployment

1. **Review the MR**
   - Check all three files have correct changes
   - Verify commit message is descriptive

2. **Merge the MR**
   - Click "Merge" button in GitLab

3. **Watch ArgoCD**
   ```bash
   # Check ArgoCD app status
   argocd app get example-app-dev

   # Watch for sync
   argocd app sync example-app-dev
   ```

4. **Verify Pod has new environment variables**
   ```bash
   # Get pod name
   kubectl get pods -n dev

   # Check environment variables
   kubectl exec -n dev <pod-name> -- env | grep REDIS
   ```

**Expected Output:**
```
REDIS_URL=redis://redis.cache.svc.cluster.local:6379
REDIS_TIMEOUT_SECONDS=5
```

---

## Success Criteria

### ✅ Phase 2 Test Passes If:

1. **Sync Operation:**
   - [  ] Jenkins console shows sync operation section
   - [  ] Synced file validates successfully with CUE
   - [  ] Diff shows the new environment variables

2. **MR Contents:**
   - [  ] MR contains services/apps/example-app.cue (synced)
   - [  ] services/apps/example-app.cue has Redis variables
   - [  ] envs/dev.cue has updated image tag
   - [  ] manifests/dev/example-app.yaml regenerated correctly

3. **Manifest Quality:**
   - [  ] Generated manifest has Redis environment variables
   - [  ] No CUE syntax errors
   - [  ] No Kubernetes validation errors

4. **Deployment:**
   - [  ] MR merges successfully
   - [  ] ArgoCD syncs without errors
   - [  ] Pod has new environment variables
   - [  ] Application still responds to requests

---

## Troubleshooting

### Issue: Sync section not in console output

**Problem:** Jenkins console doesn't show the sync operation section

**Possible Causes:**
1. Using old Jenkinsfile (before sync logic)
2. Build failed before reaching sync stage
3. workspace/deployment/app.cue not found

**Solutions:**
```bash
# Verify Jenkinsfile has sync logic
git log --oneline Jenkinsfile | head -5

# Check if changes were pushed
git log --oneline -3

# Verify app.cue exists
ls -la example-app/deployment/app.cue
```

### Issue: CUE validation fails

**Problem:** "✗ ERROR: Synced configuration validation failed!"

**Possible Causes:**
1. Invalid CUE syntax in deployment/app.cue
2. Missing imports
3. Schema mismatch

**Solutions:**
```bash
# Validate locally
cd k8s-deployments
cue vet -c=false ../example-app/deployment/app.cue

# Check format matches
diff services/apps/example-app.cue ../example-app/deployment/app.cue
```

### Issue: Manifest generation fails

**Problem:** generate-manifests.sh fails

**Possible Causes:**
1. CUE syntax error in merged configuration
2. Missing required fields
3. Import resolution issues

**Solutions:**
```bash
# Test manifest generation locally
cd k8s-deployments
./scripts/generate-manifests.sh dev

# Validate CUE config
./scripts/validate-cue-config.sh

# Check for errors
./scripts/test-cue-integration.sh --env dev
```

### Issue: services/apps/example-app.cue not in MR

**Problem:** MR doesn't contain the synced file

**Possible Causes:**
1. Sync operation failed silently
2. Git add command didn't include it
3. File was skipped due to .gitignore

**Solutions:**
```bash
# Check Jenkinsfile git add command (should include services/apps/)
grep "git add" Jenkinsfile | grep services

# Verify not in .gitignore
cat k8s-deployments/.gitignore | grep services
```

### Issue: Environment variables not in manifest

**Problem:** Generated manifest doesn't include Redis vars

**Possible Causes:**
1. Sync didn't happen (services/apps/example-app.cue not updated)
2. Environment config doesn't merge app config correctly
3. Manifest generator issue

**Solutions:**
```bash
# Check if app config has the vars
cat k8s-deployments/services/apps/example-app.cue | grep REDIS

# Test CUE merge manually
cd k8s-deployments
cue export ./envs/dev.cue -e dev.exampleApp.appEnvVars

# Regenerate manifests
./scripts/generate-manifests.sh dev
cat manifests/dev/example-app.yaml | grep -A2 REDIS
```

---

## Test Variations

After the base test passes, try these scenarios:

### Variation 1: Invalid CUE Syntax

Test that validation catches errors:

```bash
# Introduce syntax error
echo '{ invalid cue }' >> example-app/deployment/app.cue
git add example-app/deployment/app.cue
git commit -m "test: Invalid CUE (should fail)"
git push

# Expected: Build should fail at validation step
```

### Variation 2: No deployment/app.cue

Test graceful handling:

```bash
# Temporarily remove file
mv example-app/deployment/app.cue example-app/deployment/app.cue.bak
git add example-app/deployment/
git commit -m "test: No config file (should warn)"
git push

# Expected: Build should warn but continue
# Restore file after test
mv example-app/deployment/app.cue.bak example-app/deployment/app.cue
```

### Variation 3: Multiple Config Changes

Test with multiple environment variables:

```bash
# Add several env vars
# Commit and push
# Verify all appear in manifest
```

---

## Next Steps After Successful Test

Once Phase 2 testing passes:

1. **Document Results**
   - Update IMPLEMENTATION_STATUS.md
   - Mark Phase 2 as "tested and working"
   - Document any issues found and resolved

2. **Proceed to Phase 3**
   - Implement k8s-deployments validation pipeline
   - Add webhook for infrastructure changes
   - Set up pre-merge validation

3. **Rollout Planning**
   - Communicate changes to team
   - Schedule training session
   - Plan for additional applications

---

## Test Results

**Date:** ___________
**Tester:** ___________

### Checklist:

- [  ] Jenkins build triggered successfully
- [  ] Sync operation visible in console output
- [  ] CUE validation passed
- [  ] services/apps/example-app.cue synced to MR
- [  ] envs/dev.cue updated with new image
- [  ] manifests/dev/example-app.yaml regenerated
- [  ] Manifest contains Redis environment variables
- [  ] MR merged successfully
- [  ] ArgoCD synced without errors
- [  ] Pod has new environment variables

**Overall Result:** ☐ PASS  ☐ FAIL  ☐ PARTIAL

**Notes:**
_____________________________________________
_____________________________________________
_____________________________________________

---

**Created:** 2025-11-04
**Version:** 1.0
