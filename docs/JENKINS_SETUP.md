# Jenkins Job Configuration for k8s-deployments Pipeline

This document provides step-by-step instructions for configuring Jenkins to use the k8s-deployments CI/CD pipeline.

## Prerequisites

- Jenkins installed and accessible
- GitLab instance with k8s-deployments repository
- ArgoCD installed and configured
- Jenkins agent with:
  - `cue` CLI tool
  - `argocd` CLI tool
  - `kubectl` CLI tool
  - `jq` for JSON processing

## Overview

The k8s-deployments pipeline consists of three main workflows:

1. **Validation Workflow**: Triggered on MR open/update - validates CUE config and manifests
2. **Deployment Workflow**: Triggered on MR merge - refreshes ArgoCD apps and promotes
3. **Cleanup Workflow**: Triggered on MR close - performs housekeeping

---

## Step 1: Create Jenkins Credentials

### 1.1 GitLab Credentials (Username/Password)

Create credential with ID: `gitlab-credentials`

```
Kind: Username with password
ID: gitlab-credentials
Username: <gitlab-username>
Password: <gitlab-password or personal access token>
Description: GitLab credentials for git operations
```

### 1.2 GitLab API Token (Secret Text)

Create credential with ID: `gitlab-api-token-secret`

```
Kind: Secret text
ID: gitlab-api-token-secret
Secret: <gitlab-api-token>
Description: GitLab API token for MR operations
Scope: Global
```

**Token Permissions Required:**
- `api` - Full API access
- `read_repository` - Read repository
- `write_repository` - Write to repository

### 1.3 ArgoCD Credentials (Username/Password)

Create credential with ID: `argocd-credentials`

```
Kind: Username with password
ID: argocd-credentials
Username: admin (or your ArgoCD username)
Password: <argocd-password>
Description: ArgoCD credentials for app management
```

---

## Step 2: Create Jenkins Jobs

### 2.1 Main Pipeline Job: `k8s-deployments-main`

#### Basic Settings

1. **Job Type**: Pipeline
2. **Job Name**: `k8s-deployments-main`
3. **Description**:
   ```
   Main orchestration pipeline for k8s-deployments.
   Handles MR validation, deployment, and promotion workflows.
   ```

#### Build Triggers

Enable: **Generic Webhook Trigger**

**Configuration:**
```groovy
Token: k8s-deployments-webhook-token

Post content parameters:
- Variable: MR_IID
  Expression: $.object_attributes.iid

- Variable: MR_EVENT
  Expression: $.object_attributes.action

- Variable: SOURCE_BRANCH
  Expression: $.object_attributes.source_branch

- Variable: TARGET_BRANCH
  Expression: $.object_attributes.target_branch

Optional filter:
  Text: $object_kind
  Expression: ^merge_request$
```

#### Pipeline Configuration

**Definition**: Pipeline script from SCM

**SCM**: Git
- Repository URL: `http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git`
- Credentials: `gitlab-credentials`
- Branch Specifier: `*/main` (or your default branch)
- Script Path: `Jenkinsfile`

**Advanced Options**:
- Lightweight checkout: ✅ Enabled
- Shallow clone: ✅ Enabled (depth: 1)

---

### 2.2 Validation Pipeline Job: `k8s-deployments-validation`

This job should already exist (from `jenkins/k8s-deployments-validation.Jenkinsfile`).

If not, create it:

#### Basic Settings

1. **Job Type**: Pipeline
2. **Job Name**: `k8s-deployments-validation`
3. **Description**: Validates CUE configuration and manifests

#### Parameters

Add parameters:
- `BRANCH_NAME` (String, default: `dev`)
- `VALIDATE_ALL_ENVS` (Boolean, default: `true`)

#### Pipeline Configuration

**Definition**: Pipeline script from SCM

**SCM**: Git
- Repository URL: `http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git`
- Credentials: `gitlab-credentials`
- Branch Specifier: `*/${BRANCH_NAME}`
- Script Path: `jenkins/k8s-deployments-validation.Jenkinsfile`

---

## Step 3: Configure GitLab Webhook

### 3.1 Navigate to GitLab Webhook Settings

1. Go to k8s-deployments repository in GitLab
2. Settings → Webhooks

### 3.2 Add Webhook

**URL:**
```
http://jenkins.jenkins.svc.cluster.local/generic-webhook-trigger/invoke?token=k8s-deployments-webhook-token
```

**Secret Token:** (optional, recommended)
```
<your-webhook-secret>
```

**Trigger Events:**
- ✅ Merge request events
- ✅ Push events (for environment branches)

**SSL Verification:**
- Depends on your setup (disable for internal clusters)

**Branch Filter:**
Leave empty to trigger on all branches, or specify:
```
^(dev|stage|prod|feature/.*)$
```

### 3.3 Test Webhook

1. Click "Test" → "Merge Request Events"
2. Check Jenkins job was triggered
3. Review Jenkins console output

---

## Step 4: Verify Pipeline Integration

### 4.1 Test Validation Workflow

1. Create a test branch:
   ```bash
   git checkout -b test-pipeline-validation
   ```

2. Make a small change to a CUE file:
   ```bash
   echo "# Pipeline test" >> envs/dev.cue
   git add envs/dev.cue
   git commit -m "test: Verify pipeline validation"
   git push -u origin test-pipeline-validation
   ```

