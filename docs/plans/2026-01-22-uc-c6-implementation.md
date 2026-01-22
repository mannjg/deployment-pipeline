# UC-C6 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a demo script that validates platform defaults can be overridden by environment-specific configuration.

**Architecture:** The demo script adds a `cost-center` label at the platform layer, promotes it through all environments, then adds an override in prod's `env.cue` to change the value from `platform-shared` to `production-critical`.

**Tech Stack:** Bash, CUE, GitLab API, kubectl, existing demo helper libraries

---

## Task 1: Add platform-label command to cue-edit.py

The existing `cue-edit.py` has `platform-annotation` for pod annotations but no equivalent for labels. We need `platform-label` to modify `defaultLabels` in `services/core/app.cue`.

**Files:**
- Modify: `scripts/demo/lib/cue-edit.py:343-549`

**Step 1: Add platform-label functions after the platform-annotation functions**

Add these functions after line 549 (after `remove_platform_annotation`):

```python
# ============================================================================
# PLATFORM-LEVEL LABEL FUNCTIONS
# ============================================================================

def add_platform_label(project_root: str, key: str, value: str) -> dict:
    """Add a default label to the platform layer.

    This modifies services/core/app.cue - Add/update defaultLabels struct.

    Returns dict with 'app_cue' key containing modified content.
    """
    app_cue_path = Path(project_root) / "services" / "core" / "app.cue"

    if not app_cue_path.exists():
        raise ValueError(f"File not found: {app_cue_path}")

    app_content = app_cue_path.read_text()

    # Add/update label in defaultLabels
    app_content = _add_label_to_default_labels(app_content, key, value)

    return {
        'app_cue': app_content,
        'app_cue_path': str(app_cue_path),
    }


def _add_label_to_default_labels(content: str, key: str, value: str) -> str:
    """Add or update a label in defaultLabels struct."""
    # Check if this specific key exists
    key_pattern = rf'"{re.escape(key)}":\s*"[^"]*"'
    if re.search(key_pattern, content):
        # Update existing key
        content = re.sub(
            rf'("{re.escape(key)}":\s*)"[^"]*"',
            rf'\1"{value}"',
            content
        )
    else:
        # Add new key to existing defaultLabels struct
        # Find the closing brace of defaultLabels - it's after "deployment: appName"
        match = re.search(r'(defaultLabels:\s*\{[^}]*deployment:\s*appName)', content)
        if match:
            insert_pos = match.end()
            new_entry = f'\n\t\t"{key}": "{value}"'
            content = content[:insert_pos] + new_entry + content[insert_pos:]
        else:
            raise ValueError("Could not find defaultLabels block in app.cue")

    return content


def remove_platform_label(project_root: str, key: str) -> dict:
    """Remove a default label from the platform layer.

    Returns dict with modified content.
    """
    app_cue_path = Path(project_root) / "services" / "core" / "app.cue"

    if not app_cue_path.exists():
        raise ValueError(f"File not found: {app_cue_path}")

    app_content = app_cue_path.read_text()

    # Remove the specific label key from defaultLabels
    pattern = rf'\n\s*"{re.escape(key)}":\s*"[^"]*"'
    app_content = re.sub(pattern, '', app_content)

    return {
        'app_cue': app_content,
        'app_cue_path': str(app_cue_path),
    }
```

**Step 2: Add CLI subcommand for platform-label**

Find the line (around 610-620) where `platform_ann` subparser is defined. Add after the `platform_ann_remove` block:

```python
    # platform-label subcommand
    platform_lbl = subparsers.add_parser('platform-label', help='Modify platform-level default labels')
    platform_lbl_sub = platform_lbl.add_subparsers(dest='action')

    platform_lbl_add = platform_lbl_sub.add_parser('add', help='Add a default label')
    platform_lbl_add.add_argument('key', help='Label key (e.g., cost-center)')
    platform_lbl_add.add_argument('value', help='Label value (e.g., platform-shared)')

    platform_lbl_remove = platform_lbl_sub.add_parser('remove', help='Remove a default label')
    platform_lbl_remove.add_argument('key', help='Label key to remove')
```

