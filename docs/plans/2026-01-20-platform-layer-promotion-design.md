# Platform Layer Promotion Enhancement

**Date:** 2026-01-20
**Status:** Implementing

## Problem

`promote-app-config.sh` only promotes `deployment.image` from `env.cue`. Platform layer changes (`services/core/*.cue`, `services/base/*.cue`) and app layer changes (`services/apps/*.cue`) are not synced during promotion.

This causes UC-C1 (Add Default Label to All Deployments) to fail: the cost-center label added to `services/core/app.cue` on dev never propagates to stage or prod.

## Solution

Enhance `promote-app-config.sh` to sync the `services/` directories (base, core, apps) from source branch to target branch during promotion.

### Key Insight

Preservation of env-specific values (namespace, replicas, resources, debug) is handled by CUE unification, not by the promotion script. The target branch's `env.cue` already contains the correct env-specific overrides, and CUE's layering ensures these values "win" when manifests are generated.

### What Gets Synced (Source → Target)

| Directory | Purpose |
|-----------|---------|
| `services/base/` | Base defaults and schemas |
| `services/core/` | Shared templates (defaultLabels, #App) |
| `services/apps/` | App definitions |

### What Gets Preserved (Target's Values)

Handled by CUE unification when manifests are generated:
- `env.cue`: namespace, replicas, resources, debug, labels.environment

## Implementation

Add platform/app layer sync to `promote-app-config.sh` after fetching the source branch:

```bash
# Sync platform and app layers from source to target
log_info "Syncing platform and app layers from $SOURCE_ENV..."

for dir in services/base services/core services/apps; do
    if [ -d "$SOURCE_DIR/$dir" ]; then
        log_info "  Syncing $dir/"
        rm -rf "$dir"
        cp -r "$SOURCE_DIR/$dir" "$dir"
        git add "$dir"
    fi
done
```

## Validation

UC-C1 demo (`scripts/demo/demo-uc-c1-default-label.sh`) validates:
1. Platform layer change (cost-center label) propagates to all environments
2. Env-specific values (namespace, replicas) are preserved via CUE unification
3. Full promotion chain works: dev → stage → prod
