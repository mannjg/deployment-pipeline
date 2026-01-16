# Design: Event-Driven Environment Promotion

**Date**: 2026-01-16
**Status**: Approved

## Problem Statement

Currently, environment promotion (dev→stage→prod) requires manual triggering of the `promote-environment` Jenkins job or is simulated by `validate-pipeline.sh`. This creates friction and doesn't reflect the intended GitOps workflow where promotion should be event-driven.

## Intent

Developers code individual apps in individual repos. `example-app` is representative, but this architecture supports many applications deployed to shared environments. Each environment (dev/stage/prod) is represented by a branch in `k8s-deployments`, containing environment-specific `env.cue` and generated manifest YAMLs.

**Desired workflow:**
1. App CI builds software, creates artifacts, creates MR to k8s-deployments dev branch
2. Human reviews MR (sees CUE diffs AND manifest diffs), merges
3. ArgoCD syncs dev cluster
4. **Automatically**: Stage promotion MR is created
5. Human verifies dev health, reviews stage MR, merges
6. ArgoCD syncs stage cluster
7. **Automatically**: Prod promotion MR is created
8. Human verifies stage health, reviews prod MR carefully, merges
9. ArgoCD syncs prod cluster

**Key insight**: We don't need to wait for healthy deployment before creating the promotion MR. The MR creation is cheap, and humans verify health before accepting the next promotion.

---

## Design Decisions

### 1. Promotion Logic Lives in k8s-deployments

**Decision**: The k8s-deployments repository owns all promotion logic, not app repos.

**Rationale**:
- App CI shouldn't know about promotion paths
- Adding new apps doesn't require CI/CD infrastructure changes
- Platform team controls promotion workflow
- Single place to modify promotion behavior

### 2. Jenkins Over GitLab CI

**Decision**: Use Jenkins for auto-promotion (not GitLab CI).

**Rationale**:
- Team familiarity with Jenkins
- Consistent tooling (all CI/CD in Jenkins)
- Existing credential management
- Already have `promote-environment` job to reuse

**Trade-off**: Requires webhook configuration (one-time setup).

### 3. Webhook-Triggered on Merge

**Decision**: GitLab webhook fires on push to dev/stage branches (which occurs after MR merge), triggering Jenkins auto-promote job.

**Rationale**:
- Immediate response (no polling)
- Simple trigger mechanism
- Works for any number of applications
- MR merge is the definitive "deployment approved" signal

### 4. No Health-Gate for MR Creation

**Decision**: Create promotion MRs immediately after merge, without waiting for ArgoCD health status.

**Rationale**:
- MR creation is cheap and non-destructive
- Human reviewer is the gate (they check health before merging)
- Avoids complexity of health-checking in Jenkins
- ArgoCD already reports health status for reviewers to see
- If deployment is unhealthy, reviewer closes MR and fixes issues

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EVENT-DRIVEN PROMOTION                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  App CI (Jenkins)              k8s-deployments              ArgoCD          │
│  ┌──────────────┐              ┌──────────────┐           ┌─────────┐      │
│  │ Build/Test   │              │              │           │         │      │
│  │ Publish      │──MR─────────▶│ dev branch   │──watch───▶│ dev     │      │
│  │ Create MR    │              │     │        │           │ cluster │      │
│  │ DONE         │              │     │ merge  │           │         │      │
│  └──────────────┘              │     ▼        │           └─────────┘      │
│                                │  webhook     │                             │
│                                │     │        │                             │
│  Auto-Promote (Jenkins)        │     ▼        │           ┌─────────┐      │
│  ┌──────────────┐              │ ┌────────┐   │           │         │      │
│  │ Detect apps  │◀─────────────│ │ push   │   │           │ stage   │      │
│  │ Trigger      │              │ │ event  │   │           │ cluster │      │
│  │ promote job  │──MR─────────▶│ └────────┘   │──watch───▶│         │      │
│  └──────────────┘              │              │           └─────────┘      │
│                                │ stage branch │                             │
│                                │     │        │                             │
│                                │     │ merge  │           ┌─────────┐      │
│                                │     ▼        │           │         │      │
│                                │  webhook ────┼──────────▶│ prod    │      │
│                                │     │        │           │ cluster │      │
│                                │     ▼        │           └─────────┘      │
│                                │ prod branch  │                             │
│                                └──────────────┘                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Components to Create/Modify

### New Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `Jenkinsfile.auto-promote` | `k8s-deployments/jenkins/pipelines/` | Pipeline triggered by webhook, detects changed apps, triggers promote-environment |
| `setup-jenkins-auto-promote-job.sh` | `scripts/03-pipelines/` | Creates the Jenkins job via API (idempotent) |
| `setup-auto-promote-webhook.sh` | `scripts/03-pipelines/` | Configures GitLab webhook for k8s-deployments (idempotent) |

### Modified Components

| Component | Change |
|-----------|--------|
| `docs/WORKFLOWS.md` | Already updated - documents event-driven promotion |
| `docs/ARCHITECTURE.md` | Already updated - documents multi-app intent |
| `CLAUDE.md` | Already updated - documents promotion flow |

### Removed Components

| Component | Reason |
|-----------|--------|
| `example-app/vars/waitForHealthyDeployment.groovy` | Not needed - ArgoCD handles health, humans verify before merge |
| `example-app/scripts/` (empty dir) | Already cleaned up |
| `example-app/vars/` (if empty after removal) | Clean up empty directory |

---

## Jenkinsfile.auto-promote Behavior

1. **Triggered by**: GitLab webhook on push to `dev` or `stage` branch
2. **Determines**: Which branch was pushed to (source environment)
3. **Looks up**: Target environment from promotion map (dev→stage, stage→prod)
4. **Detects**: Which apps changed by examining `manifests/` directory diff
5. **Triggers**: `promote-environment` job for each changed app (non-blocking)
6. **Completes**: Immediately after triggering (doesn't wait for promotion jobs)

---

## Webhook Configuration

| Setting | Value |
|---------|-------|
| GitLab Project | `p2c/k8s-deployments` |
| URL | `http://jenkins.jenkins.svc.cluster.local:8080/generic-webhook-trigger/invoke?token=k8s-deployments-auto-promote` |
| Trigger | Push events |
| Branch filter | `dev`, `stage` (not `main`, not `prod`) |
| SSL Verification | Disabled (internal cluster) |

---

## Idempotency Requirements

All setup scripts must be idempotent:

- **Jenkins job setup**: Check if job exists, update if exists, create if not
- **Webhook setup**: Check if webhook exists with correct URL, update/create as needed
- **No manual steps**: Everything scriptable for reproducibility

---

## Success Criteria

1. Merging an MR to `dev` branch automatically creates a `stage` promotion MR
2. Merging an MR to `stage` branch automatically creates a `prod` promotion MR
3. Merging to `prod` does not trigger any further action
4. Multiple apps changed in one merge each get their own promotion MR
5. Scripts are idempotent and can be re-run safely
6. `validate-pipeline.sh` continues to work (may need minor updates)

---

## Open Questions

None - design has been validated through discussion.

---

## Approval

- [x] Design reviewed and approved (2026-01-16)
- [x] Ready for implementation planning
