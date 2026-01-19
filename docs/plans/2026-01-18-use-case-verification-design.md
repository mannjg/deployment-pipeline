# Use Case Verification Design

This document defines the verification framework for validating all k8s-deployments use cases through full pipeline execution.

## Goals

- Verify each use case works end-to-end through the actual pipeline
- Establish a TDD-style loop: use case defines requirement, demo script validates, implementation aligns
- Ensure correctness for a reference implementation
- Support tight iteration loops with context handoff between worker agents

## Prerequisites

### Jenkins-Only Automation

**Critical:** All CI/CD automation runs through Jenkins, not GitLab CI.

GitLab is used only for:
- Source control (git repository)
- Merge request workflow (MR creation, approval, merge)
- Commit status display (Jenkins reports status back to GitLab)

GitLab is NOT used for:
- Pipeline execution (no `.gitlab-ci.yml`)
- Auto DevOps (must be disabled on all projects)

**Required GitLab project settings:**
```bash
# Disable Auto DevOps on k8s-deployments
curl -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "${GITLAB_URL}/api/v4/projects/p2c%2Fk8s-deployments" \
  -d "auto_devops_enabled=false"

# Disable Auto DevOps on example-app
curl -X PUT -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "${GITLAB_URL}/api/v4/projects/p2c%2Fexample-app" \
  -d "auto_devops_enabled=false"
```

**Why Jenkins:**
- Airgapped environment compatibility (no GitLab runners needed)
- Centralized CI/CD management
- Existing infrastructure integration
- Reference implementation for enterprise patterns

## Verification Framework

### The TDD Loop

Each use case follows this verification cycle:

```
1. Create branch: uc-<id>-<description>
2. Assess current state (CUE support, gaps)
3. Implement any missing CUE schema/template support
4. Write/update demo script with assertions
5. Run demo script (triggers full pipeline)
6. Assert K8s state matches expectations
7. Assert cross-environment isolation/propagation
8. Update USE_CASES.md status table
9. Merge branch, move to next use case
```

### Failure Triage

- **Foundational failure** (CUE schema can't express it, template doesn't propagate): Stop, fix immediately. These block downstream use cases.
- **Surface failure** (demo script bug, assertion edge case): Document in USE_CASES.md, create issue, continue to next use case.

### Quality Bar

Each use case is verified when:

- [ ] CUE change made (human intent)
- [ ] MR pipeline generates manifests
- [ ] MR shows both CUE + YAML diff
- [ ] MR pipeline passes verification
- [ ] MR merged to env branch
- [ ] ArgoCD syncs successfully
- [ ] kubectl assertions confirm K8s state
- [ ] Cross-env isolation/propagation verified

## Execution Order

### Rationale

Start with Category C (platform-wide) because:
1. Platform layer is the foundation - if broken, everything else fails
2. Tests the full override chain (Platform → App → Env)
3. Changes here affect all apps/environments

### Phase Order

| Phase | Use Cases | Apps | Key Milestone |
|-------|-----------|------|---------------|
| 1 | UC-C1, UC-C4, UC-C3 | example-app | Platform defaults propagate |
| 2 | UC-C6 | example-app | Env can override platform |
| 3 | UC-C2 | example-app | Security context works |
| 4 | UC-C5 | example-app + postgres | Multi-app verified |
| 5 | UC-B1 through UC-B6 | both apps | App-level propagation |
| 6 | UC-A1 through UC-A3 | both apps | Env isolation confirmed |

### Category C Order (Platform-Wide)

1. **UC-C1** - Add default label (simplest addition, establishes pattern)
2. **UC-C4** - Add standard pod annotation (similar pattern, validates consistency)
3. **UC-C3** - Change deployment strategy (modifies existing value)
4. **UC-C6** - Platform default with env override (validates override chain)
5. **UC-C2** - Add pod security context (complex template change)
6. **UC-C5** - Platform default with app override (multi-app pivot point)

## MR-Gated Verification Flow

### Core Pattern

The demo script does NOT generate manifests. The pipeline does. This is a key feature of the project.

```
Demo Script                          Pipeline                         GitLab/ArgoCD
    │                                    │                                  │
    ├─ Make CUE change ──────────────────┼──────────────────────────────────┤
    ├─ Commit CUE only                   │                                  │
    ├─ Push to feature branch            │                                  │
    ├─ Create MR → env branch ───────────┼──────────────────────────────────┤
    │                                    │                                  │
    │                                    ├─ Triggered by MR                 │
    │                                    ├─ Generate manifests from CUE     │
    │                                    ├─ Commit YAML to MR branch        │
    │                                    ├─ Run verification                │
    │                                    ├─ Report status ──────────────────┤
    │                                    │                                  │
    ├─ Assert MR contains:               │                                  │
    │   - CUE change (intent)            │                                  │
    │   - Generated YAML (result)        │                                  │
    ├─ Assert pipeline passed            │                                  │
    ├─ Accept/merge MR ──────────────────┼──────────────────────────────────┤
    │                                    │                                  │
    │                                    │                    ├─ ArgoCD syncs
    │                                    │                    ├─ Deploys to K8s
    │                                    │                                  │
    ├─ Wait for ArgoCD sync              │                                  │
    ├─ Assert K8s state                  │                                  │
    └─ Log success                       │                                  │
```

