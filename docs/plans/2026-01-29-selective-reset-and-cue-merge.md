# Design: Selective Branch Reset & CUE Env Var Merge

**Date:** 2026-01-29
**Status:** Approved

## Overview

Two independent optimizations:
1. **Selective Branch Reset** - Only reset branches each demo touches (saves ~4.5 min per suite)
2. **CUE Env Var Merge** - Fix `list.Concat` to merge env vars by key so overrides work

---

## Part 1: Selective Branch Reset

### Problem

`run-all-demos.sh` resets all 3 branches (dev, stage, prod) before every demo, even demos that only touch dev. This wastes ~1.5 min per dev-only demo.

### Solution

1. Extend demo list format to include branch scope
2. Add `--branches` flag to `reset-demo-state.sh`
3. Runner passes scope to reset script

### Data Structure Changes

**run-all-demos.sh - extend DEMO_ORDER format:**

```bash
# Current format (3 fields):
"UC-A1:demo-uc-a1-replicas.sh:Adjust replica count (isolated)"

# New format (4 fields, 4th is branch list):
"UC-A1:demo-uc-a1-replicas.sh:Adjust replica count:dev"
"UC-B4:demo-uc-b4-app-override.sh:App ConfigMap with env override:dev,stage,prod"
```

**Branch scope assignments:**

| Demo | Branches | Rationale |
|------|----------|-----------|
| UC-A1, A2, A3 | `dev` | Isolated env changes |
| UC-B1, B2, B3 | `dev,stage,prod` | Full promotion chain |
| UC-B4, B5, B6 | `dev,stage,prod` | Override tests need all envs |
| UC-C1-C6 | `dev,stage,prod` | Platform-wide changes |
| validate-pipeline | `dev,stage,prod` | Full lifecycle test |

### Script Interface Changes

**reset-demo-state.sh - add --branches flag:**

```bash
# Parse arguments
BRANCHES="dev,stage,prod"  # Default: all branches

while [[ $# -gt 0 ]]; do
    case $1 in
        --branches)
            BRANCHES="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Convert to array
IFS=',' read -ra BRANCH_LIST <<< "$BRANCHES"
```

**Modify Phase 3 loop:**

```bash
# Current:
for env in dev stage prod; do
    reset_branch "$env"
done

# New:
for env in "${BRANCH_LIST[@]}"; do
    reset_branch "$env"
done
```

### Runner Integration

**run-all-demos.sh - update reset call:**

```bash
run_demo() {
    local entry="$1"
    IFS=':' read -r id script desc branches <<< "$entry"
    branches="${branches:-dev,stage,prod}"

    if [[ "$SKIP_RESET" != "true" ]]; then
        echo -e "${BLUE}  RESET: Preparing clean state for ${id}${NC}"
        "$RESET_SCRIPT" --branches "$branches"
    fi

    # ... existing demo run logic ...
}
```

### Usage Examples

```bash
./reset-demo-state.sh                        # Resets dev,stage,prod (default)
./reset-demo-state.sh --branches dev         # Resets dev only
./reset-demo-state.sh --branches dev,stage   # Resets dev and stage
```

---

## Part 2: CUE Env Var Merge-by-Key

### Problem

`deployment.cue` uses `list.Concat` for env vars, which creates duplicates instead of merging by name. When ArgoCD applies with `kubectl apply`, Kubernetes deduplicates keeping the FIRST occurrence, defeating override semantics.

**Current behavior (broken):**
```
appEnvVars:    [{name: "LOG_LEVEL", value: "INFO"}]
additionalEnv: [{name: "LOG_LEVEL", value: "DEBUG"}]
result:        [{name: "LOG_LEVEL", value: "INFO"}, {name: "LOG_LEVEL", value: "DEBUG"}]
kubectl apply: LOG_LEVEL=INFO (first wins)
```

**Desired behavior:**
```
result:        [{name: "LOG_LEVEL", value: "DEBUG"}]
kubectl apply: LOG_LEVEL=DEBUG (override works)
```

### Solution

Create a generic `#MergeListByKey` helper that merges lists of structs by a key field, with later values overriding earlier ones.

### Helper Function

**New file: `services/core/helpers.cue`**

```cue
package core

import "list"

// #MergeListByKey merges multiple lists of structs by a key field.
// Later lists override earlier lists for matching keys.
// Non-matching entries are preserved from all lists.
//
// Usage:
//   (#MergeListByKey & {
//       lists: [baseEnvVars, appEnvVars, envEnvVars]
//       key:   "name"
//   }).out
//
#MergeListByKey: {
    lists: [[...{...}], ...]  // Array of lists to merge
    key:   string              // Field name to merge on (e.g., "name")

    // Convert lists to map keyed by the key field, later wins
    _merged: {
        for l in lists
        for item in l {
            (item[key]): item
        }
    }

    // Convert map back to list
    out: [ for k, v in _merged {v} ]
}
```

### Integration Points

**services/core/app.cue (line 104):**

```cue
// Before:
_computedAppEnvVars: list.Concat([_baseAppEnvs, appEnvVars, envEnvVars])

// After:
_computedAppEnvVars: (#MergeListByKey & {
    lists: [_baseAppEnvs, appEnvVars, envEnvVars]
    key:   "name"
}).out
```

**services/resources/deployment.cue (line 105):**

```cue
// Before:
_env: list.Concat([appEnvVars, appConfig.deployment.additionalEnv])

// After:
_env: (#MergeListByKey & {
    lists: [appEnvVars, appConfig.deployment.additionalEnv]
    key:   "name"
}).out
```

### Scope

**In scope (envVars):**
- `app.cue:104` - multi-layer env vars
- `deployment.cue:105` - app + additional env vars

**Out of scope (concat is fine):**
- `deployment.cue:109` - envFrom (complex key structure)
- `deployment.cue:123` - volumes (rarely need override)
- `deployment.cue:190` - volumeMounts (rarely need override)
- `service.cue:53` - ports (rarely need override)

These can be revisited if override use cases emerge.

---

## Validation Plan

### Selective Branch Reset

1. Run `reset-demo-state.sh --branches dev` - verify only dev resets
2. Run `run-all-demos.sh` - verify UC-A demos use dev-only reset
3. Confirm full suite still passes

### CUE Merge

1. Run `cue vet ./...` in k8s-deployments - verify syntax
2. Run UC-B6 demo - should show `LOG_LEVEL=DEBUG` in dev
3. Run full demo suite - verify no regressions

### Edge Cases

| Case | Expected behavior |
|------|-------------------|
| Empty additionalEnv | Same as before (base vars only) |
| No overlap in keys | All entries preserved |
| Multiple overlaps | All later values win |
| Empty base list | Only additional entries |

---

## Implementation Notes

- Both changes are independent and can be implemented in parallel
- Selective branch reset is pure bash changes
- CUE merge requires syncing to GitLab and running through pipeline
- UC-B6 demo already documents the limitation - will need update after fix
