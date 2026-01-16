# Scripts Directory Reorganization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reorganize 28 flat scripts into lifecycle-based folders for intuitive navigation.

**Architecture:** Create numbered folders (01-infrastructure, 02-configure, etc.), move scripts preserving git history, update internal path references, delete duplicates.

**Tech Stack:** Bash, Git

---

## Task 1: Create Folder Structure

**Files:**
- Create: `scripts/01-infrastructure/`
- Create: `scripts/02-configure/`
- Create: `scripts/03-pipelines/`
- Create: `scripts/04-operations/`
- Create: `scripts/teardown/`
- Create: `scripts/debug/`
- Create: `scripts/test/`

**Step 1: Create all directories**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
mkdir -p scripts/{01-infrastructure,02-configure,03-pipelines,04-operations,teardown,debug,test}
```

**Step 2: Verify directories exist**

```bash
ls -la scripts/
```

Expected: See 7 new directories plus existing `lib/`

**Step 3: Commit folder structure**

```bash
git add scripts/
git commit -m "chore: create scripts folder structure for reorganization"
```

---

## Task 2: Move Infrastructure Scripts (01-infrastructure)

**Files:**
- Move: `scripts/setup-all.sh` → `scripts/01-infrastructure/`
- Move: `scripts/install-microk8s.sh` → `scripts/01-infrastructure/`
- Move: `scripts/apply-infrastructure.sh` → `scripts/01-infrastructure/`
- Move: `scripts/setup-gitlab.sh` → `scripts/01-infrastructure/`
- Move: `scripts/setup-jenkins.sh` → `scripts/01-infrastructure/`
- Move: `verify-k3s-installation.sh` → `scripts/01-infrastructure/`

**Step 1: Move scripts with git mv**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git mv scripts/setup-all.sh scripts/01-infrastructure/
git mv scripts/install-microk8s.sh scripts/01-infrastructure/
git mv scripts/apply-infrastructure.sh scripts/01-infrastructure/
git mv scripts/setup-gitlab.sh scripts/01-infrastructure/
git mv scripts/setup-jenkins.sh scripts/01-infrastructure/
git mv verify-k3s-installation.sh scripts/01-infrastructure/
```

**Step 2: Verify moves**

```bash
ls scripts/01-infrastructure/
```

Expected: 6 scripts listed

**Step 3: Commit**

```bash
git commit -m "refactor: move infrastructure scripts to 01-infrastructure/"
```

---

## Task 3: Move Configure Scripts (02-configure)

**Files:**
- Move: `scripts/configure-gitlab.sh` → `scripts/02-configure/`
- Move: `scripts/configure-jenkins.sh` → `scripts/02-configure/`
- Move: `scripts/configure-nexus.sh` → `scripts/02-configure/`
- Move: `scripts/configure-gitlab-connection.sh` → `scripts/02-configure/`

**Step 1: Move scripts**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git mv scripts/configure-gitlab.sh scripts/02-configure/
git mv scripts/configure-jenkins.sh scripts/02-configure/
git mv scripts/configure-nexus.sh scripts/02-configure/
git mv scripts/configure-gitlab-connection.sh scripts/02-configure/
```

**Step 2: Verify**

```bash
ls scripts/02-configure/
```

Expected: 4 scripts listed

**Step 3: Commit**

```bash
git commit -m "refactor: move configuration scripts to 02-configure/"
```

---

## Task 4: Move Pipeline Scripts (03-pipelines)

**Files:**
- Move: `scripts/create-gitlab-projects.sh` → `scripts/03-pipelines/`
- Move: `scripts/setup-gitlab-repos.sh` → `scripts/03-pipelines/`
- Move: `scripts/setup-gitlab-env-branches.sh` → `scripts/03-pipelines/`
- Move: `scripts/ensure-gitlab-webhook.sh` → `scripts/03-pipelines/ensure-webhook.sh` (rename)
- Move: `scripts/configure-merge-requirements.sh` → `scripts/03-pipelines/`
- Move: `scripts/setup-jenkins-promote-job.sh` → `scripts/03-pipelines/`
- Move: `scripts/setup-k8s-deployments-validation-job.sh` → `scripts/03-pipelines/`
- Move: `scripts/setup-manifest-generator-job.sh` → `scripts/03-pipelines/`

**Step 1: Move scripts (with rename for ensure-webhook)**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git mv scripts/create-gitlab-projects.sh scripts/03-pipelines/
git mv scripts/setup-gitlab-repos.sh scripts/03-pipelines/
git mv scripts/setup-gitlab-env-branches.sh scripts/03-pipelines/
git mv scripts/ensure-gitlab-webhook.sh scripts/03-pipelines/ensure-webhook.sh
git mv scripts/configure-merge-requirements.sh scripts/03-pipelines/
git mv scripts/setup-jenkins-promote-job.sh scripts/03-pipelines/
git mv scripts/setup-k8s-deployments-validation-job.sh scripts/03-pipelines/
git mv scripts/setup-manifest-generator-job.sh scripts/03-pipelines/
```

