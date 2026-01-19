# K8s-Deployments Use Cases

This document defines the demonstration use cases for k8s-deployments, showcasing how platform teams manage Kubernetes configurations across environments using CUE-based GitOps.

These use cases are **independent of any application's code lifecycle** (which is demonstrated by `validate-pipeline.sh`). Instead, they focus on infrastructure and configuration changes that flow through the CUE layering system.

## Overview

### CUE Configuration Layers

```
Platform (services/base/, services/core/)
    │
    │  Provides: defaults, schemas, templates
    │  Example: default labels, security contexts, deployment strategies
    │
    ▼
App (services/apps/*.cue)
    │
    │  Provides: app-specific config that applies to ALL environments
    │  Example: app env vars, app annotations, app-level ConfigMap defaults
    │
    ▼
Env (env.cue per branch: dev, stage, prod)
    │
    │  Provides: environment-specific overrides
    │  Example: replicas, resources, debug flags, env-specific ConfigMap values
    │
    ▼
Generated Manifests (manifests/<app>/<app>.yaml)
```

### Override Semantics

Each layer can override values from the layer above:
- **Env overrides App**: Production can set `replicas: 3` even if app defaults to `1`
- **App overrides Platform**: An app can disable Prometheus scraping even if platform enables it by default
- **Lower layer wins**: The most specific (lowest) layer takes precedence

### Change Propagation

| Change Location | Propagates To | Mechanism |
|-----------------|---------------|-----------|
| `env.cue` on dev | Dev only | Direct commit to branch |
| `services/apps/*.cue` | All envs for that app | Merge main → env branches |
| `services/base/` or `services/core/` | All apps, all envs | Merge main → env branches |

---

## Category A: Environment-Specific Configuration

Changes made to `env.cue` on a single environment branch. These intentionally **do NOT propagate** to other environments.

### UC-A1: Adjust Replica Count

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform operator, I want to scale dev to 2 replicas for load testing without affecting stage/prod" |
| **Change Location** | `env.cue` on `dev` branch |
| **Change** | `replicas: 1` → `replicas: 2` |
| **Expected Behavior** | Dev deploys with 2 pods; stage/prod unchanged |
| **Validates** | Environment isolation; promotion preserves target's replicas |

### UC-A2: Enable Debug Mode

| Aspect | Detail |
|--------|--------|
| **Story** | "As a developer, I want debug logging in dev but not in prod" |
| **Change Location** | `env.cue` on `dev` branch |
| **Change** | `debug: true` (dev) vs `debug: false` (prod) |
| **Expected Behavior** | Dev gets DEBUG env var and debug service; prod does not |
| **Validates** | Environment-specific flags don't leak to production |

### UC-A3: Environment-Specific ConfigMap Entry

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform operator, I want dev to use a different Redis URL than prod" |
| **Change Location** | `env.cue` on `dev` branch |
| **Change** | `configMap.data."redis-url": "redis://redis.dev.svc:6379"` |
| **Expected Behavior** | Dev ConfigMap has dev Redis; prod ConfigMap has prod Redis |
| **Validates** | ConfigMap entries set in env.cue are environment-specific |

**Demo Script:** [`scripts/demo/demo-env-configmap.sh`](../scripts/demo/demo-env-configmap.sh) (implements UC-A3)

---

## Category B: App-Level Cross-Environment Configuration

Changes made to `services/apps/<app>.cue`. These **SHOULD propagate** to all environments for that app (via merge from main to environment branches).

### UC-B1: Add App Environment Variable

| Aspect | Detail |
|--------|--------|
| **Story** | "As an app team, we need a new FEATURE_FLAGS env var in all environments" |
| **Change Location** | `services/apps/example-app.cue` → `appEnvVars` |
| **Change** | Add `{name: "FEATURE_FLAGS", value: "new-checkout,dark-mode"}` |
| **Expected Behavior** | After propagation, all envs (dev/stage/prod) have the new env var |
| **Validates** | App-level env vars flow through without manual intervention |