**Step 3: Add handler for platform-label command in main()**

Find the block that handles `platform-annotation` (around line 628). Add similar handling for `platform-label` right after it:

```python
    # Handle platform-label (operates on project root, not a single file)
    if args.command == 'platform-label':
        project_root = find_project_root(str(Path.cwd()))

        try:
            if args.action == 'add':
                results = add_platform_label(project_root, args.key, args.value)
            elif args.action == 'remove':
                results = remove_platform_label(project_root, args.key)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)

            # Write file and validate
            app_cue_path = Path(results['app_cue_path'])

            # Backup file
            app_backup = str(app_cue_path) + '.bak'
            shutil.copy(str(app_cue_path), app_backup)

            try:
                # Write new content
                app_cue_path.write_text(results['app_cue'])

                # Validate with cue vet -c=false
                result = subprocess.run(
                    ["cue", "vet", "-c=false", "./..."],
                    cwd=project_root,
                    capture_output=True,
                    text=True,
                    timeout=30
                )

                if result.returncode != 0:
                    shutil.move(app_backup, str(app_cue_path))
                    print(f"Error: CUE validation failed:\n{result.stderr}", file=sys.stderr)
                    sys.exit(1)

                # Success - remove backup
                Path(app_backup).unlink(missing_ok=True)
                print(f"Successfully modified {app_cue_path}")
                sys.exit(0)

            except Exception as e:
                if Path(app_backup).exists():
                    shutil.move(app_backup, str(app_cue_path))
                raise

        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
```

**Step 4: Test the new command**

Run:
```bash
cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments
python3 ../scripts/demo/lib/cue-edit.py platform-label add cost-center platform-shared
```

Expected: File modified message, `cue vet` passes

**Step 5: Verify the change**

Run:
```bash
grep -A5 "defaultLabels" services/core/app.cue
```

Expected: Shows `"cost-center": "platform-shared"` in the output

**Step 6: Revert the test change**

Run:
```bash
git checkout services/core/app.cue
```

**Step 7: Commit**

```bash
git add scripts/demo/lib/cue-edit.py
git commit -m "$(cat <<'EOF'
feat(demo): add platform-label command to cue-edit.py

Adds support for adding/removing labels from defaultLabels in
services/core/app.cue, similar to existing platform-annotation command.

Used by UC-C6 demo to add cost-center label at platform level.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add env-label command to cue-edit.py

We need to add/modify labels in environment-specific `env.cue` files for the prod override.

**Files:**
- Modify: `scripts/demo/lib/cue-edit.py`

**Step 1: Add env-label functions**

Add after the platform-label functions:

```python
# ============================================================================
# ENVIRONMENT-LEVEL LABEL FUNCTIONS
# ============================================================================

def add_env_label(content: str, env: str, app: str, key: str, value: str) -> str:
    """Add a label to an environment's app config in env.cue.

    Structure: <env>: <app>: apps.<appRef> & {
        appConfig: {
            labels: {
                "key": "value"
            }
        }
    }
    """
    # Pattern to find the app definition within the environment
    app_pattern = rf'^({env}:\s*{app}:\s*apps\.\w+\s*&\s*\{{)'
    app_match = re.search(app_pattern, content, re.MULTILINE)

    if not app_match:
        raise ValueError(f"Could not find app '{app}' in environment '{env}'")

    app_start = app_match.end()
    app_block_end = find_block_end(content, app_match.start() + content[app_match.start():].index('{'))
    app_block = content[app_start:app_block_end]

    # Look for existing labels block
    labels_pattern = r'(labels:\s*\{)'
    labels_match = re.search(labels_pattern, app_block)

    if labels_match:
        # Found existing labels block
        insert_pos = app_start + labels_match.end()

        # Check if key already exists
        existing_pattern = rf'"{re.escape(key)}":\s*"[^"]*"'
        if re.search(existing_pattern, app_block):
            # Replace existing value
            # Need to be careful to only replace within this app block
            before = content[:app_start]
            after = content[app_block_end:]
            new_app_block = re.sub(
                rf'("{re.escape(key)}":\s*)"[^"]*"',
                rf'\1"{value}"',
                app_block
            )
            return before + new_app_block + after

        # Add new entry after the opening brace of labels
        new_entry = f'\n\t\t\t"{key}": "{value}"'
        return content[:insert_pos] + new_entry + content[insert_pos:]

    # Look for appConfig block to add labels
    appconfig_pattern = r'(appConfig:\s*\{)'
    appconfig_match = re.search(appconfig_pattern, app_block)

    if appconfig_match:
        insert_pos = app_start + appconfig_match.end()
        new_block = f'\n\t\tlabels: {{\n\t\t\t"{key}": "{value}"\n\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    raise ValueError(f"Could not find appConfig block for app '{app}' in environment '{env}'")