**Step 2: Verify**

```bash
ls scripts/03-pipelines/
```

Expected: 8 scripts listed, including `ensure-webhook.sh`

**Step 3: Commit**

```bash
git commit -m "refactor: move pipeline scripts to 03-pipelines/

Renamed ensure-gitlab-webhook.sh to ensure-webhook.sh (more generic)"
```

---

## Task 5: Move Operations Scripts (04-operations)

**Files:**
- Move: `scripts/sync-to-gitlab.sh` → `scripts/04-operations/`
- Move: `scripts/sync-to-github.sh` → `scripts/04-operations/`
- Move: `scripts/sync-k8s-deployments.sh` → `scripts/04-operations/`
- Move: `scripts/trigger-build.sh` → `scripts/04-operations/`
- Move: `scripts/create-gitlab-mr.sh` → `scripts/04-operations/`
- Move: `scripts/validate-manifests.sh` → `scripts/04-operations/`
- Move: `scripts/docker-registry-helper.sh` → `scripts/04-operations/`
- Move: `check-health.sh` → `scripts/04-operations/`

**Step 1: Move scripts**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git mv scripts/sync-to-gitlab.sh scripts/04-operations/
git mv scripts/sync-to-github.sh scripts/04-operations/
git mv scripts/sync-k8s-deployments.sh scripts/04-operations/
git mv scripts/trigger-build.sh scripts/04-operations/
git mv scripts/create-gitlab-mr.sh scripts/04-operations/
git mv scripts/validate-manifests.sh scripts/04-operations/
git mv scripts/docker-registry-helper.sh scripts/04-operations/
git mv check-health.sh scripts/04-operations/
```

**Step 2: Verify**

```bash
ls scripts/04-operations/
```

Expected: 8 scripts listed

**Step 3: Commit**

```bash
git commit -m "refactor: move operations scripts to 04-operations/"
```

---

## Task 6: Move Remaining Scripts (teardown, debug, test)

**Files:**
- Move: `scripts/teardown-all.sh` → `scripts/teardown/`
- Move: `scripts/check-gitlab-plugin.sh` → `scripts/debug/`
- Move: `scripts/test-k8s-validation.sh` → `scripts/debug/`
- Move: `validate-pipeline.sh` → `scripts/test/`
- Move: `test-image-update-isolation.sh` → `scripts/test/`

**Step 1: Move scripts**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git mv scripts/teardown-all.sh scripts/teardown/
git mv scripts/check-gitlab-plugin.sh scripts/debug/
git mv scripts/test-k8s-validation.sh scripts/debug/
git mv validate-pipeline.sh scripts/test/
git mv test-image-update-isolation.sh scripts/test/
```

**Step 2: Verify**

```bash
ls scripts/teardown/ scripts/debug/ scripts/test/
```

Expected: teardown (1), debug (2), test (2)

**Step 3: Commit**

```bash
git commit -m "refactor: move teardown, debug, and test scripts to respective folders"
```

---

## Task 7: Delete Duplicate Scripts

**Files:**
- Delete: `scripts/setup-gitlab-webhook.sh`
- Delete: `scripts/setup-k8s-deployments-webhook.sh`

