# UC-C5: Platform Default with App Override - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Demonstrate that an app can override platform-wide defaults by having postgres disable Prometheus scraping while example-app keeps it enabled.

**Architecture:** Create ArgoCD applications for postgres (infrastructure), extend cue-edit.py to support app-level annotation overrides, then build a demo script that modifies postgres.cue to override `prometheus.io/scrape` from "true" to "false" and verifies the override propagates through all environments.

**Tech Stack:** Bash, Python, CUE, kubectl, ArgoCD, GitLab API

---

## Prerequisites

Before starting implementation:
1. UC-C4 must have been run previously (platform has `prometheus.io/scrape: "true"` in `defaultPodAnnotations`)
2. Postgres manifests exist on GitLab env branches (verified: they do)
3. Pipeline infrastructure running (Jenkins, ArgoCD, GitLab)

---

## Task 1: Create ArgoCD Applications for Postgres

**Files:**
- Create: `k8s/argocd/postgres-applications.yaml`

**Step 1: Create the ArgoCD applications manifest**

Create a file with all three postgres ArgoCD applications (dev, stage, prod):

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres-dev
  namespace: argocd
  labels:
    app: postgres
    environment: dev
spec:
  project: default
  source:
    repoURL: https://gitlab.jmann.local/p2c/k8s-deployments.git
    targetRevision: dev
    path: manifests/postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres-stage
  namespace: argocd
  labels:
    app: postgres
    environment: stage
spec:
  project: default
  source:
    repoURL: https://gitlab.jmann.local/p2c/k8s-deployments.git
    targetRevision: stage
    path: manifests/postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: stage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres-prod
  namespace: argocd
  labels:
    app: postgres
    environment: prod
spec:
  project: default
  source:
    repoURL: https://gitlab.jmann.local/p2c/k8s-deployments.git
    targetRevision: prod
    path: manifests/postgres
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
```

**Step 2: Apply the ArgoCD applications**

Run:
```bash
kubectl apply -f k8s/argocd/postgres-applications.yaml
```

Expected: 3 applications created

**Step 3: Verify ArgoCD applications sync**

Run:
```bash
kubectl get applications -n argocd | grep postgres
```

Expected: `postgres-dev`, `postgres-stage`, `postgres-prod` all show `Synced` and `Healthy`

**Step 4: Verify postgres deployments exist**

Run:
```bash
kubectl get deployments postgres -n dev && kubectl get deployments postgres -n stage && kubectl get deployments postgres -n prod
```

Expected: All three deployments exist

**Step 5: Commit**

```bash
git add k8s/argocd/postgres-applications.yaml
git commit -m "infra: add ArgoCD applications for postgres

Creates postgres-dev, postgres-stage, postgres-prod ArgoCD applications
pointing to manifests/postgres on respective environment branches.

This enables UC-C5 demo (app override of platform defaults)."
```

---

## Task 2: Add app-annotation Command to cue-edit.py

**Files:**
- Modify: `scripts/demo/lib/cue-edit.py`

**Step 1: Add app-annotation functions after platform-annotation functions (around line 567)**

Add these functions to handle app-level pod annotation overrides:

```python
# ============================================================================
# APP-LEVEL POD ANNOTATION FUNCTIONS
# ============================================================================

