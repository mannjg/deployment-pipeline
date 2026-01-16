# Scripts Directory Reorganization

## Problem

The `scripts/` directory contains 28 scripts in a flat structure. Issues:
- Unclear execution order for fresh setup
- Mixed one-time setup vs daily operations
- Duplicate scripts with overlapping functionality
- Root-level scripts scattered outside `scripts/`

## Solution

Reorganize into lifecycle-based folders with numbered prefixes.

## New Structure

```
scripts/
├── 01-infrastructure/     # Deploy K8s components (run first)
│   ├── setup-all.sh       # Master orchestrator
│   ├── install-microk8s.sh
│   ├── apply-infrastructure.sh
│   ├── setup-gitlab.sh
│   ├── setup-jenkins.sh
│   └── verify-k3s-installation.sh    # Moved from root
│
├── 02-configure/          # Configure deployed services
│   ├── configure-gitlab.sh
│   ├── configure-jenkins.sh
│   ├── configure-nexus.sh
│   └── configure-gitlab-connection.sh
│
├── 03-pipelines/          # Set up CI/CD jobs, repos, webhooks
│   ├── create-gitlab-projects.sh
│   ├── setup-gitlab-repos.sh
│   ├── setup-gitlab-env-branches.sh
│   ├── ensure-webhook.sh             # Renamed from ensure-gitlab-webhook.sh
│   ├── configure-merge-requirements.sh
│   ├── setup-jenkins-promote-job.sh
│   ├── setup-k8s-deployments-validation-job.sh
│   └── setup-manifest-generator-job.sh
│
├── 04-operations/         # Day-to-day scripts
│   ├── sync-to-gitlab.sh
│   ├── sync-to-github.sh
│   ├── sync-k8s-deployments.sh
│   ├── trigger-build.sh
│   ├── create-gitlab-mr.sh
│   ├── validate-manifests.sh
│   ├── docker-registry-helper.sh
│   └── check-health.sh               # Moved from root
│
├── teardown/
│   └── teardown-all.sh
│
├── debug/                 # Diagnostic/testing scripts
│   ├── check-gitlab-plugin.sh
│   └── test-k8s-validation.sh
│
├── test/                  # Validation/regression tests
│   ├── validate-pipeline.sh          # Moved from root
│   └── test-image-update-isolation.sh # Moved from root
│
└── lib/
    └── config.sh
```

## Scripts to Delete

| Script | Reason | Replacement |
|--------|--------|-------------|
| `setup-gitlab-webhook.sh` | Duplicate, less robust | `ensure-webhook.sh p2c/example-app` |
| `setup-k8s-deployments-webhook.sh` | Hardcoded, interactive | `ensure-webhook.sh p2c/k8s-deployments` |

## Scripts to Rename

| Original | New Name |
|----------|----------|
| `ensure-gitlab-webhook.sh` | `ensure-webhook.sh` |

## Documentation Updates Required

- `CLAUDE.md` - Update script path references
- `docs/plans/2026-01-14-validate-pipeline-design.md` - Update references

## Migration Steps

1. Create new folder structure
2. Move scripts with `git mv` (preserves history)
3. Update internal paths (`lib/config.sh` → `../lib/config.sh`)
4. Update `setup-all.sh` to call scripts from new locations
5. Delete duplicate scripts
6. Update documentation references
7. Test `setup-all.sh` still works

## Notes

- `k8s-deployments/scripts/` is NOT touched (synced to GitLab as subtree)
- Scripts source config from `config/infra.env` - paths stay valid
- `setup-all.sh` paths updated manually (explicit calls, no auto-discovery)
