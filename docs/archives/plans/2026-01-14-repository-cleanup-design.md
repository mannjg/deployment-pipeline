# Repository Cleanup Design

**Date:** 2026-01-14
**Status:** Approved

## Goal

Clean up the deployment-pipeline repository to:
1. Purge outdated information
2. Establish high quality standards (prioritized: actionability > accuracy > completeness > conciseness)
3. Create a single agent-oriented entry point

## Target Audience

- The repository owner
- Agentic coders (AI coding assistants)

## Key Problems Being Solved

1. **Confusion about what's current** - Hard to tell archived/old from active/current
2. **Missing context** - Agents ask questions the docs should answer
3. **Dead references** - Links, paths, or commands that no longer work
4. **Conflicting information** - Docs that contradict each other

## Solution: Agent-First Single Entry Point

Create one `CLAUDE.md` file as the single source of truth for agents. Aggressively delete or archive everything else.

### Final Structure

```
CLAUDE.md                          ← Agent entry point (NEW)
README.md                          ← Minimal human-facing overview (REWRITE)
docs/
  ARCHITECTURE.md                  ← Keep (reference)
  GIT_REMOTE_STRATEGY.md           ← Keep (critical, current)
  WORKFLOWS.md                     ← Keep (reference)
  archives/                        ← Historical docs (may be stale)
    plans/                         ← Moved design docs here
    [existing archived docs]
```

## CLAUDE.md Structure

1. **Project Overview** - What this repo is
2. **Git Remote Strategy (Critical)** - GitHub = complete, GitLab = subtrees for CI/CD
3. **Repository Layout** - Key directories and purposes
4. **Current State** - What's working, limitations, last verified
5. **Service Access** - URLs, credential locations
6. **Common Operations** - Build, deploy, promote, sync
7. **Infrastructure Notes** - MicroK8s, namespaces
8. **Documentation Index** - Links to remaining docs

## Documentation Triage

### Keep (Active)
| File | Reason |
|------|--------|
| `docs/GIT_REMOTE_STRATEGY.md` | Current, critical, well-written |
| `docs/ARCHITECTURE.md` | Good reference for system design |
| `docs/WORKFLOWS.md` | Useful workflow reference |

### Delete
| File | Reason |
|------|--------|
| `QUICKSTART.md` | Superseded by CLAUDE.md |
| `ACCESS.md` | Merged into CLAUDE.md |
| `REFACTORING_SUMMARY.md` | Historical, one-time use |
| `K3S_INSTALLATION_ANALYSIS.md` | Analysis doc, not operational |
| `JENKINS_SETUP_GUIDE.md` | One-time setup, complete |
| `GITHUB_SYNC.md` | Superseded by GIT_REMOTE_STRATEGY.md |
| `docs/IMPLEMENTATION_STATUS.md` | Stale phase tracking |
| `docs/TROUBLESHOOTING.md` | Merge useful bits or delete |
| `docs/PHASE2_TEST_GUIDE.md` | One-time test guide |
| `docs/MULTI_REPO_ARCHITECTURE.md` | Superseded by GIT_REMOTE_STRATEGY.md |

### Archive (Move to docs/archives/)
- `docs/plans/*` - Historical design docs

### Rewrite
- `README.md` - Currently describes example-app; rewrite as minimal pointer to CLAUDE.md

## Implementation Phases

### Phase 1: Create CLAUDE.md
1. Read remaining docs to extract accurate current state info
2. Write CLAUDE.md with agreed structure
3. Verify accuracy of URLs, paths, and operations

### Phase 2: Clean Up Root
1. Delete obsolete root markdown files
2. Rewrite README.md

### Phase 3: Clean Up docs/
1. Delete obsolete docs
2. Move plans to archives
3. Keep active reference docs

### Phase 4: Verification
1. Ensure no broken internal links
2. Verify CLAUDE.md accuracy
3. Commit all changes