def add_app_pod_annotation(content: str, app: str, key: str, value: str) -> str:
    """Add a pod annotation override to an app's config in services/apps/*.cue.

    This adds appConfig.deployment.podAnnotations to override platform defaults.

    Structure: postgres: core.#App & {
        appName: "postgres"
        appConfig: {
            deployment: {
                podAnnotations: {
                    "prometheus.io/scrape": "false"
                }
            }
        }
    }
    """
    # Look for existing appConfig.deployment.podAnnotations block
    pod_ann_pattern = r'(appConfig:\s*\{[^}]*?deployment:\s*\{[^}]*?podAnnotations:\s*\{)'
    pod_ann_match = re.search(pod_ann_pattern, content, re.DOTALL)

    if pod_ann_match:
        insert_pos = pod_ann_match.end()

        # Check if key already exists
        if re.search(rf'"{re.escape(key)}":\s*"[^"]*"', content[pod_ann_match.start():]):
            # Replace existing value
            return re.sub(
                rf'("{re.escape(key)}":\s*)"[^"]*"',
                rf'\1"{value}"',
                content
            )

        new_entry = f'\n\t\t\t"{key}": "{value}"'
        return content[:insert_pos] + new_entry + content[insert_pos:]

    # Look for existing appConfig.deployment block (without podAnnotations)
    deployment_pattern = r'(appConfig:\s*\{[^}]*?deployment:\s*\{)'
    deployment_match = re.search(deployment_pattern, content, re.DOTALL)

    if deployment_match:
        insert_pos = deployment_match.end()
        new_block = f'\n\t\t\tpodAnnotations: {{\n\t\t\t\t"{key}": "{value}"\n\t\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    # Look for existing appConfig block (without deployment)
    appconfig_pattern = r'(appConfig:\s*\{)'
    appconfig_match = re.search(appconfig_pattern, content)

    if appconfig_match:
        insert_pos = appconfig_match.end()
        new_block = f'\n\t\tdeployment: {{\n\t\t\tpodAnnotations: {{\n\t\t\t\t"{key}": "{value}"\n\t\t\t}}\n\t\t}}'
        return content[:insert_pos] + new_block + content[insert_pos:]

    raise ValueError("Could not find appConfig block in file")


def remove_app_pod_annotation(content: str, app: str, key: str) -> str:
    """Remove a pod annotation override from an app's config."""
    # Pattern to match the key-value line with proper whitespace handling
    pattern = rf'\n\s*"{re.escape(key)}":\s*"[^"]*"'
    return re.sub(pattern, '', content)
```

**Step 2: Add argparse subcommand for app-annotation (around line 920, after platform-label subcommand)**

```python
    # app-annotation subcommand
    app_ann = subparsers.add_parser('app-annotation', help='Modify app-level pod annotation overrides')
    app_ann_sub = app_ann.add_subparsers(dest='action')

    app_ann_add = app_ann_sub.add_parser('add', help='Add a pod annotation override to app config')
    app_ann_add.add_argument('file', help='CUE file to modify (services/apps/*.cue)')
    app_ann_add.add_argument('app', help='App name (CUE identifier)')
    app_ann_add.add_argument('key', help='Annotation key (e.g., prometheus.io/scrape)')
    app_ann_add.add_argument('value', help='Annotation value (e.g., false)')

    app_ann_remove = app_ann_sub.add_parser('remove', help='Remove a pod annotation override')
    app_ann_remove.add_argument('file', help='CUE file to modify')
    app_ann_remove.add_argument('app', help='App name (CUE identifier)')
    app_ann_remove.add_argument('key', help='Annotation key to remove')
```

**Step 3: Add handler for app-annotation command (in main() around line 1065)**

Add this handler block before the file reading section:

```python
    # Handle app-annotation command
    if args.command == 'app-annotation':
        file_path = Path(args.file).resolve()
        if not file_path.exists():
            print(f"Error: File not found: {file_path}", file=sys.stderr)
            sys.exit(1)

        content = file_path.read_text()
        project_root = find_project_root(str(file_path))

        try:
            if args.action == 'add':
                new_content = add_app_pod_annotation(content, args.app, args.key, args.value)
            elif args.action == 'remove':
                new_content = remove_app_pod_annotation(content, args.app, args.key)
            else:
                print(f"Error: Unknown action: {args.action}", file=sys.stderr)
                sys.exit(1)

            # Write and validate
            backup_path = str(file_path) + '.bak'
            shutil.copy(str(file_path), backup_path)

            try:
                file_path.write_text(new_content)

                result = subprocess.run(
                    ["cue", "vet", "-c=false", "./..."],
                    cwd=project_root,
                    capture_output=True,
                    text=True,
                    timeout=30
                )

                if result.returncode != 0:
                    shutil.move(backup_path, str(file_path))
                    print(f"Error: CUE validation failed:\n{result.stderr}", file=sys.stderr)
                    sys.exit(1)

                Path(backup_path).unlink(missing_ok=True)
                print(f"Successfully modified {file_path}")
                sys.exit(0)

            except Exception as e:
                if Path(backup_path).exists():
                    shutil.move(backup_path, str(file_path))
                raise

        except ValueError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
