# Pipeline State Checks Design

## Overview

Common preflight and postflight checks to verify the pipeline is quiescent (no open MRs, no running builds, no lingering branches) before and after demo scripts.

## Problem

Demo scripts and validation scripts need to:
1. Start from a clean state (no in-flight MRs or builds interfering)
2. Verify they leave a clean state (no mess left behind)

Currently this is handled inconsistently across scripts.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Quiescent definition | No open MRs + no running builds + no lingering branches | Complete pipeline idle state |
| Preflight failure | Auto-clean with confirmation; `--force` for automation | Visible cleanup, automation-friendly |
| Postflight failure | Hard error, no cleanup | Demos must clean up after themselves |
| Scope | Both repos (example-app, k8s-deployments) | example-app builds create k8s-deployments MRs |
| Lingering branches | Treat as error | Indicates broken MR workflow |
| Integration pattern | Wrapper functions in demo-helpers.sh | Consistent with existing demo helper patterns |

## Architecture

### New File: `scripts/demo/lib/pipeline-state.sh`

Core implementation with internal functions:

```
_check_open_mrs()           → GitLab API: list open MRs in both repos
_check_running_builds()     → Jenkins API: list running/queued builds
_check_lingering_branches() → GitLab API: find update-*/promote-* branches without open MRs
_cleanup_pipeline_state()   → Close MRs, cancel builds, delete branches
check_pipeline_quiescent()  → Orchestrates all checks, returns structured result
```

### Wrappers in `demo-helpers.sh`

```bash
demo_preflight_check   # Check + offer cleanup if dirty
demo_postflight_check  # Check + hard fail if dirty
```

## Check Logic

### MR Check

Query GitLab for open MRs:
```
GET /api/v4/projects/{project_id}/merge_requests?state=opened
```

Projects:
- `p2c/example-app`
- `p2c/k8s-deployments`

### Build Check

Query Jenkins for active builds:
```
GET /job/{job}/api/json?tree=builds[number,result,building]
GET /queue/api/json
```

Jobs:
- `example-app-ci`
- `k8s-deployments-ci` (all branches)

### Branch Check

Query GitLab for branches:
```
GET /api/v4/projects/{id}/repository/branches?search=update-
GET /api/v4/projects/{id}/repository/branches?search=promote-
```

A branch is "lingering" if it matches the pattern but has no corresponding open MR.

## Cleanup Logic

### `_cleanup_pipeline_state`

- **Close MRs**: `PUT /api/v4/projects/{id}/merge_requests/{iid}` with `state_event=close`
- **Cancel builds**: `POST /job/{job}/{number}/stop` (running), `POST /queue/cancelItem?id={id}` (queued)
- **Delete branches**: `DELETE /api/v4/projects/{id}/repository/branches/{branch}`

## Behavior

### Preflight (`demo_preflight_check`)

```
1. Call check_pipeline_quiescent()
2. If clean: log success, return 0
3. If dirty:
   a. Display findings (MRs, builds, branches)
   b. If DEMO_FORCE_CLEANUP=1: auto-clean, return 0
   c. Else: prompt "Clean up and continue? [y/N]"
      - y: cleanup, verify, return 0
      - n: exit 1
```

### Postflight (`demo_postflight_check`)

```
1. Call check_pipeline_quiescent()
2. If clean: log success, return 0
3. If dirty:
   a. Display findings
   b. Log error: "Demo left pipeline in dirty state"
   c. exit 1
```

## Integration

### Use Case Script Pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/demo-helpers.sh"

demo_header "UC-XX: Description"
demo_preflight_check

# ... demo logic ...

demo_postflight_check
demo_header "UC-XX Complete"
```

### validate-pipeline.sh Integration

```bash
preflight_checks        # existing: config, credentials, cluster
demo_preflight_check    # new: MRs, builds, branches clear

# ... validation logic ...

demo_postflight_check   # new: verify clean state
```

### run-all-demos.sh Integration

```bash
./run-all-demos.sh --force   # Sets DEMO_FORCE_CLEANUP=1, auto-cleans
./run-all-demos.sh           # Interactive, prompts on dirty state
```

## Files to Create

| File | Purpose |
|------|---------|
| `scripts/demo/lib/pipeline-state.sh` | Core check/cleanup implementation (~150-200 lines) |

## Files to Modify

| File | Change |
|------|--------|
| `scripts/demo/lib/demo-helpers.sh` | Add `demo_preflight_check`, `demo_postflight_check` wrappers |
| `scripts/demo/demo-uc-c1-default-label.sh` | Add preflight/postflight calls |
| `scripts/demo/demo-uc-c4-prometheus-annotations.sh` | Add preflight/postflight calls |
| `scripts/demo/demo-uc-c6-platform-env-override.sh` | Add preflight/postflight calls |
| `scripts/demo/demo-app-override.sh` | Add preflight/postflight calls |
| `scripts/demo/demo-env-configmap.sh` | Add preflight/postflight calls |
| `scripts/test/validate-pipeline.sh` | Add preflight/postflight calls after existing preflight_checks() |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `DEMO_FORCE_CLEANUP` | Set to `1` to skip confirmation and auto-clean (for CI/automation) |

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Pipeline quiescent (or cleaned successfully) |
| `1` | Dirty state: user declined cleanup (preflight) or dirty state found (postflight) |

## Dependencies

- `scripts/lib/credentials.sh` - GitLab/Jenkins token loading
- `scripts/lib/infra.sh` - Project paths, URLs
- `scripts/lib/logging.sh` - Output formatting
