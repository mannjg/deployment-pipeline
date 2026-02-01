# Use Case Gap Analysis

**Date:** 2026-02-01
**Status:** Design Complete

## Context

This reference implementation validates CUE-based GitOps for deploying changes through dev→stage→prod environments. The use cases ensure the CUE layering system is functionally correct and the pipelines work as expected.

The architecture supports:
- **N first-party apps** (like example-app) with full CI/CD
- **M third-party apps** (like postgres) with image-only management

## Current State

| Category | Focus | Count | Status |
|----------|-------|-------|--------|
| A: Environment-Specific | Config that stays isolated | 3 | ✅ All verified |
| B: App-Level | Config that propagates to all envs for an app | 6 | ✅ All verified |
| C: Platform-Wide | Config that propagates to all apps, all envs | 6 | ✅ All verified |
| D: Operational | Non-happy-path scenarios | 5 | ✅ All verified |
| E: App Lifecycle | Code changes flowing through pipeline | 1 | ✅ Verified |
| **Total** | | **21** | |

## Identified Gaps

### E-Series: App Lifecycle (3 additions)

The E-series currently has only UC-E1 (full promotion), while A-D each have 3-6 use cases. The following scenarios are realistic and need validation.

#### UC-E2: App Code + Config Change Together

| Aspect | Detail |
|--------|--------|
| **Story** | "As a developer, I push a code change that also requires a new environment variable, and both flow through the pipeline together" |
| **Trigger** | Code change + `deployment/app.cue` modification in same commit |
| **Flow** | 1. Developer modifies source code AND adds `appEnvVars` entry in `deployment/app.cue`<br>2. Jenkins builds app, publishes image<br>3. App CI creates MR to k8s-deployments dev with BOTH image tag update AND merged CUE config<br>4. Merge → manifests include new env var<br>5. Promotion MRs carry both changes through stage→prod |
| **Expected Behavior** | New image AND new config deploy atomically; no partial state where image expects env var that doesn't exist |
| **Validates** | Pipeline correctly extracts and merges `deployment/app.cue` changes alongside image updates |

#### UC-E3: Multiple App Versions In Flight

| Aspect | Detail |
|--------|--------|
| **Story** | "Production runs v1.0.40, stage has v1.0.41 under QA review, dev has v1.0.42 for new feature testing — all simultaneously" |
| **Trigger** | Normal development pace where promotions aren't instant |
| **Setup** | Three consecutive version bumps with deliberate pauses between promotion merges |
| **Expected Behavior** | Each environment maintains its own image tag in `env.cue`; promotions don't overwrite pending changes in other environments |
| **Validates** | Environment isolation; promotion only moves the specific app version being promoted |

#### UC-E4: App-Level Rollback

| Aspect | Detail |
|--------|--------|
| **Story** | "v1.0.42 deployed to prod has a bug. Roll back to v1.0.41 image while preserving prod's env.cue settings (replicas, resources)" |
| **Trigger** | Direct MR to prod branch updating only the image tag |
| **Change** | `deployment.image.tag: "1.0.42"` → `deployment.image.tag: "1.0.41"` |
| **Expected Behavior** | Prod rolls back to previous image; prod's replicas/resources unchanged; dev/stage unaffected |
| **Contrast with UC-D3** | D3 uses git revert (rolls back entire commit); E4 surgically changes only the image tag |
| **Validates** | Image tag can be changed independently; env.cue structure supports targeted rollback |

---

### F-Series: App Lifecycle Management (new category, 4 use cases)

These scenarios cover the full lifecycle of applications in the system — from onboarding through decommissioning.

#### UC-F1: Onboard New 1st-Party App

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, I onboard a new team's application (user-service) to the deployment pipeline" |
| **Precondition** | New app repo exists with `deployment/app.cue` following the schema |
| **Steps** | 1. Create Jenkins job for new app (or use shared multibranch pipeline)<br>2. First merge to app's main triggers CI<br>3. CI creates `services/apps/user-service.cue` in k8s-deployments<br>4. CI adds app entry to each environment's `env.cue`<br>5. Manifests generated under `manifests/<env>/user-service/` |
| **Expected Behavior** | New app flows through dev→stage→prod like existing apps; no changes to platform CUE required |
| **Validates** | CUE schema is generic enough for N apps; pipeline supports app registration |