```

**Step 4: Update docstring at top of file to include app-annotation examples**

Add after the platform-annotation examples in the docstring:

```python
App-level pod annotation overrides:
  cue-edit.py app-annotation add <file> <app> <key> <value>
  cue-edit.py app-annotation remove <file> <app> <key>

Examples:
  # Disable Prometheus scraping for postgres (overrides platform default)
  cue-edit.py app-annotation add services/apps/postgres.cue postgres prometheus.io/scrape false

  # Remove the override (restore platform default behavior)
  cue-edit.py app-annotation remove services/apps/postgres.cue postgres prometheus.io/scrape
```

**Step 5: Run manual test**

Run:
```bash
cd /home/jmann/git/mannjg/deployment-pipeline/k8s-deployments
python3 ../scripts/demo/lib/cue-edit.py app-annotation add services/apps/postgres.cue postgres prometheus.io/scrape false
cat services/apps/postgres.cue | grep -A5 podAnnotations
git checkout services/apps/postgres.cue  # Restore
```

Expected: Shows `podAnnotations: { "prometheus.io/scrape": "false" }`

**Step 6: Commit**

```bash
git add scripts/demo/lib/cue-edit.py
git commit -m "feat(demo): add app-annotation command to cue-edit.py

Enables app-level pod annotation overrides for UC-C5 demo.
Apps can now override platform defaults like prometheus.io/scrape."
```

---

## Task 3: Create UC-C5 Demo Script

**Files:**
- Create: `scripts/demo/demo-uc-c5-app-override.sh`

**Step 1: Create the demo script**

```bash
#!/bin/bash
# Demo: Platform Default with App Override (UC-C5)
#
# This demo showcases how an app can override platform-wide defaults
# through the CUE layering system.
#
# Use Case UC-C5:
# "Platform sets Prometheus scraping on, but postgres needs it off"
#
# What This Demonstrates:
# - Platform layer sets prometheus.io/scrape: "true" for all apps (UC-C4)
# - App layer (postgres.cue) overrides to prometheus.io/scrape: "false"
# - example-app keeps the platform default (scraping enabled)
# - postgres gets the app override (scraping disabled)
#
# Prerequisites:
# - UC-C4 has been run (platform has prometheus.io/scrape: "true")
# - Postgres ArgoCD applications exist (postgres-dev/stage/prod)
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

DEMO_ANNOTATION_KEY="prometheus.io/scrape"
PLATFORM_DEFAULT_VALUE="true"
APP_OVERRIDE_VALUE="false"
OVERRIDE_APP="postgres"
UNAFFECTED_APP="example-app"
ENVIRONMENTS=("dev" "stage" "prod")

# ============================================================================
# CUE MODIFICATION FUNCTIONS
# ============================================================================

CUE_EDIT="${SCRIPT_DIR}/lib/cue-edit.py"

add_app_annotation_override() {
    demo_action "Adding app-level annotation override to postgres.cue..."

    if ! python3 "${CUE_EDIT}" app-annotation add \
        services/apps/postgres.cue postgres \
        "$DEMO_ANNOTATION_KEY" "$APP_OVERRIDE_VALUE"; then
        demo_fail "Failed to add app annotation override"
        return 1
    fi
    demo_verify "Added $DEMO_ANNOTATION_KEY: $APP_OVERRIDE_VALUE to postgres"

    return 0
}

# ============================================================================
# MAIN DEMO
# ============================================================================

cd "$K8S_DEPLOYMENTS_DIR"

demo_init "UC-C5: Platform Default with App Override"

# Load credentials
load_pipeline_credentials || exit 1

# Verify pipeline is quiescent before starting
demo_preflight_check

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

demo_action "Checking ArgoCD applications for both apps..."
for env in "${ENVIRONMENTS[@]}"; do
    for app in "$OVERRIDE_APP" "$UNAFFECTED_APP"; do
        if kubectl get application "${app}-${env}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
            demo_verify "ArgoCD app ${app}-${env} exists"
        else
            demo_fail "ArgoCD app ${app}-${env} not found"
            exit 1
        fi
    done
done