### UC-B2: Add App-Level Annotation

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, we want Prometheus to scrape example-app in all environments" |
| **Change Location** | `services/apps/example-app.cue` → `appConfig.deployment.podAnnotations` |
| **Change** | Add `"prometheus.io/scrape": "true"`, `"prometheus.io/port": "8080"` |
| **Expected Behavior** | All envs get the annotation; env.cue doesn't need to specify it |
| **Validates** | App-level appConfig fields inherit to all envs via CUE unification |

### UC-B3: Add App-Level ConfigMap Entry

| Aspect | Detail |
|--------|--------|
| **Story** | "As an app team, we need a consistent cache-ttl setting across all environments" |
| **Change Location** | `services/apps/example-app.cue` → `appConfig.configMap.data` |
| **Change** | Add `"cache-ttl": "300"` |
| **Expected Behavior** | All envs get cache-ttl=300 in ConfigMap; envs can override if needed |
| **Validates** | App-level ConfigMap entries propagate; env-level can still override |

### UC-B4: App ConfigMap with Environment Override

| Aspect | Detail |
|--------|--------|
| **Story** | "App sets cache-ttl=300, but prod needs cache-ttl=600 for performance" |
| **Change Location** | App: `services/apps/example-app.cue`; Override: `env.cue` on `prod` |
| **Change** | App sets `"cache-ttl": "300"`; Prod's env.cue sets `"cache-ttl": "600"` |
| **Expected Behavior** | Dev/stage get 300; prod gets 600 |
| **Validates** | Environment override takes precedence over app-level default |

**Demo Script:** [`scripts/demo/demo-app-override.sh`](../scripts/demo/demo-app-override.sh) (implements UC-B4)

### UC-B5: App-Level Probe with Environment Override

| Aspect | Detail |
|--------|--------|
| **Story** | "App defines readiness probe with 10s timeout, but prod needs 30s due to cold-start characteristics" |
| **Change Location** | App: `services/apps/example-app.cue` → `appConfig.deployment.readinessProbe`; Override: `env.cue` on `prod` |
| **Change** | App sets `timeoutSeconds: 10`; Prod's env.cue sets `timeoutSeconds: 30` |
| **Expected Behavior** | Dev/stage use 10s timeout; prod uses 30s |
| **Validates** | Environment can override any app-level appConfig field (clean CUE merge) |

### UC-B6: App-Level Env Var with Environment Override

| Aspect | Detail |
|--------|--------|
| **Story** | "App sets LOG_LEVEL=INFO as default, but dev needs LOG_LEVEL=DEBUG for troubleshooting" |
| **Change Location** | App: `services/apps/example-app.cue` → `appEnvVars`; Override: `env.cue` on `dev` → `additionalEnv` |
| **Change** | App sets `{name: "LOG_LEVEL", value: "INFO"}`; Dev's env.cue sets `{name: "LOG_LEVEL", value: "DEBUG"}` |
| **Expected Behavior** | Stage/prod use INFO; dev uses DEBUG |
| **Design Note** | Current implementation concatenates env vars (both appear, last wins in K8s). A cleaner implementation might merge-by-name. |
| **Validates** | Env var override pattern; documents concatenation vs merge semantics |

---

## Category C: Platform-Wide Configuration

Changes made to `services/base/` (defaults/schema) or `services/core/` (templates). These **SHOULD propagate** to all apps in all environments.

### UC-C1: Add Default Label to All Deployments

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, we need all deployments to have a `cost-center` label for chargeback reporting" |
| **Change Location** | `services/core/app.cue` → `defaultLabels` |
| **Change** | Add `"cost-center": "platform-shared"` to defaultLabels |
| **Expected Behavior** | All apps in all envs get the label; apps/envs can override if needed |
| **Validates** | Template-level changes propagate universally |

### UC-C2: Add Pod Security Context

