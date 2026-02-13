# Operations

This doc collects common operational commands and required tooling.

## Jenkins Operations (ALWAYS use jenkins-cli.sh)

**IMPORTANT:** Always use `scripts/04-operations/jenkins-cli.sh` for Jenkins operations. Do not write ad-hoc curl commands - extend the CLI if needed.

```bash
# Get build status (JSON output)
./scripts/04-operations/jenkins-cli.sh status example-app/main
./scripts/04-operations/jenkins-cli.sh status k8s-deployments/dev

# Get console output
./scripts/04-operations/jenkins-cli.sh console example-app/main
./scripts/04-operations/jenkins-cli.sh console example-app/main 138  # specific build

# Wait for build to complete
./scripts/04-operations/jenkins-cli.sh wait example-app/main --timeout 600
```

Job notation uses slash format: `example-app/main` -> `example-app/job/main`.

## GitLab Operations (ALWAYS use gitlab-cli.sh)

**IMPORTANT:** Always use `scripts/04-operations/gitlab-cli.sh` for GitLab API operations. Do not write ad-hoc curl commands - extend the CLI if needed.

```bash
# List open MRs targeting dev
./scripts/04-operations/gitlab-cli.sh mr list p2c/k8s-deployments --state opened --target dev

# Merge an MR
./scripts/04-operations/gitlab-cli.sh mr merge p2c/k8s-deployments 634

# List branches matching pattern
./scripts/04-operations/gitlab-cli.sh branch list p2c/k8s-deployments --pattern "promote-*"

# Get file from specific branch
./scripts/04-operations/gitlab-cli.sh file get p2c/k8s-deployments env.cue --ref stage

# Verify authentication
./scripts/04-operations/gitlab-cli.sh user
```

Project notation uses path format: `p2c/example-app` (auto URL-encoded).

## Trigger a Build
```bash
./scripts/04-operations/trigger-build.sh example-app
```

## Status Summary (Agent-Oriented)
```bash
./scripts/04-operations/status-summary.sh
```

## Check Deployment Status
```bash
kubectl get applications -n argocd
kubectl get pods -n dev
```

## Sync to GitLab (after pushing to GitHub)
```bash
./scripts/04-operations/sync-to-gitlab.sh
```

## Access Application
```bash
kubectl port-forward -n dev svc/example-app 8080:8080 &
curl http://localhost:8080/api/greetings
pkill -f "port-forward.*example-app"
```

## Quick Debugging

**Pod not starting:**
```bash
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name>
```

**ArgoCD not syncing:**
```bash
kubectl describe application -n argocd <app-name>
```

**CUE validation:**
```bash
cd k8s-deployments
cue vet ./...
```