def remove_env_label(content: str, env: str, app: str, key: str) -> str:
    """Remove a label from an environment's app config."""
    # Find the app block first to scope the replacement
    app_pattern = rf'^{env}:\s*{app}:\s*apps\.\w+\s*&\s*\{{'
    app_match = re.search(app_pattern, content, re.MULTILINE)

    if not app_match:
        return content  # Nothing to remove if app doesn't exist

    app_start = app_match.start()
    app_block_end = find_block_end(content, app_start + content[app_start:].index('{'))

    # Only remove within this app's block
    before = content[:app_start]
    app_block = content[app_start:app_block_end + 1]
    after = content[app_block_end + 1:]

    # Remove the entry from the app block
    pattern = rf'(\n\s*)"{re.escape(key)}":\s*"[^"]*"\s*'
    app_block = re.sub(pattern, r'\1', app_block)

    return before + app_block + after
```

**Step 2: Add CLI subcommand for env-label**

Add after the `platform-label` subparser:

```python
    # env-label subcommand
    env_lbl = subparsers.add_parser('env-label', help='Modify environment-level labels')
    env_lbl_sub = env_lbl.add_subparsers(dest='action')

    env_lbl_add = env_lbl_sub.add_parser('add', help='Add a label')
    env_lbl_add.add_argument('file', help='CUE file to modify (env.cue)')
    env_lbl_add.add_argument('env', help='Environment name (dev/stage/prod)')
    env_lbl_add.add_argument('app', help='App name (CUE identifier, e.g., exampleApp)')
    env_lbl_add.add_argument('key', help='Label key')
    env_lbl_add.add_argument('value', help='Label value')

    env_lbl_remove = env_lbl_sub.add_parser('remove', help='Remove a label')
    env_lbl_remove.add_argument('file', help='CUE file to modify')
    env_lbl_remove.add_argument('env', help='Environment name')
    env_lbl_remove.add_argument('app', help='App name (CUE identifier)')
    env_lbl_remove.add_argument('key', help='Label key to remove')
```

**Step 3: Add handler in the main command dispatch**

In the `try` block that handles `env-configmap`, `app-configmap`, `env-field`, add:

```python
        elif args.command == 'env-label':
            if args.action == 'add':
                new_content = add_env_label(content, args.env, args.app, args.key, args.value)
            elif args.action == 'remove':
                new_content = remove_env_label(content, args.env, args.app, args.key)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)
```

**Step 4: Commit**

```bash
git add scripts/demo/lib/cue-edit.py
git commit -m "$(cat <<'EOF'
feat(demo): add env-label command to cue-edit.py

Adds support for adding/removing labels in environment-specific env.cue
files, enabling environment overrides of platform-level labels.

Used by UC-C6 demo to override cost-center label in prod.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add helper function for creating direct branch commits

The demo needs to commit directly to the prod branch in GitLab (for the override). We need a helper for this.

**Files:**
- Modify: `scripts/demo/lib/pipeline-wait.sh`