demo_action "Verifying platform default annotation exists..."
# Check that example-app has prometheus scraping enabled (from UC-C4)
if assert_pod_annotation_equals "dev" "$UNAFFECTED_APP" "$DEMO_ANNOTATION_KEY" "$PLATFORM_DEFAULT_VALUE" 2>/dev/null; then
    demo_verify "Platform default ($DEMO_ANNOTATION_KEY=$PLATFORM_DEFAULT_VALUE) is active"
else
    demo_fail "Platform default not set. Run UC-C4 demo first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Verify Current State (Both Apps Have Platform Default)
# ---------------------------------------------------------------------------

demo_step 2 "Verify Current State (Both Apps Have Platform Default)"

demo_info "Before override, both apps should have platform default annotation"

for env in "${ENVIRONMENTS[@]}"; do
    demo_action "Checking $env environment..."
    assert_pod_annotation_equals "$env" "$UNAFFECTED_APP" "$DEMO_ANNOTATION_KEY" "$PLATFORM_DEFAULT_VALUE" || exit 1
    # Postgres may or may not have the annotation initially - just note the state
    local postgres_val
    postgres_val=$(kubectl get deployment "$OVERRIDE_APP" -n "$env" \
        -o jsonpath="{.spec.template.metadata.annotations.prometheus\\.io/scrape}" 2>/dev/null || echo "not-set")
    demo_info "  postgres.$DEMO_ANNOTATION_KEY = $postgres_val"
done

# ---------------------------------------------------------------------------
# Step 3: Add App-Level Override to postgres.cue
# ---------------------------------------------------------------------------

demo_step 3 "Add App-Level Override to postgres.cue"

demo_info "Adding appConfig.deployment.podAnnotations to postgres.cue"
demo_info "  This overrides platform default for postgres only"

# Make CUE change
add_app_annotation_override || exit 1

demo_action "Summary of CUE changes:"
git diff --stat services/apps/postgres.cue 2>/dev/null || echo "    (no diff available)"

# ---------------------------------------------------------------------------
# Step 4: Push CUE Change via GitLab API
# ---------------------------------------------------------------------------

demo_step 4 "Push CUE Change to GitLab"

# Generate feature branch name
FEATURE_BRANCH="uc-c5-app-override-$(date +%s)"

GITLAB_CLI="${PROJECT_ROOT}/scripts/04-operations/gitlab-cli.sh"

demo_action "Creating branch '$FEATURE_BRANCH' from dev in GitLab..."
"$GITLAB_CLI" branch create p2c/k8s-deployments "$FEATURE_BRANCH" --from dev >/dev/null || {
    demo_fail "Failed to create branch in GitLab"
    exit 1
}

demo_action "Pushing services/apps/postgres.cue to GitLab..."
cat services/apps/postgres.cue | "$GITLAB_CLI" file update p2c/k8s-deployments services/apps/postgres.cue \
    --ref "$FEATURE_BRANCH" \
    --message "feat: disable Prometheus scraping for postgres (UC-C5)" \
    --stdin >/dev/null || {
    demo_fail "Failed to update services/apps/postgres.cue in GitLab"
    exit 1
}
demo_verify "Feature branch pushed"

# Restore local changes
git checkout services/apps/postgres.cue 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 5: MR-Gated Promotion Through Environments
# ---------------------------------------------------------------------------

demo_step 5 "MR-Gated Promotion Through Environments"

# Track baseline time for promotion MR detection
next_promotion_baseline=""

