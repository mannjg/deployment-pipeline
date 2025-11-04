# Deployment Pipeline Regression Test Suite

Comprehensive regression tests to ensure all pipeline components are working as expected.

## Overview

This test suite validates:
- ✅ CUE schema and configuration validation
- ✅ Manifest generation (K8s resources + ArgoCD Applications)
- ✅ Kubernetes cluster operations
- ✅ ArgoCD Application management
- ✅ GitLab integration (coming soon)
- ✅ CI/CD pipeline (coming soon)
- ✅ End-to-end deployment flow (coming soon)

## Test Structure

```
tests/
├── regression-test.sh          # Main test runner
├── lib/                        # Shared libraries
│   ├── common.sh              # Utilities and logging
│   ├── assertions.sh          # Test assertions
│   ├── cleanup.sh             # Cleanup functions
│   └── reporting.sh           # Report generation
├── unit/                       # Unit tests (fast)
│   └── test-cue-validation.sh # CUE validation tests
├── integration/                # Integration tests
│   ├── test-kubernetes.sh     # K8s operations
│   └── test-argocd.sh         # ArgoCD operations
└── e2e/                        # End-to-end tests
    └── (coming soon)
```

## Quick Start

### Run All Tests

```bash
cd k8s-deployments/tests
./regression-test.sh --full
```

### Run Quick Validation (Unit Tests Only)

```bash
./regression-test.sh --quick
```

### Run with HTML Report

```bash
./regression-test.sh --full --html report.html
```

## Test Modes

### Test Scope Options

| Option | Description | Phases Run | Duration |
|--------|-------------|------------|----------|
| `--quick` | Fast validation | Pre-flight + Unit | ~2 min |
| `--integration` | Unit + Integration | Pre-flight + Unit + Integration | ~5-10 min |
| `--full` | Complete suite | All phases including E2E | ~20-30 min |

### Test Selection

Run specific test categories:

```bash
# Only CUE validation tests
./regression-test.sh --only-cue

# Only Kubernetes tests
./regression-test.sh --only-k8s

# Only ArgoCD tests
./regression-test.sh --only-argocd

# Skip specific phases
./regression-test.sh --skip-e2e
./regression-test.sh --skip-integration
```

## Test Phases

### Phase 1: Pre-Flight Checks (10-30s)

Validates prerequisites:
- Required tools installed (cue, kubectl, git, curl, jq, yq)
- Kubernetes cluster accessible
- ArgoCD installed
- GitLab accessible

```bash
./regression-test.sh --only-preflight
```

### Phase 2: Unit Tests (1-2 min)

Fast, isolated tests:
- CUE schemas compile correctly
- Environment configs validate
- Manifest generation succeeds
- YAML output is well-formed
- Required fields present

```bash
./regression-test.sh --quick
```

### Phase 3: Integration Tests (5-10 min)

Component interaction tests:
- Kubernetes resource CRUD operations
- Namespace isolation
- RBAC permissions
- ArgoCD Application validation
- Sync policy verification
- Health and sync status checks

```bash
./regression-test.sh --integration
```

### Phase 4: End-to-End Tests (10-15 min) ⚠️ Coming Soon

Full pipeline validation:
- Code change → CI trigger
- Container build and push
- GitOps repo update
- ArgoCD sync
- Pod rollout
- Health verification

## Cleanup Options

### Cleanup Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `--cleanup-always` | Always cleanup (default) | Normal runs |
| `--cleanup-on-success` | Cleanup only if tests pass | Debugging failures |
| `--no-cleanup` | Never cleanup | Investigation |

```bash
# Keep artifacts on failure for debugging
./regression-test.sh --cleanup-on-success

# Never cleanup (for manual inspection)
./regression-test.sh --no-cleanup
```

### What Gets Cleaned Up

- Test namespaces (`pipeline-test-*`)
- Test ArgoCD Applications
- Test Git branches
- Temporary directories

## Output and Reporting

### Verbosity Levels

```bash
# Default output
./regression-test.sh

# Verbose (show debug info)
./regression-test.sh -v

# Very verbose (show all commands)
./regression-test.sh -vv

# Quiet (errors only)
./regression-test.sh -q
```

### Report Formats

#### JUnit XML (for CI integration)

```bash
./regression-test.sh --junit results.xml
```

#### HTML Report (for human consumption)

```bash
./regression-test.sh --html report.html
open report.html
```

#### JSON Report (for programmatic parsing)

```bash
./regression-test.sh --json results.json
```

### Multiple Reports