**Step 1: Add function to commit a file change to a GitLab branch**

Add after the `push_empty_commit_for_mr` function (around line 361):

```bash
# Commit a file change directly to a GitLab branch
# Usage: commit_file_to_branch <branch> <file_path> <content> <commit_message>
# Returns: 0 on success, 1 on failure
commit_file_to_branch() {
    local branch="$1"
    local file_path="$2"
    local content="$3"
    local commit_message="$4"

    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")

    demo_action "Committing $file_path to $branch branch..."

    # Check if file exists to determine create vs update action
    local file_check
    file_check=$(curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/repository/files/$(echo "$file_path" | sed 's/\//%2F/g')?ref=${branch}" 2>/dev/null)

    local action="create"
    if echo "$file_check" | jq -e '.file_name' >/dev/null 2>&1; then
        action="update"
    fi

    # Use commits API for atomic commit
    local json_payload
    json_payload=$(jq -n \
        --arg branch "$branch" \
        --arg msg "$commit_message" \
        --arg action "$action" \
        --arg path "$file_path" \
        --arg content "$content" \
        '{
            branch: $branch,
            commit_message: $msg,
            actions: [{
                action: $action,
                file_path: $path,
                content: $content
            }]
        }')

    local result
    result=$(curl -sk -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/repository/commits" \
        -d "$json_payload" 2>/dev/null)

    if echo "$result" | jq -e '.id' >/dev/null 2>&1; then
        local commit_sha
        commit_sha=$(echo "$result" | jq -r '.short_id')
        demo_verify "Created commit $commit_sha on $branch"
        return 0
    else
        demo_fail "Could not commit: $(echo "$result" | jq -r '.message // "unknown error"')"
        return 1
    fi
}

# Get file content from a GitLab branch
# Usage: get_file_from_branch <branch> <file_path>
# Returns: File content on stdout
get_file_from_branch() {
    local branch="$1"
    local file_path="$2"

    local project="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
    local encoded_project=$(_encode_project "$project")
    local encoded_path=$(echo "$file_path" | sed 's/\//%2F/g')

    curl -sk -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_URL_EXTERNAL}/api/v4/projects/${encoded_project}/repository/files/${encoded_path}/raw?ref=${branch}" 2>/dev/null
}
```

**Step 2: Commit**

```bash
git add scripts/demo/lib/pipeline-wait.sh
git commit -m "$(cat <<'EOF'
feat(demo): add commit_file_to_branch and get_file_from_branch helpers

Enables demo scripts to commit file changes directly to GitLab branches
and retrieve file contents from specific branches.

Used by UC-C6 demo to add label override to prod's env.cue.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Create the UC-C6 demo script

**Files:**
- Create: `scripts/demo/demo-uc-c6-platform-env-override.sh`

**Step 1: Create the demo script**

```bash
#!/bin/bash
# Demo: Platform Default with Environment Override (UC-C6)
#
# This demo showcases how environment-specific configuration can override
# platform-wide defaults through the CUE layering system.
#
# Use Case UC-C6:
# "Platform sets cost-center=platform-shared, but prod overrides to
# cost-center=production-critical for priority billing"
#
# What This Demonstrates:
# - Platform-wide defaults propagate to ALL environments (like UC-C1)
# - Environment-specific overrides in env.cue take precedence
# - Override only affects the target environment (isolation)
# - Promotion preserves environment-specific configuration
#
# Flow:
# 1. Add platform default (cost-center: platform-shared)
# 2. Promote through all environments (dev/stage/prod all get platform-shared)
# 3. Add prod override (cost-center: production-critical)
# 4. Verify: dev/stage have platform-shared, prod has production-critical
#
# Prerequisites:
# - Environment branches (dev/stage/prod) exist in GitLab
# - Pipeline infrastructure running (Jenkins, ArgoCD)
# - Run from deployment-pipeline root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K8S_DEPLOYMENTS_DIR="${PROJECT_ROOT}/k8s-deployments"

