# Fix UC-A3 and UC-B4 CUE Validation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix CUE validation errors in UC-A3 and UC-B4 demo scripts by using correct editing patterns for each file type.

**Architecture:**
- Files in `services/` exist locally on main branch and should be edited locally, validated with `cue vet -c=false ./...`, pushed via GitLab API
- `env.cue` does NOT exist locally (only on env branches in GitLab), so it must be fetched, modified in memory, and pushed back without local CUE validation (Jenkins CI validates after push)

**Tech Stack:** Bash, GitLab API, CUE

---

## Problem Analysis

| File Type | Exists on main? | Edit Pattern | Validation |
|-----------|-----------------|--------------|------------|
| `services/apps/*.cue` | Yes | Edit local, push via GitLab API | Local: `cue vet -c=false ./...` |
| `services/core/*.cue` | Yes | Edit local, push via GitLab API | Local: `cue vet -c=false ./...` |
| `env.cue` | No | Fetch from GitLab, modify in memory, push back | Jenkins CI (no local validation possible) |

**Current Issues:**
1. UC-A3: Fetches env.cue, saves to local dir, runs cue-edit.py which validates in wrong context
2. UC-B4 Phase 1: Already fixed to edit local services/apps/example-app.cue
3. UC-B4 Phase 2: Same issue as UC-A3 - fetches env.cue, tries local validation