**Step 1: Delete duplicates**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git rm scripts/setup-gitlab-webhook.sh
git rm scripts/setup-k8s-deployments-webhook.sh
```

**Step 2: Verify scripts folder is clean**

```bash
ls scripts/*.sh 2>/dev/null || echo "No scripts in root - good!"
```

Expected: "No scripts in root - good!" (only lib/ folder should remain)

**Step 3: Commit**

```bash
git commit -m "refactor: remove duplicate webhook scripts

Replaced by scripts/03-pipelines/ensure-webhook.sh which:
- Takes project path as argument (more flexible)
- Is idempotent (checks before creating)
- Uses correct MultiBranch Pipeline webhook URL"
```

---

## Task 8: Update lib/config.sh Path References

Scripts in subfolders now need `../lib/config.sh` instead of `./lib/config.sh`.

**Files to modify:**
- `scripts/02-configure/configure-gitlab-connection.sh`
- `scripts/02-configure/configure-gitlab.sh`
- `scripts/02-configure/configure-jenkins.sh`
- `scripts/03-pipelines/configure-merge-requirements.sh`
- `scripts/03-pipelines/create-gitlab-projects.sh`
- `scripts/03-pipelines/setup-gitlab-repos.sh`
- `scripts/03-pipelines/setup-k8s-deployments-validation-job.sh`
- `scripts/03-pipelines/setup-manifest-generator-job.sh`
- `scripts/04-operations/create-gitlab-mr.sh`

**Step 1: Update paths using sed**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline

# Update 02-configure scripts
sed -i 's|")/lib/config.sh|")/../lib/config.sh|g' scripts/02-configure/*.sh

# Update 03-pipelines scripts  
sed -i 's|")/lib/config.sh|")/../lib/config.sh|g' scripts/03-pipelines/*.sh

# Update 04-operations scripts
sed -i 's|")/lib/config.sh|")/../lib/config.sh|g' scripts/04-operations/*.sh
```

**Step 2: Verify changes**

```bash
grep -r "lib/config.sh" scripts/0*/
```

Expected: All paths show `/../lib/config.sh`

**Step 3: Commit**

```bash
git add scripts/
git commit -m "fix: update lib/config.sh paths for new folder structure"
```

---

## Task 9: Update setup-all.sh Script References

**File:** `scripts/01-infrastructure/setup-all.sh`

**Step 1: Update SCRIPT_DIR usage**

The script uses `$SCRIPT_DIR/setup-gitlab.sh` etc. Since setup-all.sh is now in the same folder as setup-gitlab.sh, these paths still work. But it references setup-nexus.sh and setup-argocd.sh which don't exist.

Verify the script works with its new location:

```bash
grep 'SCRIPT_DIR.*\.sh' scripts/01-infrastructure/setup-all.sh
```

Expected: References like `$SCRIPT_DIR/setup-gitlab.sh` - these are fine since all are in same folder.

**Step 2: No changes needed**

The script references scripts in the same directory using `$SCRIPT_DIR`, which remains correct.

**Step 3: Commit (skip if no changes)**

No commit needed for this task.

---

## Task 10: Update CLAUDE.md Documentation

**File:** `CLAUDE.md`

**Step 1: Read current references**

```bash
grep -n "scripts/" CLAUDE.md | head -20
```

**Step 2: Update script paths**

Replace references to match new structure. Key updates:
- `./scripts/sync-to-gitlab.sh` → `./scripts/04-operations/sync-to-gitlab.sh`
- `./scripts/setup-gitlab-env-branches.sh` → `./scripts/03-pipelines/setup-gitlab-env-branches.sh`

Use editor or sed to update paths.

**Step 3: Update validate-pipeline.sh and check-health.sh paths**

These moved from root to `scripts/test/` and `scripts/04-operations/`:
- `./validate-pipeline.sh` → `./scripts/test/validate-pipeline.sh`
- `./check-health.sh` → `./scripts/04-operations/check-health.sh`

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md script paths for new structure"
```

---

## Task 11: Update Other Documentation

**File:** `docs/plans/2026-01-14-validate-pipeline-design.md`

**Step 1: Check for script references**

```bash
grep -n "validate-pipeline\|check-health" docs/plans/2026-01-14-validate-pipeline-design.md
```

**Step 2: Update paths if needed**

Update any references to the old paths.

**Step 3: Commit**

```bash
git add docs/
git commit -m "docs: update remaining docs for new script paths"
```

---

## Task 12: Verify and Final Commit

**Step 1: Check for any remaining scripts in wrong places**

```bash
ls scripts/*.sh 2>/dev/null && echo "ERROR: Scripts still in root!" || echo "OK: No scripts in scripts/ root"
ls *.sh 2>/dev/null && echo "WARNING: Scripts in project root" || echo "OK: No scripts in project root"
```

Expected: Both checks pass

**Step 2: Verify folder structure**

```bash
find scripts -type f -name "*.sh" | sort
```

Expected: All scripts in appropriate subfolders

**Step 3: Run a quick sanity check**

```bash
# Check that a moved script can still source its config
bash -n scripts/02-configure/configure-gitlab.sh && echo "Syntax OK"
```

Expected: "Syntax OK"

**Step 4: Final verification commit (if any uncommitted changes)**

```bash
git status
# If clean: done
# If changes: git add -A && git commit -m "chore: complete scripts reorganization"
```

---

## Summary

| Folder | Script Count | Purpose |
|--------|--------------|---------|
| 01-infrastructure | 6 | Deploy K8s components |
| 02-configure | 4 | Configure services |
| 03-pipelines | 8 | Set up CI/CD |
| 04-operations | 8 | Day-to-day use |
| teardown | 1 | Cleanup |
| debug | 2 | Diagnostics |
| test | 2 | Validation tests |
| lib | 1 | Shared config |

**Total: 32 files (was 28 scripts + 4 root scripts, minus 2 deleted = 30, plus lib/config.sh = 31)**

Wait, let me recount:
- 01-infrastructure: 6
- 02-configure: 4
- 03-pipelines: 8
- 04-operations: 8
- teardown: 1
- debug: 2
- test: 2
- lib: 1
- **Total: 32**

Original: 28 in scripts/ + 4 in root = 32, minus 2 deleted = 30... plus lib/config.sh already existed.

**Final: 30 scripts + 1 config = 31 shell files total**