### Verification Assertions

Three levels of assertion for each use case:

1. **Resource exists**: `kubectl get` returns success
2. **Field value matches**: `kubectl get -o jsonpath` extracts and compares
3. **Cross-environment**: Verify isolation (Category A) or propagation (Category B/C)

## Demo Script Architecture

### Directory Structure

```
scripts/demo/
├── lib/
│   ├── demo-helpers.sh      # Existing - output, git, cleanup
│   ├── cue-edit.py          # Existing - CUE file manipulation
│   ├── assertions.sh        # NEW - K8s verification functions
│   └── pipeline-wait.sh     # NEW - MR/pipeline/ArgoCD helpers
├── demo-env-configmap.sh    # Existing (UC-A3)
├── demo-app-override.sh     # Existing (UC-B4)
├── demo-uc-c1-default-label.sh
├── demo-uc-c2-security-context.sh
├── ...                      # One per use case (15 total)
└── run-all-demos.sh         # NEW - sequential runner
```

### Language Strategy

- **Shell** for orchestration, calling CLI tools, simple assertions
- **Python** for complex parsing, CUE file manipulation

### New Helper: assertions.sh

```bash
# Assert resource exists
assert_resource_exists <namespace> <kind> <name>

# Assert field value matches
assert_field_equals <namespace> <kind> <name> <jsonpath> <expected>

# Assert field does NOT exist
assert_field_absent <namespace> <kind> <name> <jsonpath>

# Assert cross-environment isolation
assert_env_isolation <kind> <name> <jsonpath> <expected> <env_has> <env_lacks>

# Assert cross-environment propagation
assert_env_propagation <kind> <name> <jsonpath> <expected> <envs...>

# Assert MR diff contains expected content
assert_mr_contains_diff <mr_id> <file_pattern> <expected_content>
```

### New Helper: pipeline-wait.sh

```bash
# Create MR and return MR ID
create_mr <source_branch> <target_branch> <title> → mr_id

# Wait for MR pipeline to complete
wait_for_mr_pipeline <mr_id> <timeout> → pass/fail

# Accept/merge MR
accept_mr <mr_id>

# Wait for ArgoCD sync
wait_for_argocd_sync <app> <timeout>

# Combined flow for one environment
promote_via_mr <source> <target_env> <title> <timeout>
```

## Status Tracking

### USE_CASES.md Status Table

Add to USE_CASES.md:

```markdown
## Implementation Status

| ID | Use Case | CUE Support | Demo Script | Pipeline Verified | Branch | Notes |
|----|----------|-------------|-------------|-------------------|--------|-------|
| UC-C1 | Add default label | 🔲 | 🔲 | 🔲 | — | Not started |
| UC-C2 | Add security context | 🔲 | 🔲 | 🔲 | — | Not started |
...
```

### Status Icons

- 🔲 Not started
- 🚧 In progress
- ⚠️ Partial / has known issues
- ✅ Verified complete

## Agent Context Handoff

### Branch Artifacts

Each branch contains everything an agent needs to resume:

- Commit messages tell the story of progress
- USE_CASES.md status row shows current state
- Demo script documents expected behavior

### Agent Prompt Pattern

```
Resume work on UC-C1 (Add Default Label to All Deployments).

Context:
- Branch: uc-c1-default-label
- Current status: [read from USE_CASES.md]
- Use case requirements: [from USE_CASES.md UC-C1 row]

Instructions:
- Follow verification flow in this design doc
- Run demo script to verify current state
- If assertions fail, triage: foundational → fix, surface → document
- Update USE_CASES.md status when complete
```

## Branch Naming Convention

Pattern: `uc-<id>-<short-description>`

Examples:
- `uc-c1-default-label`
- `uc-c5-app-override-postgres`
- `uc-a3-env-configmap`
- `uc-b4-configmap-override`

## Multi-App Strategy

### Pivot Point: UC-C5

UC-C5 is where postgres becomes the second app for multi-app verification.

### Why Postgres

- Already defined in `services/apps/postgres.cue`
- Different shape (stateful, PVC, exec probes)
- Proves platform layer handles diverse workloads

### After UC-C5

Both example-app and postgres are used for remaining use cases to verify multi-app correctness.

## Deliverables

1. `scripts/demo/lib/assertions.sh` - K8s verification functions
2. `scripts/demo/lib/pipeline-wait.sh` - MR/pipeline/ArgoCD helpers
3. 15 demo scripts (one per use case)
4. `scripts/demo/run-all-demos.sh` - full verification runner
5. Updated USE_CASES.md with status table
6. This design document

## Related Documentation

- [USE_CASES.md](../USE_CASES.md) - Use case definitions
- [WORKFLOWS.md](../WORKFLOWS.md) - Pipeline details
- [ARCHITECTURE.md](../ARCHITECTURE.md) - System design
