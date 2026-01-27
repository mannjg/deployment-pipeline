# UC-B1: Add App Environment Variable - Design Document

**Date:** 2026-01-26
**Status:** Design Complete
**Use Case:** UC-B1 from docs/USE_CASES.md

## Overview

This document defines the implementation of a demo script that proves app-level environment variables propagate to ALL environments through the GitOps pipeline.

### Use Case Story

> "As an app team, we need a new FEATURE_FLAGS env var in all environments"

### Key Difference from UC-B4

- **UC-B4** is two-phase (add app default + add env override)
- **UC-B1** is single-phase (add once, verify everywhere)

### What This Validates

1. Changes to `services/apps/example-app.cue` flow through the promotion chain
2. The `appEnvVars` array in CUE correctly generates container env vars
3. All environments (dev/stage/prod) receive the same app-level configuration

## Technical Implementation

### CUE Change

Add a `FEATURE_FLAGS` env var to the existing `appEnvVars` array in `services/apps/example-app.cue`:

```cue
appEnvVars: [
    // ... existing vars ...
    {
        name:  "FEATURE_FLAGS"
        value: "dark-mode,new-checkout"
    },
]
```

### Verification Method

Check the deployment's container spec for the env var:

```bash
kubectl get deployment example-app -n <env> \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FEATURE_FLAGS")].value}'
```

Expected result in all envs: `dark-mode,new-checkout`

### Branch Strategy

**Important:** `main` branch is NOT used. Feature branches are created from `dev` in GitLab.

| Step | Branch | Action |
|------|--------|--------|
| 1 | `uc-b1-feature-flags-<timestamp>` | Create from dev, add CUE change |
| 2 | MR → dev | Merge triggers k8s-deployments CI |
| 3 | dev → stage | Jenkins auto-creates promotion MR |
| 4 | stage → prod | Jenkins auto-creates promotion MR |

### Demo Flow

```
1. Create feature branch FROM dev in GitLab
2. Add FEATURE_FLAGS env var to services/apps/example-app.cue
3. Create MR: feature → dev
4. Jenkins CI generates manifests
5. Merge → ArgoCD syncs dev
6. Jenkins auto-creates promotion MR: dev → stage
7. Merge → ArgoCD syncs stage
8. Jenkins auto-creates promotion MR: stage → prod
9. Merge → ArgoCD syncs prod
10. Verify all envs have FEATURE_FLAGS
11. Cleanup: reverse the process
```

## Verification & Assertions

### Assertion Function

```bash
# Check deployment has specific env var with expected value
assert_deployment_env_var() {
    local namespace="$1"
    local deployment="$2"
    local env_name="$3"
    local expected_value="$4"

    actual=$(kubectl get deployment "$deployment" -n "$namespace" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$env_name\")].value}")

    [[ "$actual" == "$expected_value" ]]
}
```

### Verification Points

| Step | Environment | Check |
|------|-------------|-------|
| Baseline | dev, stage, prod | `FEATURE_FLAGS` does NOT exist |
| After dev merge | dev | `FEATURE_FLAGS` = `dark-mode,new-checkout` |
| After stage merge | stage | `FEATURE_FLAGS` = `dark-mode,new-checkout` |
| After prod merge | prod | `FEATURE_FLAGS` = `dark-mode,new-checkout` |
| After cleanup | dev, stage, prod | `FEATURE_FLAGS` does NOT exist |

## Script Structure

```
demo-uc-b1-app-env-var.sh
├── Configuration
│   ├── DEMO_ENV_VAR_NAME="FEATURE_FLAGS"
│   ├── DEMO_ENV_VAR_VALUE="dark-mode,new-checkout"
│   └── APP_CUE_PATH="services/apps/example-app.cue"
├── Step 1: Verify Prerequisites
│   ├── kubectl connectivity
│   ├── ArgoCD apps exist (dev/stage/prod)
│   └── Deployments exist
├── Step 2: Verify Baseline State
│   └── FEATURE_FLAGS absent from all envs
├── Step 3: Modify App CUE (local edit + CUE validation)
├── Step 4: Push via GitLab MR (feature branch from dev)
├── Step 5: Promote Through Environments
│   ├── dev: merge MR, wait for ArgoCD, verify
│   ├── stage: wait for auto-promotion MR, merge, verify
│   └── prod: wait for auto-promotion MR, merge, verify
├── Step 6: Final Verification
│   └── All envs have FEATURE_FLAGS
└── Cleanup (on exit or explicit)
    └── Remove env var, propagate removal
```

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/demo/demo-uc-b1-app-env-var.sh` | Create | Main demo script (~250-300 lines) |
| `scripts/demo/lib/assertions.sh` | Modify (if needed) | Add `assert_deployment_env_var` |
| `scripts/demo/run-all-demos.sh` | Modify | Add UC-B1 to test suite |
| `docs/USE_CASES.md` | Modify | Update status to ✅ |

## Success Criteria

1. Demo runs end-to-end without errors
2. `FEATURE_FLAGS` env var appears in all 3 environments
3. Cleanup removes env var from all environments
4. `run-all-demos.sh` passes with UC-B1 included
5. No regression in existing demos (UC-A3, UC-B4, UC-C1, UC-C2, UC-C4, UC-C6)

## Final Verification

After implementation, run:

```bash
./scripts/demo/run-all-demos.sh
```

This validates UC-B1 and confirms no regressions. The final status report will include verification status of UC-A3, UC-B4, and UC-C2.

## Related Documentation

- [USE_CASES.md](../USE_CASES.md) - All use case definitions
- [demo-uc-b4-app-override.sh](../../scripts/demo/demo-uc-b4-app-override.sh) - Reference implementation (Category B)
- [demo-uc-c1-default-label.sh](../../scripts/demo/demo-uc-c1-default-label.sh) - Reference implementation (promotion pattern)