# Load helper libraries
source "${SCRIPT_DIR}/lib/demo-helpers.sh"
source "${SCRIPT_DIR}/lib/assertions.sh"
source "${SCRIPT_DIR}/lib/pipeline-wait.sh"

# ============================================================================
# CONFIGURATION
# ============================================================================

DEMO_LABEL_KEY="cost-center"
PLATFORM_LABEL_VALUE="platform-shared"
PROD_OVERRIDE_VALUE="production-critical"
DEMO_APP="example-app"
DEMO_APP_CUE="exampleApp"  # CUE identifier
ENVIRONMENTS=("dev" "stage" "prod")

# CUE edit helper path
CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

add_platform_label() {
    demo_action "Adding platform label using cue-edit.py..."

    if ! python3 "${CUE_EDIT}" platform-label add "$DEMO_LABEL_KEY" "$PLATFORM_LABEL_VALUE"; then
        demo_fail "Failed to add platform label"
        return 1
    fi
    demo_verify "Added $DEMO_LABEL_KEY: $PLATFORM_LABEL_VALUE to defaultLabels"
    return 0
}

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C6: Platform Default with Environment Override"

# Load credentials
load_pipeline_credentials || exit 1

# Save original branch
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

# Setup cleanup
demo_cleanup_on_exit "$ORIGINAL_BRANCH"

# ---------------------------------------------------------------------------
# Step 1: Verify Prerequisites
# ---------------------------------------------------------------------------

demo_step 1 "Verify Prerequisites"

demo_action "Checking kubectl connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    demo_fail "Cannot connect to Kubernetes cluster"
    exit 1
fi
demo_verify "Connected to Kubernetes cluster"

demo_action "Checking ArgoCD applications..."
for env in "${ENVIRONMENTS[@]}"; do
    if kubectl get application "${DEMO_APP}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
        demo_verify "ArgoCD app ${DEMO_APP}-${env} exists"
    else
        demo_fail "ArgoCD app ${DEMO_APP}-${env} not found"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Add Platform Default Label
# ---------------------------------------------------------------------------

demo_step 2 "Add Platform Default Label"

demo_info "Adding '$DEMO_LABEL_KEY: $PLATFORM_LABEL_VALUE' to services/core/app.cue"

# Make CUE change using cue-edit.py
add_platform_label || exit 1

demo_action "Summary of CUE changes:"
git diff --stat services/core/app.cue 2>/dev/null || echo "  (no diff available)"

# ---------------------------------------------------------------------------
# Step 3: Commit and Push Platform Default
# ---------------------------------------------------------------------------

demo_step 3 "Commit and Push Platform Default"

demo_action "Creating feature branch..."
FEATURE_BRANCH="uc-c6-platform-default-$(date +%s)"
git checkout -b "$FEATURE_BRANCH"

demo_action "Committing CUE change only (manifests generated by pipeline)..."
git add services/core/app.cue
git commit -m "feat: add $DEMO_LABEL_KEY label to all deployments (UC-C6)"

demo_action "Pushing feature branch to GitLab..."
cd "$PROJECT_ROOT"
git subtree push --prefix=k8s-deployments gitlab-deployments "$FEATURE_BRANCH"
cd "$K8S_DEPLOYMENTS_DIR"
demo_verify "Feature branch pushed"

# ---------------------------------------------------------------------------
# Step 4: Promote Platform Default Through All Environments
# ---------------------------------------------------------------------------