**Solution:**
- For env.cue edits: Use pure string manipulation (sed/awk) on fetched content, skip CUE validation, push back
- For services/*.cue edits: Edit local file, validate with `cue vet -c=false ./...`, push via GitLab API (already correct in UC-C1)

---

### Task 1: Fix UC-B4 Phase 1 (services/apps/example-app.cue)

Phase 1 was partially fixed but uses complex sed patterns that may not work correctly. Simplify to match UC-C1's proven pattern.

**Files:**
- Modify: `scripts/demo/demo-uc-b4-app-override.sh:139-226`

**Step 1: Replace sed-based configMap insertion with simpler pattern**

The current sed patterns (lines 162-175) are complex and fragile. Replace with a simpler approach that adds the configMap block in the right place.

```bash
# Lines 148-189 - Replace entire Phase 1 edit section with:

# Edit LOCAL file directly (same pattern as UC-C1)
APP_CUE_PATH="services/apps/example-app.cue"

# Check if entry already exists
if grep -q "\"$DEMO_KEY\"" "$APP_CUE_PATH"; then
    demo_warn "Key '$DEMO_KEY' already exists in $APP_CUE_PATH"
    demo_info "Run reset-demo-state.sh to clean up"
    exit 1
fi

# Add configMap entry to appConfig block
# The appConfig block is currently empty (just comments), so we add after "appConfig: {"
demo_action "Adding ConfigMap entry to app CUE..."

# Use awk for reliable multi-line insertion after "appConfig: {"
awk -v key="$DEMO_KEY" -v val="$APP_DEFAULT_VALUE" '
/appConfig: \{/ {
    print
    print "\t\tconfigMap: {"
    print "\t\t\tdata: {"
    print "\t\t\t\t\"" key "\": \"" val "\""
    print "\t\t\t}"
    print "\t\t}"
    next
}
{print}
' "$APP_CUE_PATH" > "${APP_CUE_PATH}.tmp" && mv "${APP_CUE_PATH}.tmp" "$APP_CUE_PATH"

demo_verify "Added ConfigMap entry to $APP_CUE_PATH"

# Verify CUE is valid (use -c=false since main branch env.cue is incomplete by design)
demo_action "Validating CUE configuration..."
if cue vet -c=false ./...; then
    demo_verify "CUE validation passed"
else
    demo_fail "CUE validation failed"
    git checkout "$APP_CUE_PATH" 2>/dev/null || true
    exit 1
fi

demo_action "Changed section in $APP_CUE_PATH:"
grep -A10 "appConfig" "$APP_CUE_PATH" | head -15 | sed 's/^/    /'
```

**Step 2: Verify the edit produces valid CUE**

Run: `cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments && bash -c 'source ../scripts/demo/lib/demo-helpers.sh; DEMO_KEY="test-key"; APP_DEFAULT_VALUE="test-val"; APP_CUE_PATH="services/apps/example-app.cue"; awk -v key="$DEMO_KEY" -v val="$APP_DEFAULT_VALUE" "/appConfig: \\{/ { print; print \"\t\tconfigMap: {\"; print \"\t\t\tdata: {\"; print \"\t\t\t\t\\\"\" key \"\\\": \\\"\" val \"\\\"\"; print \"\t\t\t}\"; print \"\t\t}\"; next } {print}" "$APP_CUE_PATH" | head -70'`

Expected: See the appConfig block with configMap entry properly indented

**Step 3: Revert test and commit**

```bash
git checkout services/apps/example-app.cue
```

---

### Task 2: Fix UC-B4 Phase 2 (prod env.cue override)

Phase 2 modifies env.cue which doesn't exist locally. Use string manipulation on fetched content without local CUE validation.

**Files:**
- Modify: `scripts/demo/demo-uc-b4-app-override.sh:307-366`

**Step 1: Replace cue-edit.py usage with sed-based modification**

Replace lines 316-343 with:

```bash
# Get current env.cue content from prod branch
demo_action "Fetching prod's env.cue from GitLab..."
PROD_ENV_CUE=$(get_file_from_branch "prod" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from prod branch"
    exit 1
fi
demo_verify "Retrieved prod's env.cue"

# Modify the content using awk (no local CUE validation - Jenkins CI will validate)
# Add configMap entry to the prod exampleApp appConfig block
demo_action "Adding ConfigMap override to env.cue..."

# Find the prod: exampleApp: block and add configMap entry to its appConfig
MODIFIED_ENV_CUE=$(echo "$PROD_ENV_CUE" | awk -v key="$DEMO_KEY" -v val="$PROD_OVERRIDE_VALUE" '
/^prod: exampleApp:/ { in_prod_app=1 }
in_prod_app && /configMap:/ { in_configmap=1 }
in_prod_app && in_configmap && /data: \{/ {
    print
    print "\t\t\t\t\"" key "\": \"" val "\""
    next
}
{print}
')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi
demo_verify "Modified env.cue with override"

demo_action "Change preview:"
diff <(echo "$PROD_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true
```

**Step 2: Update branch creation to use GitLab CLI (consistent with UC-C1)**

Replace lines 345-366 with:

```bash
# Create branch and MR for the override
OVERRIDE_BRANCH="uc-b4-prod-override-$(date +%s)"

demo_action "Creating branch '$OVERRIDE_BRANCH' from prod in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$OVERRIDE_BRANCH" --from prod >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing override to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$OVERRIDE_BRANCH" \
    --message "feat: override $DEMO_KEY to $PROD_OVERRIDE_VALUE in prod (UC-B4)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Override branch pushed"

# Create MR from override branch to prod
demo_action "Creating MR for prod override..."
override_mr_iid=$(create_mr "$OVERRIDE_BRANCH" "prod" "UC-B4: Override $DEMO_KEY in prod")
```

---

### Task 3: Fix UC-A3 (dev env.cue modification)

UC-A3 has the same pattern issue - it fetches env.cue and tries to use cue-edit.py.

**Files:**
- Modify: `scripts/demo/demo-uc-a3-env-configmap.sh:137-196`

**Step 1: Replace cue-edit.py usage with sed-based modification**

Replace lines 137-164 with:

```bash
# Get current env.cue content from dev branch
demo_action "Fetching $TARGET_ENV's env.cue from GitLab..."
DEV_ENV_CUE=$(get_file_from_branch "$TARGET_ENV" "env.cue")

if [[ -z "$DEV_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from $TARGET_ENV branch"
    exit 1
fi
demo_verify "Retrieved $TARGET_ENV's env.cue"

# Modify the content using awk (no local CUE validation - Jenkins CI will validate)
# Add configMap entry to the dev exampleApp appConfig block
demo_action "Adding ConfigMap entry to env.cue..."

# Find the dev: exampleApp: block and add entry to its configMap.data
MODIFIED_ENV_CUE=$(echo "$DEV_ENV_CUE" | awk -v env="$TARGET_ENV" -v key="$DEMO_KEY" -v val="$DEMO_VALUE" '
BEGIN { in_target=0; in_configmap=0 }
$0 ~ "^" env ": exampleApp:" { in_target=1 }
in_target && /configMap:/ { in_configmap=1 }
in_target && in_configmap && /data: \{/ {
    print
    print "\t\t\t\t\"" key "\": \"" val "\""
    next
}
in_target && /^[a-z]+: / && !/exampleApp/ { in_target=0; in_configmap=0 }
{print}
')

if [[ -z "$MODIFIED_ENV_CUE" ]]; then
    demo_fail "Failed to modify env.cue"
    exit 1
fi
demo_verify "Modified env.cue with ConfigMap entry"

demo_action "Change preview:"
diff <(echo "$DEV_ENV_CUE") <(echo "$MODIFIED_ENV_CUE") | head -20 || true
```

**Step 2: Update branch creation to use GitLab CLI (consistent with UC-C1)**

Replace lines 175-192 with:

```bash
# Generate feature branch name
FEATURE_BRANCH="uc-a3-env-configmap-$(date +%s)"

demo_action "Creating branch '$FEATURE_BRANCH' from $TARGET_ENV in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from "$TARGET_ENV" >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing CUE change to GitLab..."
echo "$MODIFIED_ENV_CUE" | "$GITLAB_CLI" file update p2c/k8s-deployments "env.cue" \
    --ref "$FEATURE_BRANCH" \
    --message "feat: add $DEMO_KEY to $TARGET_ENV ConfigMap (UC-A3)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update file in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Create MR from feature branch to dev
demo_action "Creating MR: $FEATURE_BRANCH → $TARGET_ENV..."
mr_iid=$(create_mr "$FEATURE_BRANCH" "$TARGET_ENV" "UC-A3: Add $DEMO_KEY to $TARGET_ENV ConfigMap")
```

---

### Task 4: Test UC-A3 in isolation

**Step 1: Run UC-A3 demo**

Run: `cd /home/jmann/git/mannjg/deployment-pipeline && ./scripts/demo/demo-uc-a3-env-configmap.sh`

Expected: Demo completes successfully, dev ConfigMap has the entry, stage/prod do not

**Step 2: Verify cleanup**

Run: `./scripts/03-pipelines/reset-demo-state.sh`

Expected: Reset completes, all environments return to baseline

---

### Task 5: Test UC-B4 in isolation

**Step 1: Run UC-B4 demo**

Run: `cd /home/jmann/git/mannjg/deployment-pipeline && ./scripts/demo/demo-uc-b4-app-override.sh`

Expected: Demo completes successfully with:
- Phase 1: All environments have demo-cache-ttl=300
- Phase 2: prod has demo-cache-ttl=600, dev/stage have 300

**Step 2: Verify cleanup**

Run: `./scripts/03-pipelines/reset-demo-state.sh`

Expected: Reset completes, all environments return to baseline

---

### Task 6: Run full demo suite

**Step 1: Run all demos**

Run: `cd /home/jmann/git/mannjg/deployment-pipeline/scripts/demo && ./run-all-demos.sh`

Expected: All demos pass (validate-pipeline, UC-A3, UC-B4, UC-C1, UC-C2, UC-C4, UC-C6)

**Step 2: Commit the fixes**

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
git add scripts/demo/demo-uc-a3-env-configmap.sh scripts/demo/demo-uc-b4-app-override.sh
git commit -m "fix: use correct editing patterns for UC-A3 and UC-B4 demos

- UC-A3: Use awk for env.cue modification, skip local CUE validation
- UC-B4 Phase 1: Use awk for services/apps/example-app.cue modification
- UC-B4 Phase 2: Use awk for prod env.cue modification
- Use GitLab CLI consistently (matching UC-C1 pattern)
- Let Jenkins CI validate CUE instead of attempting local validation

Root cause: env.cue doesn't exist on main branch, so cue-edit.py
couldn't validate in the correct context.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Summary of Changes

| File | Change | Reason |
|------|--------|--------|
| `demo-uc-a3-env-configmap.sh` | Replace cue-edit.py with awk + GitLab CLI | env.cue doesn't exist locally |
| `demo-uc-b4-app-override.sh` (Phase 1) | Simplify sed to awk, keep local validation | services/*.cue exists locally |
| `demo-uc-b4-app-override.sh` (Phase 2) | Replace cue-edit.py with awk + GitLab CLI | env.cue doesn't exist locally |