```bash
./regression-test.sh \
    --junit ci-results.xml \
    --html human-report.html \
    --json api-results.json
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | Some tests failed |
| 2 | Fatal error (missing prerequisites, etc.) |

## Example Usage Scenarios

### Pre-Commit Validation

Fast feedback before committing:

```bash
./regression-test.sh --quick
```

### CI Pipeline

Full validation in CI:

```bash
#!/bin/bash
./regression-test.sh \
    --full \
    --junit test-results.xml \
    --fail-fast \
    --cleanup-always
```

### Post-Deployment Validation

Verify deployment health:

```bash
./regression-test.sh \
    --only-argocd \
    --only-k8s \
    -v
```

### Troubleshooting

Debug with artifacts preserved:

```bash
./regression-test.sh \
    --integration \
    --no-cleanup \
    -vv
```

## Test Results Interpretation

### Success Output

```
========================================
         TEST RESULTS SUMMARY
========================================

Total Tests:   45
Passed:        45
Failed:        0
Skipped:       0

Duration:      00:02:15

========================================

✓ ALL TESTS PASSED
```

### Failure Output

```
========================================
         TEST RESULTS SUMMARY
========================================

Total Tests:   45
Passed:        42
Failed:        3
Skipped:       0

Duration:      00:02:15

========================================

✗ TESTS FAILED
```

## Extending the Test Suite

### Adding New Unit Tests

1. Create test script in `unit/`:

```bash
# unit/test-my-feature.sh
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/assertions.sh"

run_my_feature_tests() {
    log_info "===== My Feature Tests ====="

    assert_success \
        "My feature works" \
        "my-command --test"

    log_info "===== My Feature Tests Complete ====="
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_my_feature_tests
fi
```

2. Source in `regression-test.sh`:

```bash
# In run_unit_tests() function
source "$SCRIPT_DIR/unit/test-my-feature.sh"
run_my_feature_tests
```

### Adding New Integration Tests

Follow the same pattern in `integration/` directory.

### Adding New Assertions

Add to `lib/assertions.sh`:

```bash
assert_my_condition() {
    local description=$1
    local value=$2

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log_test "$description"

    if [ "my_check" = "expected" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_pass "$description"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_fail "$description"
        return 1
    fi
}
```

## Troubleshooting

### Tests Hang or Timeout

Increase timeout values in assertions or skip long-running tests:

```bash
./regression-test.sh --skip-e2e
```

### Cleanup Fails

Manual cleanup:

```bash
# Delete test namespaces
kubectl delete namespace -l test=pipeline-regression

# Delete test ArgoCD apps
kubectl delete applications -n argocd -l test=pipeline-regression
```

### Missing Prerequisites

Install required tools:

```bash
# Ubuntu/Debian
apt-get install jq yq

# macOS
brew install jq yq

# CUE
go install cuelang.org/go/cmd/cue@latest
```

## CI/CD Integration

### GitLab CI

```yaml
test:
  stage: test
  script:
    - cd k8s-deployments/tests
    - ./regression-test.sh --full --junit results.xml
  artifacts:
    reports:
      junit: k8s-deployments/tests/results.xml
    when: always
```

### GitHub Actions

```yaml
- name: Run Regression Tests
  run: |
    cd k8s-deployments/tests
    ./regression-test.sh --full --junit results.xml

- name: Publish Test Results
  uses: EnricoMi/publish-unit-test-result-action@v2
  if: always()
  with:
    files: k8s-deployments/tests/results.xml
```

### Jenkins

```groovy
stage('Test') {
    steps {
        sh '''
            cd k8s-deployments/tests
            ./regression-test.sh --full --junit results.xml
        '''
    }
    post {
        always {
            junit 'k8s-deployments/tests/results.xml'
        }
    }
}
```

## Performance Tips

1. **Use --quick for fast feedback** during development
2. **Run --integration in CI** for merge requests
3. **Run --full nightly** or before releases
4. **Use --fail-fast** in CI to save time
5. **Use --cleanup-on-success** for debugging

## Support

For issues or questions:
1. Check test output with `-vv` flag
2. Review test artifacts (if using `--no-cleanup`)
3. Check individual test scripts in `unit/` and `integration/`
4. Review logs in Kubernetes and ArgoCD

## Future Enhancements

- [ ] GitLab integration tests
- [ ] Jenkins pipeline tests
- [ ] Container registry tests
- [ ] End-to-end deployment tests
- [ ] Performance benchmarking
- [ ] Chaos testing (failure scenarios)
- [ ] Multi-cluster tests
- [ ] Security scanning integration