| Aspect | Detail |
|--------|--------|
| **Story** | "As a security team, we require all pods to run as non-root" |
| **Change Location** | `services/base/defaults.cue` → `#DefaultPodSecurityContext`; referenced in `services/resources/deployment.cue` |
| **Change** | Enable `runAsNonRoot: true`, `runAsUser: 1000` |
| **Expected Behavior** | All deployments across all apps/envs get the security context |
| **Validates** | Base defaults flow through templates to all generated manifests |

### UC-C3: Change Default Deployment Strategy

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, we want zero-downtime deployments as the default" |
| **Change Location** | `services/base/defaults.cue` → `#DefaultDeploymentStrategy` |
| **Change** | Change `maxUnavailable: 1` → `maxUnavailable: 0` |
| **Expected Behavior** | All apps default to zero-downtime unless explicitly overridden |
| **Validates** | Changing base defaults affects all consumers |

### UC-C4: Add Standard Pod Annotation

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, we want all pods to be scraped by Prometheus by default" |
| **Change Location** | `services/core/app.cue` or `services/resources/deployment.cue` |
| **Change** | Add default `podAnnotations: {"prometheus.io/scrape": "true"}` |
| **Expected Behavior** | All deployments get Prometheus annotation; apps can override to "false" if needed |
| **Validates** | Platform-wide defaults with opt-out capability |

### UC-C5: Platform Default with App Override

| Aspect | Detail |
|--------|--------|
| **Story** | "Platform sets Prometheus scraping on, but legacy-app needs it off" |
| **Change Location** | Platform: `services/core/app.cue`; Override: `services/apps/legacy-app.cue` |
| **Change** | Platform sets `"prometheus.io/scrape": "true"`; legacy-app sets `"prometheus.io/scrape": "false"` |
| **Expected Behavior** | Most apps get scraping enabled; legacy-app has it disabled across all its envs |
| **Validates** | App layer can override platform defaults |

### UC-C6: Platform Default with Environment Override

| Aspect | Detail |
|--------|--------|
| **Story** | "Platform sets cost-center=platform-shared, but prod overrides to cost-center=production-critical" |
| **Change Location** | Platform: `services/core/app.cue`; Override: `env.cue` on `prod` |
| **Change** | Platform sets `"cost-center": "platform-shared"`; prod's env.cue sets `"cost-center": "production-critical"` |
| **Expected Behavior** | Dev/stage get platform-shared; prod gets production-critical |
| **Validates** | Full override chain: Platform → App → Env |

---

## Use Case Summary

### All Use Cases at a Glance

| Category | ID | Use Case | Change Location | Propagation |
|----------|-----|----------|-----------------|-------------|
| **A: Env-Specific** | UC-A1 | Adjust replica count | `env.cue` | Stays in env |
| | UC-A2 | Enable debug mode | `env.cue` | Stays in env |
| | UC-A3 | Env-specific ConfigMap entry | `env.cue` | Stays in env |
| **B: App-Level** | UC-B1 | Add app env var | `services/apps/*.cue` | All envs for app |
| | UC-B2 | Add app annotation | `services/apps/*.cue` | All envs for app |
| | UC-B3 | Add app ConfigMap entry | `services/apps/*.cue` | All envs for app |
| | UC-B4 | App ConfigMap with env override | App + `env.cue` | App default, env overrides |
| | UC-B5 | App probe with env override | App + `env.cue` | App default, env overrides |
| | UC-B6 | App env var with env override | App + `env.cue` | App default, env overrides |
| **C: Platform-Wide** | UC-C1 | Add default label | `services/core/` | All apps, all envs |
| | UC-C2 | Add security context | `services/base/` | All apps, all envs |
| | UC-C3 | Change deployment strategy | `services/base/` | All apps, all envs |
| | UC-C4 | Add pod annotation | `services/core/` | All apps, all envs |
| | UC-C5 | Platform default with app override | Platform + App | Platform default, app overrides |
| | UC-C6 | Platform default with env override | Platform + `env.cue` | Platform default, env overrides |

### Override Hierarchy

