#!/bin/bash
# Unit tests for CUE validation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test libraries
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/assertions.sh
source "$SCRIPT_DIR/../lib/assertions.sh"

run_cue_validation_tests() {
    log_info "===== Running CUE Validation Tests ====="
    echo

    # Test: CUE schemas compile
    assert_success \
        "CUE argocd schema compiles" \
        "cd '$PROJECT_ROOT' && cue vet argocd/schema.cue"

    assert_success \
        "CUE argocd defaults compile" \
        "cd '$PROJECT_ROOT' && cue vet argocd/defaults.cue"

    assert_success \
        "CUE argocd application template compiles" \
        "cd '$PROJECT_ROOT' && cue vet argocd/application.cue"

    assert_success \
        "CUE services base schema compiles" \
        "cd '$PROJECT_ROOT' && cue vet services/base/schema.cue"

    assert_success \
        "CUE services base defaults compile" \
        "cd '$PROJECT_ROOT' && cue vet services/base/defaults.cue"

    assert_success \
        "CUE services core app template compiles" \
        "cd '$PROJECT_ROOT' && cue vet services/core/app.cue"

    # Test: Environment configs compile
    assert_success \
        "Dev environment config compiles" \
        "cd '$PROJECT_ROOT' && cue vet envs/dev.cue"

    assert_success \
        "Stage environment config compiles" \
        "cd '$PROJECT_ROOT' && cue vet envs/stage.cue"

    assert_success \
        "Prod environment config compiles" \
        "cd '$PROJECT_ROOT' && cue vet envs/prod.cue"

    # Test: Manifest generation succeeds
    local temp_dir
    temp_dir=$(mktemp -d)

    assert_success \
        "Generate dev manifests" \
        "cd '$PROJECT_ROOT' && MANIFEST_DIR='$temp_dir/dev' ./scripts/generate-manifests.sh dev > /dev/null 2>&1"

    assert_success \
        "Generate stage manifests" \
        "cd '$PROJECT_ROOT' && MANIFEST_DIR='$temp_dir/stage' ./scripts/generate-manifests.sh stage > /dev/null 2>&1"

    assert_success \
        "Generate prod manifests" \
        "cd '$PROJECT_ROOT' && MANIFEST_DIR='$temp_dir/prod' ./scripts/generate-manifests.sh prod > /dev/null 2>&1"

    # Test: Generated manifests are valid YAML
    for env in dev stage prod; do
        if [ -f "$temp_dir/$env/example-app.yaml" ]; then
            assert_success \
                "Generated $env manifest is valid YAML" \
                "yq eval '.' '$temp_dir/$env/example-app.yaml' > /dev/null"
        fi
    done

    # Test: ArgoCD Application manifests are valid
    for env in dev stage prod; do
        local argocd_manifest="$PROJECT_ROOT/manifests/argocd/example-app-$env.yaml"
        if [ -f "$argocd_manifest" ]; then
            assert_success \
                "ArgoCD Application manifest for $env is valid YAML" \
                "yq eval '.' '$argocd_manifest' > /dev/null"

            assert_success \
                "ArgoCD Application for $env has correct apiVersion" \
                "yq eval '.apiVersion' '$argocd_manifest' | grep -q 'argoproj.io/v1alpha1'"

            assert_success \
                "ArgoCD Application for $env has correct kind" \
                "yq eval '.kind' '$argocd_manifest' | grep -q 'Application'"

            assert_success \
                "ArgoCD Application for $env has metadata.name" \
                "yq eval '.metadata.name' '$argocd_manifest' | grep -q 'example-app-$env'"

            assert_success \
                "ArgoCD Application for $env has spec.source.repoURL" \
                "yq eval '.spec.source.repoURL' '$argocd_manifest' | grep -q '.'"

            assert_success \
                "ArgoCD Application for $env has spec.destination.namespace" \
                "yq eval '.spec.destination.namespace' '$argocd_manifest' | grep -q '$env'"
        else
            skip_test "ArgoCD Application manifest for $env" "manifest not found"
        fi
    done

    # Cleanup temp directory
    rm -rf "$temp_dir"

    echo
    log_info "===== CUE Validation Tests Complete ====="
    echo
}

# Run tests if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_cue_validation_tests
fi