demo_step 4 "Promote Platform Default Through All Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR
    argocd_baseline=$(get_argocd_revision "${DEMO_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C6: Add $DEMO_LABEL_KEY label to $env")

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "services/core/app.cue" "$DEMO_LABEL_KEY" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_LABEL_KEY" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    else
        # STAGE/PROD: Wait for Jenkins-created promotion MR
        wait_for_promotion_mr "$env" "$next_promotion_baseline" || exit 1
        mr_iid="$PROMOTION_MR_IID"

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to validate promotion..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains manifest changes..."
        assert_mr_contains_diff "$mr_iid" "manifests/.*\\.yaml" "$DEMO_LABEL_KEY" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync
    wait_for_argocd_sync "${DEMO_APP}-${env}" "$argocd_baseline" || exit 1

    # Verify K8s state
    demo_action "Verifying label in K8s deployment..."
    assert_pod_label_equals "$env" "$DEMO_APP" "$DEMO_LABEL_KEY" "$PLATFORM_LABEL_VALUE" || exit 1

    demo_verify "Promotion to $env complete"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 5: Checkpoint - All Environments Have Platform Default
# ---------------------------------------------------------------------------

demo_step 5 "Checkpoint - All Environments Have Platform Default"

demo_info "Verifying platform default propagated to ALL environments..."

assert_env_propagation "deployment" "$DEMO_APP" \
    "{.spec.template.metadata.labels.$DEMO_LABEL_KEY}" \
    "$PLATFORM_LABEL_VALUE" \
    "${ENVIRONMENTS[@]}" || exit 1

demo_verify "CHECKPOINT: All environments have '$DEMO_LABEL_KEY: $PLATFORM_LABEL_VALUE'"
demo_info "This proves UC-C1-like behavior: platform-wide propagation works."
echo ""

# ---------------------------------------------------------------------------
# Step 6: Add Prod Override
# ---------------------------------------------------------------------------

demo_step 6 "Add Prod Override"

demo_info "Now adding override to prod: '$DEMO_LABEL_KEY: $PROD_OVERRIDE_VALUE'"

# Get current env.cue content from prod branch
demo_action "Fetching prod's env.cue from GitLab..."
PROD_ENV_CUE=$(get_file_from_branch "prod" "env.cue")

if [[ -z "$PROD_ENV_CUE" ]]; then
    demo_fail "Could not fetch env.cue from prod branch"
    exit 1
fi
demo_verify "Retrieved prod's env.cue"

# Modify the content locally using cue-edit.py
demo_action "Adding label override to env.cue..."
TEMP_ENV_CUE=$(mktemp)
echo "$PROD_ENV_CUE" > "$TEMP_ENV_CUE"

# Use cue-edit.py to add the label
if ! python3 "${CUE_EDIT}" env-label add "$TEMP_ENV_CUE" "prod" "$DEMO_APP_CUE" "$DEMO_LABEL_KEY" "$PROD_OVERRIDE_VALUE"; then
    demo_fail "Failed to add label override to env.cue"
    rm -f "$TEMP_ENV_CUE"
    exit 1
fi

MODIFIED_ENV_CUE=$(cat "$TEMP_ENV_CUE")
rm -f "$TEMP_ENV_CUE"
demo_verify "Modified env.cue with override"

# Create branch and MR for the override
OVERRIDE_BRANCH="uc-c6-prod-override-$(date +%s)"
demo_action "Creating override branch: $OVERRIDE_BRANCH"

# Use GitLab API to create branch from prod
PROJECT="${DEPLOYMENTS_REPO_PATH:-p2c/k8s-deployments}"
ENCODED_PROJECT=$(echo "$PROJECT" | sed 's/\//%2F/g')

branch_result=$(curl -sk -X POST -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "${GITLAB_URL_EXTERNAL}/api/v4/projects/${ENCODED_PROJECT}/repository/branches?branch=${OVERRIDE_BRANCH}&ref=prod" 2>/dev/null)

if ! echo "$branch_result" | jq -e '.name' >/dev/null 2>&1; then
    demo_fail "Could not create branch: $(echo "$branch_result" | jq -r '.message // "unknown error"')"
    exit 1
fi
demo_verify "Created branch $OVERRIDE_BRANCH from prod"

# Commit the modified env.cue to the override branch
demo_action "Committing override to branch..."
commit_file_to_branch "$OVERRIDE_BRANCH" "env.cue" "$MODIFIED_ENV_CUE" \
    "feat: override $DEMO_LABEL_KEY to $PROD_OVERRIDE_VALUE in prod (UC-C6)" || exit 1