for env in "${ENVIRONMENTS[@]}"; do
    demo_info "--- Promoting to $env ---"

    # Capture baselines before MR (for both apps)
    example_argocd_baseline=$(get_argocd_revision "${UNAFFECTED_APP}-${env}")
    postgres_argocd_baseline=$(get_argocd_revision "${OVERRIDE_APP}-${env}")

    if [[ "$env" == "dev" ]]; then
        # DEV: Create MR from feature branch
        mr_iid=$(create_mr "$FEATURE_BRANCH" "$env" "UC-C5: Add app override for postgres to $env")

        # Wait for MR pipeline
        demo_action "Waiting for pipeline to generate manifests..."
        wait_for_mr_pipeline "$mr_iid" || exit 1

        # Verify MR contains expected changes
        demo_action "Verifying MR contains CUE and manifest changes..."
        assert_mr_contains_diff "$mr_iid" "services/apps/postgres.cue" "podAnnotations" || exit 1
        assert_mr_contains_diff "$mr_iid" "manifests/postgres/postgres.yaml" "prometheus.io/scrape.*false" || exit 1

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

        # Verify MR contains manifest changes
        demo_action "Verifying MR contains manifest changes..."
        assert_mr_contains_diff "$mr_iid" "manifests/postgres/postgres.yaml" "prometheus.io/scrape.*false" || exit 1

        # Capture baseline time BEFORE merge
        next_promotion_baseline=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        # Merge MR
        accept_mr "$mr_iid" || exit 1
    fi

    # Wait for ArgoCD sync (both apps)
    wait_for_argocd_sync "${UNAFFECTED_APP}-${env}" "$example_argocd_baseline" || exit 1
    wait_for_argocd_sync "${OVERRIDE_APP}-${env}" "$postgres_argocd_baseline" || exit 1

    # Verify K8s state - THE KEY ASSERTION
    demo_action "Verifying annotations diverge as expected..."
    # example-app should STILL have platform default (scraping enabled)
    assert_pod_annotation_equals "$env" "$UNAFFECTED_APP" "$DEMO_ANNOTATION_KEY" "$PLATFORM_DEFAULT_VALUE" || exit 1
    # postgres should have app override (scraping disabled)
    assert_pod_annotation_equals "$env" "$OVERRIDE_APP" "$DEMO_ANNOTATION_KEY" "$APP_OVERRIDE_VALUE" || exit 1

    demo_verify "Promotion to $env complete - apps have divergent annotations"
    echo ""
done

# ---------------------------------------------------------------------------
# Step 6: Cross-Environment Verification
# ---------------------------------------------------------------------------

demo_step 6 "Cross-Environment Verification"

demo_info "Verifying annotation divergence across ALL environments..."

demo_action "example-app should have platform default (scraping ENABLED)..."
assert_env_propagation "deployment" "$UNAFFECTED_APP" \
    "{.spec.template.metadata.annotations.prometheus\\.io/scrape}" \
    "$PLATFORM_DEFAULT_VALUE" \
    "${ENVIRONMENTS[@]}" || exit 1

demo_action "postgres should have app override (scraping DISABLED)..."
assert_env_propagation "deployment" "$OVERRIDE_APP" \
    "{.spec.template.metadata.annotations.prometheus\\.io/scrape}" \
    "$APP_OVERRIDE_VALUE" \
    "${ENVIRONMENTS[@]}" || exit 1

# ---------------------------------------------------------------------------
# Step 7: Summary
# ---------------------------------------------------------------------------

demo_step 7 "Summary"

cat << EOF

  This demo validated UC-C5: Platform Default with App Override

  What happened:
  1. Verified platform has prometheus.io/scrape: "true" (from UC-C4)
  2. Added app-level override in postgres.cue:
     appConfig.deployment.podAnnotations: {"prometheus.io/scrape": "false"}
  3. Pushed CUE change only (no manual manifest generation)
  4. Promoted through environments using GitOps pattern
  5. For each environment:
     - Pipeline generated/validated manifests
     - Merged MR after pipeline passed
     - ArgoCD synced both apps
     - Verified annotations DIVERGE correctly

  Key Observations:
  - Platform layer sets prometheus.io/scrape: "true" for ALL apps
  - App layer (postgres.cue) overrides to "false" for postgres only
  - Override chain works: Platform -> App -> Env
  - example-app: prometheus.io/scrape = "true" (platform default)
  - postgres:    prometheus.io/scrape = "false" (app override)

  Override Hierarchy Demonstrated:
    Platform (services/core/app.cue) → prometheus.io/scrape: "true"
         ↓
    App (services/apps/postgres.cue) → prometheus.io/scrape: "false" [OVERRIDES]
         ↓
    Env (env.cue per branch) → could override further if needed

EOF

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

demo_step 8 "Cleanup"

# Verify pipeline is quiescent after demo
demo_postflight_check

demo_action "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

demo_info "Feature branch '$FEATURE_BRANCH' left in place for reference"
demo_info "To delete: git branch -D $FEATURE_BRANCH"

demo_complete
```

**Step 2: Make executable**

Run:
```bash
chmod +x scripts/demo/demo-uc-c5-app-override.sh
```

**Step 3: Commit**

```bash
git add scripts/demo/demo-uc-c5-app-override.sh
git commit -m "feat(demo): add UC-C5 demo script

