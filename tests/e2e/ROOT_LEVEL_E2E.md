# Root-Level E2E Pipeline Test

## Why Root Level?

The E2E test is at the **root level** (`deployment-pipeline/tests/e2e/`) because it needs to test changes from **BOTH** repositories:

1. **`example-app/`** - Application source code changes
2. **`k8s-deployments/`** - Infrastructure/configuration changes

Both types of changes flow through the same promotion pipeline:
```
Change → Jenkins Build → Dev → Stage (MR) → Prod (MR)
```

## Directory Structure

```
deployment-pipeline/
├── tests/e2e/                    # Root-level E2E tests
│   ├── test-full-pipeline.sh     # Main orchestrator
│   ├── config/
│   │   └── e2e-config.sh         # Configure TEST_REPO here
│   ├── lib/                      # E2E-specific libs (GitLab, Jenkins, Git)
│   ├── stages/                   # 6 pipeline stages
│   └── README.md                 # Full documentation
│
├── example-app/                  # Application repository
│   ├── .git/ → gitlab.local
│   ├── src/                      # Java source code
│   └── pom.xml
│
└── k8s-deployments/              # Deployment repository
    ├── .git/ → gitlab.local
    ├── envs/                     # CUE configs
    ├── manifests/                # Generated YAML
    └── tests/lib/                # K8s testing libraries (reused by E2E)
```

## Running E2E Tests

### Test Application Changes (example-app)

```bash
cd tests/e2e
export TEST_REPO="example-app"
./test-full-pipeline.sh
```

This will:
1. Create a test file in `example-app/src/test/resources/`
2. Push to example-app dev branch
3. Trigger Jenkins build
4. Verify deployments through dev → stage → prod

### Test Infrastructure Changes (k8s-deployments)

```bash
cd tests/e2e
export TEST_REPO="k8s-deployments"
./test-full-pipeline.sh
```

This will:
1. Update VERSION.txt in k8s-deployments
2. Push to k8s-deployments dev branch
3. Trigger pipeline
4. Verify deployments through dev → stage → prod

### Default Behavior

By default, `TEST_REPO="example-app"` (configured in `config/e2e-config.sh`)

## How It Works

1. **Stage 01** determines which repo to work in based on `TEST_REPO`
2. Navigates to the appropriate subproject directory
3. Creates test changes specific to that repository type:
   - **example-app**: Adds test marker file
   - **k8s-deployments**: Bumps VERSION.txt
4. Both trigger the same Jenkins job and flow through the same pipeline

## Library Dependencies

The E2E test uses:
- **Root-level E2E libs** (`tests/e2e/lib/`): GitLab API, Jenkins API, Git operations
- **k8s-deployments test libs** (`k8s-deployments/tests/lib/`): Common, assertions, cleanup

This separation ensures:
- E2E-specific logic (API integrations) stays with E2E tests
- K8s/ArgoCD testing logic stays with k8s-deployments
- Both are reusable

## Configuration

Edit `tests/e2e/config/e2e-config.sh`:

```bash
# Choose which repository to test
export TEST_REPO="example-app"  # or "k8s-deployments"

# Repository paths
export EXAMPLE_APP_PATH="example-app"
export K8S_DEPLOYMENTS_PATH="k8s-deployments"

# Branches
export DEV_BRANCH="dev"
export STAGE_BRANCH="stage"
export PROD_BRANCH="prod"
```

## Benefits of Root-Level E2E

✅ Can test changes from either repository
✅ Both flow through same pipeline
✅ Simulates real developer workflow
✅ Tests complete CI/CD + GitOps flow
✅ No duplication of E2E logic

## See Also

- **[README.md](README.md)** - Complete E2E test documentation
- **[QUICK_START.md](QUICK_START.md)** - 5-minute setup guide
- **[E2E_TEST_IMPLEMENTATION.md](E2E_TEST_IMPLEMENTATION.md)** - Technical details