# Create MR from override branch to prod
demo_action "Creating MR for prod override..."
override_mr_iid=$(create_mr "$OVERRIDE_BRANCH" "prod" "UC-C6: Override $DEMO_LABEL_KEY in prod")

# Wait for MR pipeline
demo_action "Waiting for pipeline to validate override..."
wait_for_mr_pipeline "$override_mr_iid" || exit 1

# Verify MR contains expected changes
demo_action "Verifying MR contains override..."
assert_mr_contains_diff "$override_mr_iid" "env.cue" "$PROD_OVERRIDE_VALUE" || exit 1

# Capture ArgoCD baseline before merge
argocd_baseline=$(get_argocd_revision "${DEMO_APP}-prod")

# Merge MR
accept_mr "$override_mr_iid" || exit 1

# Wait for ArgoCD sync
wait_for_argocd_sync "${DEMO_APP}-prod" "$argocd_baseline" || exit 1

demo_verify "Prod override applied successfully"

# ---------------------------------------------------------------------------
# Step 7: Final Verification - Override Only Affects Prod
# ---------------------------------------------------------------------------

demo_step 7 "Final Verification - Override Only Affects Prod"

demo_info "Verifying final state across all environments..."

# Dev should still have platform default
demo_action "Checking dev..."
assert_pod_label_equals "dev" "$DEMO_APP" "$DEMO_LABEL_KEY" "$PLATFORM_LABEL_VALUE" || exit 1

# Stage should still have platform default
demo_action "Checking stage..."
assert_pod_label_equals "stage" "$DEMO_APP" "$DEMO_LABEL_KEY" "$PLATFORM_LABEL_VALUE" || exit 1

# Prod should have the override
demo_action "Checking prod..."
assert_pod_label_equals "prod" "$DEMO_APP" "$DEMO_LABEL_KEY" "$PROD_OVERRIDE_VALUE" || exit 1

demo_verify "VERIFIED: Environment isolation works correctly!"
demo_info "  - dev:   $DEMO_LABEL_KEY = $PLATFORM_LABEL_VALUE (platform default)"
demo_info "  - stage: $DEMO_LABEL_KEY = $PLATFORM_LABEL_VALUE (platform default)"
demo_info "  - prod:  $DEMO_LABEL_KEY = $PROD_OVERRIDE_VALUE (environment override)"

# ---------------------------------------------------------------------------
# Step 8: Summary
# ---------------------------------------------------------------------------

demo_step 8 "Summary"

cat << EOF

  This demo validated UC-C6: Platform Default with Environment Override

  What happened:
  1. Added '$DEMO_LABEL_KEY: $PLATFORM_LABEL_VALUE' to platform layer (services/core/app.cue)
  2. Promoted through all environments using GitOps pattern:
     - Feature branch → dev: Manual MR (pipeline generates manifests)
     - dev → stage: Jenkins auto-created promotion MR
     - stage → prod: Jenkins auto-created promotion MR
  3. CHECKPOINT: Verified all environments had platform default
  4. Added prod override '$DEMO_LABEL_KEY: $PROD_OVERRIDE_VALUE' via MR
  5. Verified final state:
     - dev/stage: platform default ($PLATFORM_LABEL_VALUE)
     - prod: environment override ($PROD_OVERRIDE_VALUE)

  Key Observations:
  - Platform-wide defaults propagate correctly (UC-C1 behavior)
  - Environment overrides take precedence (CUE unification)
  - Override only affects target environment (isolation)
  - All changes go through MR with pipeline validation (GitOps)

  Override Hierarchy Validated:
    Platform (services/core/app.cue) → sets default
        ↓
    Environment (env.cue on prod) → overrides for prod only

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 9 "Cleanup"

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "Override branch '$OVERRIDE_BRANCH' left in place for reference"
demo_info "To delete locally: git branch -D $FEATURE_BRANCH"

