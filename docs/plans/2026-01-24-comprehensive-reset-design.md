# Comprehensive Demo Reset Design

**Date:** 2026-01-24
**Status:** Approved
**Related:** UC-C2 (Pod Security Context), all use cases

## Problem Statement

The current `reset-demo-state.sh` uses a "subtractive" approach - it removes specific demo artifacts (e.g., `cost-center` labels). This requires updating the reset script for each new demo and risks missing cleanup steps.

## Solution: Baseline + Regenerate

Instead of tracking what each demo adds, define the **baseline state** and reset to it:

1. **`services/` directory**: Reset all CUE files from main branch
2. **`env.cue`**: Reset from canonical baseline templates, preserving only CI/CD-managed image tags
3. **Manifests**: Let Jenkins regenerate from clean CUE (no manual cleanup)

## Baseline Files

**Location:** `scripts/03-pipelines/baselines/`

```
scripts/03-pipelines/baselines/
├── env-dev.cue      # Canonical dev env.cue
├── env-stage.cue    # Canonical stage env.cue
└── env-prod.cue     # Canonical prod env.cue
```

**Rationale:** Baselines are demo infrastructure, not deployment configuration. They don't belong in k8s-deployments (which syncs to GitLab).

## env.cue Baseline Structure

Each baseline contains the complete env.cue with image placeholders:

```cue
// env-dev.cue baseline
dev: exampleApp: apps.exampleApp & {
    appConfig: {
        namespace: "dev"
        labels: {
            environment: "dev"
            managed_by:  "argocd"
        }
        debug: true
        deployment: {
            image: "{{EXAMPLE_APP_IMAGE}}"  // Extracted from live env.cue
            replicas: 1
            resources: {
                requests: { cpu: "100m", memory: "256Mi" }
                limits:   { cpu: "500m", memory: "512Mi" }
            }
            // ... probes, additionalEnv, etc.
        }
        configMap: {
            data: {
                "redis-url":     "redis://redis.dev.svc.cluster.local:6379"
                "log-level":     "debug"
                "feature-flags": "experimental-features=true"
            }
        }
    }
}

dev: postgres: apps.postgres & {
    // ... postgres baseline
}
```

## Environment Differences

| Field | Dev | Stage | Prod |
|-------|-----|-------|------|
| `debug` | `true` | `true` | `false` |
| `replicas` | 1 | 2 | 3 |
| `resources.requests.cpu` | 100m | 500m | 2000m |
| `resources.requests.memory` | 256Mi | 512Mi | 1Gi |
| `resources.limits.cpu` | 500m | 1000m | 2000m |
| `resources.limits.memory` | 512Mi | 1Gi | 2Gi |
| `additionalEnv[QUARKUS_LOG_LEVEL]` | DEBUG | INFO | WARN |
| `configMap.data.log-level` | debug | info | warn |
| `configMap.data.redis-url` | redis.dev... | redis.stage... | redis.prod... |
| **postgres** `storage.pvc.storageSize` | 5Gi | 20Gi | 50Gi |

## Complete Reset Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        RESET DEMO STATE                              │
├─────────────────────────────────────────────────────────────────────┤
│  Phase 1: Stop In-Flight Work                                        │
│    ├── Clear Jenkins queue                                           │
│    ├── Abort running k8s-deployments builds                          │
│    └── Delete Jenkins agent pods                                     │
├─────────────────────────────────────────────────────────────────────┤
│  Phase 2: Clean Up Branches & MRs                                    │
│    ├── Close all open MRs targeting dev/stage/prod                   │
│    ├── Delete orphaned GitLab demo branches (uc-*, promote-*, etc.)  │
│    └── Delete local demo branches                                    │
├─────────────────────────────────────────────────────────────────────┤
│  Phase 3: Reset CUE Configuration                                    │
│    ├── For each env branch (dev, stage, prod):                       │
│    │   ├── Extract current image tags from env.cue                   │
│    │   ├── Reset services/ directory from main                       │
│    │   └── Reset env.cue from baseline (with extracted images)       │
│    └── Trigger Jenkins builds to regenerate manifests                │
├─────────────────────────────────────────────────────────────────────┤
│  Phase 4: Wait for Pipeline Quiescence                               │
│    ├── Wait for all env branch builds to complete                    │
│    └── Verify no promotion MRs were created (no changes to promote)  │
├─────────────────────────────────────────────────────────────────────┤
│  Phase 5: Reset App Version                                          │
│    └── Reset example-app/pom.xml to 1.0.0-SNAPSHOT                   │
└─────────────────────────────────────────────────────────────────────┘
```

## Key Functions

### reset_cue_config()

Replaces: `sync_via_promotion_workflow()`, `remove_demo_labels_from_env_cue()`, `remove_demo_labels_from_manifests()`

```bash
reset_cue_config() {
    for env in dev stage prod; do
        # 1. Extract current images from live env.cue
        extract_images_from_env_cue "$env"

        # 2. Reset services/ directory from main
        reset_services_directory "$env"

        # 3. Reset env.cue from baseline with extracted images
        reset_env_cue_from_baseline "$env"
    done

    # 4. Trigger Jenkins to regenerate manifests
    trigger_manifest_regeneration
}
```

### reset_services_directory()

Copies all files in `services/` from main to the target environment branch.

### reset_env_cue_from_baseline()

1. Reads baseline template from `scripts/03-pipelines/baselines/env-${env}.cue`
2. Substitutes `{{EXAMPLE_APP_IMAGE}}` and `{{POSTGRES_IMAGE}}` placeholders
3. Pushes to GitLab branch

## Benefits

| Aspect | Current Approach | New Approach |
|--------|------------------|--------------|
| **Speed** | Sequential promotion (dev→stage→prod) | Direct reset of all branches |
| **Completeness** | Must add cleanup for each new demo | Baselines define complete state |
| **Predictability** | Partial state if reset fails mid-way | Each branch reset is atomic |
| **Auditability** | Cleanup logic scattered in code | Baselines are version-controlled |
| **New demos** | Requires reset script changes | No changes needed |

## Use Cases Handled

This approach automatically handles cleanup for ALL use cases:

| Category | Use Cases | What Gets Reset |
|----------|-----------|-----------------|
| A (Env-Specific) | UC-A1, A2, A3 | env.cue → baseline |
| B (App-Level) | UC-B1-B6 | services/apps/*.cue → main |
| C (Platform-Wide) | UC-C1-C6 | services/core/*.cue, services/base/*.cue → main |
| D (Operational) | UC-D1-D5 | Branches/MRs cleaned in Phase 2 |

## Implementation Plan

1. Create baseline files:
   - `scripts/03-pipelines/baselines/env-dev.cue`
   - `scripts/03-pipelines/baselines/env-stage.cue`
   - `scripts/03-pipelines/baselines/env-prod.cue`

2. Refactor `reset-demo-state.sh`:
   - Replace `sync_via_promotion_workflow()` with `reset_cue_config()`
   - Remove `remove_demo_labels_from_env_cue()`
   - Remove `remove_demo_labels_from_manifests()`
   - Remove `reset_cue_config()` (old version)

3. Test:
   - Run a demo (e.g., UC-C1)
   - Run reset
   - Verify clean state
   - Run validate-pipeline.sh

## Notes

- The `image:` field is the ONLY truly dynamic value in env.cue
- Jenkinsfile and scripts/ sync is still needed (handled separately)
- Baselines should be updated when environment defaults change (rare)
