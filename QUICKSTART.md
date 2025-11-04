# QuickStart: Get the Pipeline Running in 20 Minutes

Last Updated: 2025-11-02

## Current Status at a Glance

```
Infrastructure     ✅ All pods running (GitLab, Jenkins, Nexus, ArgoCD)
Code              ✅ Ready to deploy
GitLab            ✅ Projects created, code pushed
Jenkins           ✅ Credentials configured + pipeline job created
ArgoCD            ✅ Repository connected, applications deployed (Synced)
Docker Registry   ✅ Configured (HTTPS via docker.local)
Nexus Maven       ✅ Configured and working
Pipeline Test     ⚠️  Last build failed at "Update Deployment Repo" stage

COMPLETION: ~95% | TIME TO FINISH: ~5 minutes (trigger + verify build)
```

---

## Prerequisites

- All infrastructure pods running (check: `sg microk8s -c "microk8s kubectl get pods -A | grep -E 'gitlab|jenkins|nexus|argocd'"`)
- GitLab token available: `glpat-9m86y9YHyGf77Kr8bRjX`
- Access to service UIs (see [ACCESS.md](ACCESS.md))

---

## Important: GitLab URL Note

**GitLab has TWO different URLs:**
- **`http://gitlab.local`** - Use for external/host API calls and web browser
- **`http://gitlab.gitlab.svc.cluster.local`** - Use ONLY for in-cluster operations (Jenkins, ArgoCD)

---

## Step 1: Verify Configuration (Already Complete!)

### 1.1 Jenkins Configuration ✅
All Jenkins configuration is already complete:
- **Credentials:** gitlab-credentials, nexus-credentials, docker-registry-credentials (all configured)
- **Pipeline Job:** example-app-ci (created and pointing to GitLab)

**Verify:**
```bash
curl -s http://jenkins.local/api/json | \
  python3 -c "import sys, json; [print(j['name']) for j in json.load(sys.stdin)['jobs']]"
# Should show: example-app-ci
```

### 1.2 ArgoCD Configuration ✅
All ArgoCD configuration is already complete:
- **Repository:** Connected to http://gitlab.gitlab.svc.cluster.local/example/k8s-deployments.git
- **Applications:** All 3 deployed (example-app-dev, example-app-stage, example-app-prod)

**Verify:**
```bash
sg microk8s -c "microk8s kubectl get applications -n argocd"
# Should show all 3 apps with Status: Synced, Health: Healthy
```

---

## Step 2: Test the Pipeline (5 minutes)

### 2.1 Trigger Build
```bash
curl -X POST http://jenkins.local/job/example-app-ci/build
```

### 2.2 Monitor Build
```bash
# Watch build status (Ctrl+C to stop)
watch -n 2 'curl -s "http://jenkins.local/job/example-app-ci/lastBuild/api/json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(f\"Build #{d[\"number\"]}: {d[\"result\"] or \"BUILDING\"}\")"'
```

**Or view in browser:** http://jenkins.local/job/example-app-ci/lastBuild/console

### 2.3 Verify Success

**Expected Pipeline Stages:**
1. ✅ Checkout
2. ✅ Unit Tests
3. ⏭️  Integration Tests (skipped - configured)
4. ✅ Build & Publish (Docker image + Maven artifacts to Nexus)
5. ✅ Update Deployment Repo (pushes to k8s-deployments/dev)
6. ℹ️  Create Promotion MR (draft - not fully implemented)

**Check Artifacts Published:**
```bash
# Docker image in Nexus
curl -s http://nexus.local/service/rest/v1/search?repository=docker-hosted | \
  python3 -c "import sys, json; [print(i['name']) for i in json.load(sys.stdin).get('items', [])]"

# Maven artifact in Nexus
curl -s http://nexus.local/service/rest/v1/search?repository=maven-snapshots | \
  python3 -c "import sys, json; [print(i['name']) for i in json.load(sys.stdin).get('items', [])]"
```

**Check k8s-deployments Updated:**
```bash
# View latest commit on dev branch
curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "http://gitlab.local/api/v4/projects/example%2Fk8s-deployments/repository/commits?ref_name=dev" | \
  python3 -c "import sys, json; c=json.load(sys.stdin)[0]; print(f\"{c['short_id']}: {c['title']}\")"

# Should show: Update example-app to <version>-<hash>
```

**Check ArgoCD Synced:**
```bash
# Check app sync status
sg microk8s -c "microk8s kubectl get application example-app-dev -n argocd -o jsonpath='{.status.sync.status}'"
# Should show: Synced
```

**Check Application Deployed:**
```bash
# Check dev namespace
sg microk8s -c "microk8s kubectl get pods,svc -n dev"
# Should show example-app pod running
```

### 2.4 Test Application
```bash
# Port-forward to test
sg microk8s -c "microk8s kubectl port-forward -n dev svc/example-app 8080:8080" &

# Test endpoint
curl http://localhost:8080/api/greetings
# Should return: {"message":"Hello, World!"}

# Kill port-forward
pkill -f "port-forward.*example-app"
```

---

## Success! What Next?

✅ **You now have a fully working GitOps CI/CD pipeline!**

### What Just Happened

1. **Code pushed to GitLab** - Source of truth for application and deployment configs
2. **Jenkins builds on commit** - Compiles, tests, publishes Docker images + Maven artifacts
3. **GitOps workflow active** - Jenkins updates k8s-deployments/dev branch automatically
4. **ArgoCD auto-deploys** - Watches dev branch, deploys to dev namespace
5. **Application running** - Quarkus REST API live in Kubernetes

### Environment Promotion Workflow

```
Commit to main
    ↓
Jenkins builds & publishes
    ↓
Updates k8s-deployments/dev
    ↓
ArgoCD auto-syncs to dev namespace
    ↓
[Manual MR: dev → stage]
    ↓
ArgoCD syncs to stage namespace
    ↓
[Manual MR: stage → prod]
    ↓
ArgoCD syncs to prod namespace
```

### Next Steps

1. **Enable GitLab Webhooks** - Auto-trigger Jenkins on push
2. **Configure Auto-Sync** - ArgoCD automatically deploys changes
3. **Add Environment Promotion** - Implement MR creation for stage/prod
4. **Enable Integration Tests** - Uncomment in Jenkinsfile (line 101)
5. **Add Monitoring** - Prometheus + Grafana for observability

---

## Troubleshooting

### Build Fails at "Update Deployment Repo"
**Error:** `fatal: could not read Username`

**Fix:**
- Verify gitlab-credentials exists in Jenkins
- Check token is correct: `glpat-9m86y9YHyGf77Kr8bRjX`
- Ensure k8s-deployments project exists in GitLab

### ArgoCD Shows "Unknown" Status
**Fix:**
- Check repository connection: Settings → Repositories
- Verify token has correct permissions
- Test connection from ArgoCD to GitLab

### Docker Push Fails
**Error:** `unauthorized: authentication required`

**Fix:**
- Verify docker-registry-credentials in Jenkins
- Check Nexus Docker Bearer Token Realm enabled:
  - http://nexus.local → Administration → Security → Realms
  - Ensure "Docker Bearer Token Realm" is Active

### For More Help
See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed guides.

---

## Quick Reference

- **Documentation:** [README.md](README.md) | [ACCESS.md](ACCESS.md) | [STATUS.md](STATUS.md)
- **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Workflows:** [docs/WORKFLOWS.md](docs/WORKFLOWS.md)
- **Troubleshooting:** [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