```
Platform (services/base/, services/core/)
    ↓ UC-C1 through UC-C4 demonstrate this layer
App (services/apps/*.cue)
    ↓ UC-B1 through UC-B3 demonstrate this layer
    ↓ UC-C5 demonstrates app overriding platform
Env (env.cue per branch)
    ↓ UC-A1 through UC-A3 demonstrate this layer
    ↓ UC-B4 through UC-B6 demonstrate env overriding app
    ↓ UC-C6 demonstrates env overriding platform
```

---

## Demo Scripts

### Initial Demos (Phase 1)

| Script | Use Case | What It Demonstrates |
|--------|----------|---------------------|
| [`scripts/demo/demo-env-configmap.sh`](../scripts/demo/demo-env-configmap.sh) | UC-A3 | Environment-specific changes stay isolated |
| [`scripts/demo/demo-app-override.sh`](../scripts/demo/demo-app-override.sh) | UC-B4 | App defaults propagate; environments can override |

### Future Demos (Phase 2+)

Additional demos can be added to cover:
- Platform-wide changes (UC-C1 through UC-C4)
- Complex override chains (UC-C5, UC-C6)
- Multi-app scenarios

---

## Implementation Notes

### Current State vs Ideal State

| Capability | Current State | Ideal State |
|------------|---------------|-------------|
| Env-specific changes (Category A) | Works correctly | Works correctly |
| App-level propagation (Category B) | Requires manual merge main→env | Automated via promotion |
| Platform-wide propagation (Category C) | Requires manual merge main→env | Automated via promotion |
| Override semantics | Works via CUE unification | Works via CUE unification |

### Promotion System

The current `promote-app-config.sh` only promotes:
- `deployment.image` (CI/CD managed)

Future enhancement should also promote:
- `deployment.additionalEnv` (app env vars)
- `configMap.data` (app config)
- Changes to `services/apps/*.cue`
- Changes to `services/base/` and `services/core/`

While preserving:
- `namespace`
- `replicas`
- `resources`
- `debug`
- `labels.environment`

---

## Implementation Status

| ID | Use Case | CUE Support | Demo Script | Pipeline Verified | Branch | Notes |
|----|----------|-------------|-------------|-------------------|--------|-------|
| UC-A1 | Adjust replica count | 🔲 | 🔲 | 🔲 | — | |
| UC-A2 | Enable debug mode | 🔲 | 🔲 | 🔲 | — | |
| UC-A3 | Env-specific ConfigMap | ✅ | ✅ | 🔲 | — | Demo exists, needs pipeline verification |
| UC-B1 | Add app env var | 🔲 | 🔲 | 🔲 | — | |
| UC-B2 | Add app annotation | 🔲 | 🔲 | 🔲 | — | |
| UC-B3 | Add app ConfigMap entry | 🔲 | 🔲 | 🔲 | — | |
| UC-B4 | App ConfigMap with env override | ✅ | ✅ | 🔲 | — | Demo exists, needs pipeline verification |
| UC-B5 | App probe with env override | 🔲 | 🔲 | 🔲 | — | |
| UC-B6 | App env var with env override | 🔲 | 🔲 | 🔲 | — | |
| UC-C1 | Add default label | ✅ | ✅ | 🔲 | `uc-c1-default-label` | Ready for pipeline verification |
| UC-C2 | Add security context | ⚠️ | 🔲 | 🔲 | — | Schema exists, disabled by default |
| UC-C3 | Change deployment strategy | 🔲 | 🔲 | 🔲 | — | |
| UC-C4 | Add standard pod annotation | 🔲 | 🔲 | 🔲 | — | |
| UC-C5 | Platform default + app override | 🔲 | 🔲 | 🔲 | — | Multi-app pivot (uses postgres) |
| UC-C6 | Platform default + env override | 🔲 | 🔲 | 🔲 | — | |

**Status Legend:**
- 🔲 Not started
- 🚧 In progress
- ⚠️ Partial / has known issues
- ✅ Verified complete

---

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - System design and component details
- [WORKFLOWS.md](WORKFLOWS.md) - CI/CD pipeline stages and triggers
- [GIT_REMOTE_STRATEGY.md](GIT_REMOTE_STRATEGY.md) - Git subtree workflow