#### UC-F2: Onboard New 3rd-Party App

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, I add Redis as a new 3rd-party dependency managed through the pipeline" |
| **Precondition** | No app repo; image comes from external registry or is mirrored to Nexus |
| **Steps** | 1. Create `services/apps/redis.cue` manually (no CI to extract it)<br>2. Add redis entry to each environment's `env.cue` with image tag<br>3. Create MR to dev branch<br>4. Merge → manifests generated<br>5. Promotion follows normal MR workflow |
| **Key Difference** | No app CI; image tags updated manually or via platform automation |
| **Expected Behavior** | Redis deploys to all environments; follows same promotion workflow as 1st-party apps |
| **Validates** | Pipeline supports apps without CI; CUE works for externally-managed images |

#### UC-F3: Decommission an App

| Aspect | Detail |
|--------|--------|
| **Story** | "As a platform team, I retire legacy-service from all environments" |
| **Steps** | 1. Remove app entry from prod's `env.cue` → MR → merge → ArgoCD removes from prod<br>2. Remove from stage's `env.cue` → MR → merge → ArgoCD removes from stage<br>3. Remove from dev's `env.cue` → MR → merge → ArgoCD removes from dev<br>4. Remove `services/apps/legacy-service.cue` from main<br>5. Archive/delete app repo and Jenkins job |
| **Order** | Prod → Stage → Dev (reverse of deployment order) |
| **Expected Behavior** | ArgoCD prunes resources when app removed from manifests; clean removal with audit trail |
| **Validates** | Removal flows through GitOps; ArgoCD prune works correctly; no orphaned resources |

#### UC-F4: Coordinated Multi-App Deployment

| Aspect | Detail |
|--------|--------|
| **Story** | "example-app v2.0 requires postgres 17 (currently on 16). They must deploy together to avoid incompatibility" |
| **Challenge** | Normal promotion is per-app; need to group these changes |
| **Approach** | Single MR containing both app updates to each environment branch |
| **Steps** | 1. Update both example-app image and postgres image in dev's `env.cue` in same MR<br>2. Merge → both deploy to dev atomically<br>3. Create single promotion MR to stage with both changes<br>4. Repeat for prod |
| **Expected Behavior** | Both apps promote together; no window where incompatible versions coexist |
| **Constraint** | Requires manual coordination; auto-promote creates per-app MRs |
| **Validates** | Multiple apps can be updated atomically; MR-based workflow supports grouping |

---

## Updated Category Structure

| Category | Focus | Count |
|----------|-------|-------|
| A: Environment-Specific | Config that stays isolated | 3 |
| B: App-Level | Config that propagates to all envs for an app | 6 |
| C: Platform-Wide | Config that propagates to all apps, all envs | 6 |
| D: Operational | Non-happy-path scenarios | 5 |
| E: App Lifecycle | Code changes flowing through pipeline | 4 (was 1) |
| **F: App Management** | **Onboarding, decommissioning, coordination** | **4 (new)** |
| **Total** | | **28 (was 21)** |

---

## Implementation Considerations

### Tooling Opportunities

**UC-F1 and UC-F2** would benefit from scripted tooling:
- `scripts/04-operations/onboard-app.sh` — automates app registration steps
- Ensures consistent CUE structure and env.cue entries across environments

### Known Constraints

**UC-F4 (Coordinated Multi-App Deployment)** highlights a limitation:
- Auto-promote creates per-app MRs
- Coordinated deployments require manual MR creation
- Options:
  1. Document as known constraint (acceptable for rare scenarios)
  2. Add `--group` flag to promotion tooling for explicit grouping
  3. Add `[coordinate-with: app-name]` marker in commit messages

### Demo Script Patterns

New use cases should follow existing demo script patterns:
- Located in `scripts/demo/demo-uc-<id>-<name>.sh`
- Self-contained with setup, execution, verification, and cleanup
- Idempotent and safe to run multiple times
- Uses `reset-demo-state.sh` as prerequisite

---

## Implementation Priority

Recommended implementation order based on validation value:

| Priority | Use Cases | Rationale |
|----------|-----------|-----------|
| 1 | UC-E2, UC-E4 | Core app lifecycle scenarios; high frequency in real usage |
| 2 | UC-F1, UC-F2 | Onboarding is first thing new teams encounter |
| 3 | UC-E3 | Validates isolation but scenario emerges naturally |
| 4 | UC-F3, UC-F4 | Less frequent; can document process without full automation |

---

## Next Steps

1. Update `docs/USE_CASES.md` with new E-series and F-series use cases
2. Implement demo scripts for priority 1 use cases (UC-E2, UC-E4)
3. Create onboarding tooling for UC-F1/UC-F2
4. Add implementation status tracking to USE_CASES.md
