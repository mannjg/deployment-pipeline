# JENKINS-04: Extract merge-preview conflict resolution to a script

## Overview

Extract the ~70-line shell block inside `mergeTargetBranchForPreview()` in `k8s-deployments/Jenkinsfile` into `k8s-deployments/scripts/merge-preview.sh`.

## Script Interface

**Path:** `k8s-deployments/scripts/merge-preview.sh`
**Usage:** `./scripts/merge-preview.sh [--promote] <targetEnv>`

- `--promote` — optional flag indicating a promote branch (affects env.cue conflict strategy)
- `<targetEnv>` — required, the target environment branch (dev, stage, prod)
- Exit 0 on success, exit 1 on failure
- Uses `set -euo pipefail`
- No Jenkins-specific dependencies (no preflight.sh, no env vars beyond git)

## Conflict Resolution Flow

1. Fetch and merge target branch (`--no-commit --no-edit || true`)
2. Resolve env.cue conflicts: promote keeps ours, feature takes theirs
3. Resolve manifests/ conflicts: always keep ours (derivative files)
4. Resolve .mr-trigger conflicts: always keep ours
5. Resolve services/ conflicts: always keep ours
6. Check for remaining unresolved conflicts — exit 1 if any
7. Commit merge if staged changes exist
8. Verify env.cue exists post-merge

Git identity config (`user.name`/`user.email`) is NOT set by this script — that's the caller's responsibility.

## Groovy Wrapper

```groovy
def mergeTargetBranchForPreview(String targetEnv, boolean isPromoteBranch = false) {
    try {
        sh "./scripts/merge-preview.sh ${isPromoteBranch ? '--promote ' : ''}${targetEnv}"
        return true
    } catch (Exception e) {
        echo "Warning: Could not merge ${targetEnv}: ${e.message}"
        return false
    }
}
```

Call site unchanged. Signature, return semantics, and error handling identical to current implementation.
