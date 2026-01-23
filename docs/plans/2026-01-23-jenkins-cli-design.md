# Jenkins CLI Design

## Overview

A centralized CLI for common Jenkins operations, replacing ad-hoc curl commands scattered throughout the codebase.

## Interface

```bash
# Get console output for last build
./scripts/04-operations/jenkins-cli.sh console example-app/main

# Get console for specific build number
./scripts/04-operations/jenkins-cli.sh console example-app/main 138

# Get build status (JSON output)
./scripts/04-operations/jenkins-cli.sh status k8s-deployments/dev
# Output: {"number":1078,"result":"SUCCESS","building":false,"timestamp":1769196182}

# Wait for current build to complete (default 5min timeout)
./scripts/04-operations/jenkins-cli.sh wait example-app/main

# Wait with custom timeout
./scripts/04-operations/jenkins-cli.sh wait example-app/main --timeout 600
```

## Job Path Notation

Uses slash notation that maps to Jenkins MultiBranch paths:
- `example-app/main` → `example-app/job/main`
- `k8s-deployments/dev` → `k8s-deployments/job/dev`

## Exit Codes

- `0` - Success
- `1` - Error (network, auth, job not found)
- `2` - Timeout (for `wait` command)

## Output Conventions

- `console` - Raw console text to stdout
- `status` - JSON to stdout (machine-parseable)
- `wait` - Progress to stderr, final status JSON to stdout
- All errors go to stderr

## Implementation

Location: `scripts/04-operations/jenkins-cli.sh`

Reuses existing libraries:
- `lib/credentials.sh` - Jenkins auth from env or K8s secret
- `lib/infra.sh` - `JENKINS_URL_EXTERNAL`
- `lib/logging.sh` - Error formatting

Uses temp file pattern for curl+jq to avoid pipe issues.

## Future Work

Tracked separately: Refactor existing scripts to use this CLI for consistency. See task backlog.

Candidates for refactoring:
- `scripts/test/validate-pipeline.sh` (12 curl calls)
- `scripts/demo/lib/pipeline-wait.sh` (6 calls)
- `scripts/demo/lib/pipeline-state.sh` (6 calls)
- `scripts/03-pipelines/reset-demo-state.sh` (5 calls)
- `scripts/04-operations/check-health.sh` (3 calls)

Potential additional subcommands:
- `trigger` - Trigger a build
- `queue` - Check queue status
- `cancel` - Cancel builds/queue items
