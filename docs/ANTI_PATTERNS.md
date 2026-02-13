# Anti-Patterns

Concrete examples of what not to do and the approved alternative.

## Shell scripts
- Don't add abstraction layers for one-off flows.

Wrong:
```bash
scripts/lib/do_everything.sh "$@"
```

Right:
```bash
scripts/04-operations/validate-manifests.sh "$@"
```

- Don't consolidate scripts serving different contexts (demo vs ops vs CI).

Wrong:
```bash
scripts/demo/run-demo.sh --mode ops
```

Right:
```bash
scripts/demo/run-demo.sh
scripts/04-operations/promote-env.sh
```

- Don't replace CLI wrappers with direct curl.

Wrong:
```bash
curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/projects"
```

Right:
```bash
scripts/04-operations/gitlab-cli.sh projects list
```

Exception:
If the CLI wrapper lacks the needed endpoint, extend the wrapper. If a direct API call is temporarily required, document the exception in the file with `# allow-direct-api` and include a short rationale.

- Don't inline credential access.

Wrong:
```bash
kubectl -n infra get secret jenkins-token -o jsonpath='{.data.token}' | base64 -d
```

Right:
```bash
scripts/lib/credentials.sh jenkins_token
```

## Jenkinsfiles
- Don't put logic in inline sh blocks over ~15 lines.

Wrong:
```groovy
sh '''
set -euo pipefail
# 20+ lines of logic here
'''
```

Right:
```groovy
sh 'scripts/04-operations/validate-manifests.sh'
```

- Don't hardcode URLs.

Wrong:
```groovy
env.GITLAB_URL = 'https://gitlab.example.com'
```

Right:
```groovy
env.GITLAB_URL = params.GITLAB_URL
```

- Don't skip GitLab commit status reporting.

Wrong:
```groovy
sh 'scripts/04-operations/validate-manifests.sh'
```

Right:
```groovy
loadHelpers().reportGitLabStatus('pending', statusContext, env.GIT_COMMIT_SHA, projectPath)
sh 'scripts/04-operations/validate-manifests.sh'
loadHelpers().reportGitLabStatus('success', statusContext, env.GIT_COMMIT_SHA, projectPath)
```

- Don't deploy from feature branches.

Wrong:
```groovy
if (env.BRANCH_NAME.startsWith('feature/')) {
  sh 'scripts/04-operations/promote-env.sh prod'
}
```

Right:
```groovy
if (env.BRANCH_NAME == 'main') {
  sh 'scripts/04-operations/promote-env.sh prod'
}
```

## CUE schemas
- Don't reference env-specific values from app definitions.

Wrong:
```cue
app: {
  replicas: envs.prod.replicas
}
```

Right:
```cue
app: {
  replicas: 3
}
```

- Don't bypass the `#App` schema.

Wrong:
```cue
myapp: {
  name: "example"
}
```

Right:
```cue
myapp: #App & {
  name: "example"
}
```

- Don't remove defaults.

Wrong:
```cue
#App: {
  image: string
}
```

Right:
```cue
#App: {
  image: string | *"registry/example:latest"
}
```

## Operations
- Don't push directly to env branches.

Wrong:
```bash
git push origin prod
```

Right:
```bash
scripts/04-operations/promote-env.sh prod
```

- Don't run GitLab sync before pushing to GitHub origin.

Wrong:
```bash
scripts/04-operations/sync-to-gitlab.sh
git push origin main
```

Right:
```bash
git push origin main
scripts/04-operations/sync-to-gitlab.sh
```

- Don't hardcode namespace names.

Wrong:
```bash
kubectl -n prod apply -f manifests/
```

Right:
```bash
kubectl -n "$K8S_NAMESPACE" apply -f manifests/
```