demo_complete
```

**Step 2: Make the script executable**

Run:
```bash
chmod +x scripts/demo/demo-uc-c6-platform-env-override.sh
```

**Step 3: Commit**

```bash
git add scripts/demo/demo-uc-c6-platform-env-override.sh
git commit -m "$(cat <<'EOF'
feat(demo): add UC-C6 platform env override demo script

Demonstrates that platform-wide defaults can be overridden by
environment-specific configuration in env.cue.

Flow:
1. Add cost-center: platform-shared to platform layer
2. Promote through all environments (dev/stage/prod)
3. Checkpoint: verify all have platform-shared
4. Add prod override: cost-center: production-critical
5. Verify: dev/stage have default, prod has override

Validates full CUE override hierarchy and environment isolation.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Update USE_CASES.md status

**Files:**
- Modify: `docs/USE_CASES.md`

**Step 1: Update UC-C6 status in the Implementation Status table**

Find the UC-C6 row (around line 402) and update:

Before:
```markdown
| UC-C6 | Platform default + env override | 🔲 | 🔲 | 🔲 | — | |
```

After:
```markdown
| UC-C6 | Platform default + env override | ✅ | ✅ | 🔲 | — | Demo ready, pending pipeline verification |
```

**Step 2: Add demo script reference to Demo Scripts section**

Find the "Platform-Wide Demos (Phase 2)" section (around line 340) and add UC-C6:

```markdown
| [`scripts/demo/demo-uc-c6-platform-env-override.sh`](../scripts/demo/demo-uc-c6-platform-env-override.sh) | UC-C6 | Platform default with environment override; prod can diverge |
```

**Step 3: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "$(cat <<'EOF'
docs: update UC-C6 status to demo ready

Added demo script reference and updated implementation status table.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Test the demo script (dry run validation)

Before running against real infrastructure, validate the script syntax and helpers work.

**Step 1: Check script syntax**

Run:
```bash
bash -n scripts/demo/demo-uc-c6-platform-env-override.sh
```

Expected: No output (syntax OK)

**Step 2: Verify cue-edit.py platform-label command works**

Run:
```bash
cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments
python3 ../scripts/demo/lib/cue-edit.py platform-label add cost-center test-value
grep -A5 "defaultLabels" services/core/app.cue
git checkout services/core/app.cue  # Revert
```

Expected: Shows `"cost-center": "test-value"` in output before revert

**Step 3: Verify cue-edit.py env-label command works**

Run:
```bash
cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments
# Create a test env.cue file based on example-env.cue
cp example-env.cue test-env.cue
python3 ../scripts/demo/lib/cue-edit.py env-label add test-env.cue dev exampleApp cost-center override-value
grep -A3 "labels:" test-env.cue | head -10
rm test-env.cue  # Cleanup
```

Expected: Shows `"cost-center": "override-value"` in labels section

---

## Task 7: Final commit - implementation plan complete

**Step 1: Commit the implementation plan**

```bash
git add docs/plans/2026-01-22-uc-c6-implementation.md
git commit -m "$(cat <<'EOF'
docs: add UC-C6 implementation plan

Detailed step-by-step implementation plan for the UC-C6 demo script
that validates platform defaults with environment overrides.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Execution Checklist

After implementation, run the full demo to verify:

- [ ] Task 1: `platform-label` command added to cue-edit.py
- [ ] Task 2: `env-label` command added to cue-edit.py
- [ ] Task 3: `commit_file_to_branch` helper added to pipeline-wait.sh
- [ ] Task 4: Demo script created and executable
- [ ] Task 5: USE_CASES.md updated
- [ ] Task 6: Dry run validation passed
- [ ] Task 7: All commits made

## Pipeline Verification

After implementation, run the demo script:

```bash
cd /home/jmann/git/mannjg/deployment-pipeline
./scripts/demo/demo-uc-c6-platform-env-override.sh
```

If successful, update USE_CASES.md:
- Change UC-C6 "Pipeline Verified" from 🔲 to ✅
- Add verification date and branch name
