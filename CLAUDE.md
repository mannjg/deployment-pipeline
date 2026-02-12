Local GitOps CI/CD pipeline demo using Jenkins, GitLab, ArgoCD, and Nexus on Kubernetes.

Critical invariants:
- Environment branches (dev/stage/prod) are ONLY modified via merged MRs. No exceptions.
- Subtree sync order is mandatory: `git push origin main` then `./scripts/04-operations/sync-to-gitlab.sh`.

Workflow order (critical):
- Initial bootstrap: `git push origin main` -> `sync-to-gitlab.sh` -> `setup-gitlab-env-branches.sh`.
- After k8s-deployments core changes: `git push origin main` -> `sync-to-gitlab.sh` -> `reset-demo-state.sh`.
- After example-app changes only: `git push origin main` -> `demo-uc-e1-app-deployment.sh`.
- Demo reset/validation: `reset-demo-state.sh` -> `run-all-demos.sh`.

For the full project map, read `AGENTS.md`.