3. Create MR in GitLab:
   - Source: `test-pipeline-validation`
   - Target: `dev`

4. Verify:
   - ✅ Jenkins job `k8s-deployments-main` triggered
   - ✅ Validation workflow executed
   - ✅ GitLab commit status updated
   - ✅ MR comment posted with results

### 4.2 Test Deployment Workflow

1. Merge the test MR to `dev`

2. Verify:
   - ✅ Deployment workflow triggered
   - ✅ ArgoCD apps refreshed
   - ✅ Apps synced and healthy
   - ✅ Promotion MR created to `stage`

### 4.3 Test Full Promotion Cycle

1. Review and merge the auto-generated stage promotion MR

2. Verify:
   - ✅ Stage deployment successful
   - ✅ Promotion MR created to `prod`

3. Review and merge prod promotion MR

4. Verify:
   - ✅ Prod deployment successful
   - ✅ No promotion MR created (prod is final)

---

## Step 5: Configure ArgoCD Access (if needed)

If ArgoCD is not accessible from Jenkins, configure:

### Option A: ArgoCD Service Account

Create a service account for Jenkins:

```bash
kubectl create serviceaccount argocd-jenkins -n argocd

# Create role with app management permissions
kubectl create role argocd-jenkins-role \
  --verb=get,list,update,patch \
  --resource=applications \
  -n argocd

kubectl create rolebinding argocd-jenkins-binding \
  --role=argocd-jenkins-role \
  --serviceaccount=argocd:argocd-jenkins \
  -n argocd
```

Get token:
```bash
kubectl create token argocd-jenkins -n argocd --duration=8760h
```

### Option B: ArgoCD Admin Password

Get ArgoCD admin password:
```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Troubleshooting

### Issue: Pipeline not triggering

**Check:**
1. GitLab webhook configured correctly
2. Webhook URL accessible from GitLab
3. Jenkins job exists and is enabled
4. Webhook token matches

**Debug:**
```bash
# Check GitLab webhook logs
# Settings → Webhooks → Recent Deliveries

# Check Jenkins webhook logs
# Jenkins → Manage Jenkins → System Log
```

### Issue: ArgoCD login fails

**Check:**
1. ArgoCD credentials in Jenkins
2. ArgoCD server URL correct
3. Network connectivity from Jenkins to ArgoCD

**Debug:**
```bash
# Test ArgoCD login manually from Jenkins agent
argocd login argocd-server.argocd.svc.cluster.local:80 \
  --username admin \
  --password <password> \
  --plaintext --grpc-web
```

### Issue: CUE validation fails

**Check:**
1. CUE CLI installed in Jenkins agent
2. CUE version compatible with configs
3. All CUE imports resolvable

**Debug:**
```bash
# Test CUE export locally
cue export ./envs/dev.cue -e dev --out json
```

### Issue: Manifest generation fails

**Check:**
1. All required scripts exist in `scripts/` directory
2. Scripts have execute permissions
3. Environment CUE files are valid

**Debug:**
```bash
# Test manifest generation manually
./scripts/generate-manifests.sh dev
```

---

## Advanced Configuration

### Customize Timeout Values

Edit `Jenkinsfile` timeout settings:

```groovy
options {
    timeout(time: 45, unit: 'MINUTES')  // Adjust as needed
}
```

### Disable Auto-Promotion

Set pipeline parameter:

```groovy
parameters {
    booleanParam(
        name: 'CREATE_PROMOTION_MR',
        defaultValue: false,  // Change to false
        description: 'Automatically create promotion MR'
    )
}
```

### Configure Notification Channels

Add notification stages to `Jenkinsfile`:

```groovy
post {
    success {
        // Send Slack notification
        slackSend(
            color: 'good',
            message: "Pipeline succeeded: ${env.BUILD_URL}"
        )
    }
}
```

---

## Security Best Practices

1. **Credential Rotation**
   - Rotate GitLab tokens quarterly
   - Rotate ArgoCD passwords quarterly
   - Use short-lived tokens where possible

2. **Access Control**
   - Limit Jenkins job permissions
   - Use least-privilege service accounts
   - Review audit logs regularly

3. **Webhook Security**
   - Use secret tokens for webhooks
   - Enable SSL verification in production
   - Whitelist GitLab IP ranges

4. **Pipeline Security**
   - Review Jenkinsfile changes
   - Validate scripts before execution
   - Avoid hardcoded credentials

---

## Maintenance

### Regular Tasks

- **Weekly**: Review pipeline execution logs
- **Monthly**: Update Jenkins plugins
- **Quarterly**: Review and update credentials
- **Annually**: Audit pipeline security

### Monitoring

Set up alerts for:
- Pipeline failures
- Long-running builds
- ArgoCD sync failures
- Credential expiration

---

## References

- [Jenkins Pipeline Syntax](https://www.jenkins.io/doc/book/pipeline/syntax/)
- [GitLab Webhooks Documentation](https://docs.gitlab.com/ee/user/project/integrations/webhooks.html)
- [ArgoCD CLI Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd/)
- [CUE Language Specification](https://cuelang.org/docs/)

---

## Support

For issues or questions:
1. Check Jenkins console output
2. Review GitLab webhook delivery logs
3. Check ArgoCD application status
4. Consult team documentation
5. Create issue in k8s-deployments repository

---

**Last Updated**: 2025-11-06
**Maintained By**: DevOps Team