Demonstrates app-level override of platform defaults:
- Platform sets prometheus.io/scrape: true
- postgres.cue overrides to false
- example-app keeps platform default
- Validates override hierarchy works correctly"
```

---

## Task 4: Update run-all-demos.sh

**Files:**
- Modify: `scripts/demo/run-all-demos.sh:47`

**Step 1: Add UC-C5 to DEMO_ORDER array**

Insert after the UC-C4 line (around line 46):

```bash
    "UC-C5:demo-uc-c5-app-override.sh:Platform default with app override:dev,stage,prod"
```

The resulting section should look like:
```bash
    # Category C: Platform-Wide (full promotion)
    "UC-C1:demo-uc-c1-default-label.sh:Platform-wide label propagation:dev,stage,prod"
    "UC-C2:demo-uc-c2-security-context.sh:Platform-wide pod security context:dev,stage,prod"
    "UC-C3:demo-uc-c3-deployment-strategy.sh:Platform-wide zero-downtime deployment strategy:dev,stage,prod"
    "UC-C4:demo-uc-c4-prometheus-annotations.sh:Platform-wide pod annotations:dev,stage,prod"
    "UC-C5:demo-uc-c5-app-override.sh:Platform default with app override:dev,stage,prod"
    "UC-C6:demo-uc-c6-platform-env-override.sh:Platform default with env override:dev,stage,prod"
```

**Step 2: Commit**

```bash
git add scripts/demo/run-all-demos.sh
git commit -m "feat(demo): add UC-C5 to run-all-demos.sh"
```

---

## Task 5: Update USE_CASES.md

**Files:**
- Modify: `docs/USE_CASES.md:415`

**Step 1: Update Implementation Status for UC-C5**

Change:
```markdown
| UC-C5 | Platform default + app override | 🔲 | 🔲 | 🔲 | — | Multi-app pivot (uses postgres) |
```

To:
```markdown
| UC-C5 | Platform default + app override | ✅ | ✅ | 🔲 | `uc-c5-app-override` | Uses postgres to override platform prometheus annotation |
```

**Step 2: Add Demo Script entry in the Phase 2 table (around line 354)**

Add after UC-C4:
```markdown
| [`scripts/demo/demo-uc-c5-app-override.sh`](../scripts/demo/demo-uc-c5-app-override.sh) | UC-C5 | App-level override of platform default (postgres disables Prometheus scraping) |
```

**Step 3: Commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: update UC-C5 implementation status"
```

---

## Task 6: Run E2E Validation

**Step 1: Run the full demo suite**

Run:
```bash
./scripts/demo/run-all-demos.sh
```

Expected: All demos pass including UC-C5

**Step 2: If UC-C5 fails, debug and fix**

Check the specific failure:
- If ArgoCD apps missing: Re-run Task 1
- If cue-edit.py fails: Check Task 2 implementation
- If assertion fails: Check manifest generation

**Step 3: After all pass, update USE_CASES.md status**

Change UC-C5 row to show Pipeline Verified:
```markdown
| UC-C5 | Platform default + app override | ✅ | ✅ | ✅ | `uc-c5-app-override` | Pipeline verified YYYY-MM-DD |
```

**Step 4: Final commit**

```bash
git add docs/USE_CASES.md
git commit -m "docs: mark UC-C5 as pipeline verified"
```

---

## Verification Checklist

After implementation, verify:

- [ ] `kubectl get applications -n argocd | grep postgres` shows 3 apps (dev/stage/prod)
- [ ] All postgres ArgoCD apps are Synced and Healthy
- [ ] `python3 scripts/demo/lib/cue-edit.py app-annotation --help` shows usage
- [ ] `./scripts/demo/demo-uc-c5-app-override.sh` runs successfully
- [ ] After UC-C5 demo: example-app has `prometheus.io/scrape: "true"` in all envs
- [ ] After UC-C5 demo: postgres has `prometheus.io/scrape: "false"` in all envs
- [ ] `./scripts/demo/run-all-demos.sh` passes all tests
- [ ] `./scripts/test/validate-pipeline.sh` still passes (no regression)
