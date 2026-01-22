# Version Lifecycle Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:writing-plans to create implementation plan from this design.

## Goal

Implement version lifecycle management: SNAPSHOT (dev) → RC (stage) → Release (prod), ensuring the same binary is promoted through all environments with appropriate version tagging.

## Version Progression

| Environment | Version Format | Example | Nexus Repository |
|-------------|----------------|---------|------------------|
| Dev | `{base}-SNAPSHOT-{hash}` | `1.0.0-SNAPSHOT-abc123` | maven-snapshots |
| Stage | `{base}-rc{N}-{hash}` | `1.0.0-rc1-abc123` | maven-releases |
| Prod | `{base}-{hash}` | `1.0.0-abc123` | maven-releases |

## Design Decisions

### Same Binary, Re-tagged Per Environment
- JAR built once as SNAPSHOT, re-deployed with new Maven coordinates for RC/Release
- Docker image re-tagged (not rebuilt) for each environment
- Git hash suffix on all tags provides traceability to source commit

### RC Number Increments Only When Code Changes
- Same SNAPSHOT re-promoted to stage keeps same RC number
- New SNAPSHOT (different git hash) increments RC: `rc1` → `rc2`
- Query Nexus for existing RCs to determine next number

### Maven Artifact Re-deployment
- Use `mvn deploy:deploy-file` to deploy same JAR with new version coordinates
- Avoids rebuild variance, guarantees byte-for-byte identical binary
- SNAPSHOT → maven-snapshots (overwritable)
- RC/Release → maven-releases (immutable)

### Artifact Versioning at MR Creation Time
- When `createPromotionMR()` runs, immediately create RC/Release artifacts
- MR diff shows the exact version that will be deployed
- Artifacts ready and waiting when MR merges
- ArgoCD deployment is just a manifest apply (no post-merge artifact creation)

### Manual Base Version Management
- Developers manually update pom.xml version (e.g., `1.0.0-SNAPSHOT` → `1.1.0-SNAPSHOT`)
- No automatic version bumping after prod release
- Keeps control explicit, avoids semver assumptions

### Immutability Enforcement
- SNAPSHOT: Overwritable (Nexus maven-snapshots policy)
- RC: Immutable (new RC number if different code)
- Release: Immutable, hard error if already exists in Nexus

## Components

### 1. promote-artifact.sh

**Location:** `k8s-deployments/scripts/promote-artifact.sh`

**Interface:**
```bash
./scripts/promote-artifact.sh \
  --source-env dev \
  --target-env stage \
  --app-name example-app \
  --git-hash abc123
```

**Responsibilities:**
1. Determine target version:
   - Read base version from source env's current image tag
   - For stage: Query Nexus for existing RCs, calculate next
   - For prod: Use base version only, error if exists
2. Promote Maven artifact:
   - Download JAR from Nexus (source version)
   - Deploy with new version via `mvn deploy:deploy-file`
3. Promote Docker image:
   - Pull source image
   - Re-tag with target version
   - Push re-tagged image
4. Output new image tag for caller

### 2. Modified createPromotionMR()

**Location:** `k8s-deployments/Jenkinsfile`

**Changes:**
```groovy
// Before promote-app-config.sh, call promote-artifact.sh
def newImageTag = sh(
    script: """
        ./scripts/promote-artifact.sh \
            --source-env ${sourceEnv} \
            --target-env ${targetEnv} \
            --app-name example-app \
            --git-hash ${gitHash}
    """,
    returnStdout: true
).trim()

// Update env.cue with newImageTag
// Then proceed with existing flow
```

**Updated Flow:**
1. Call `promote-artifact.sh` → Get new image tag
2. Copy app config from source to target
3. Update env.cue with new image tag
4. Regenerate manifests
5. Commit and push promotion branch
6. Create MR via GitLab API

### 3. Extended validate-pipeline.sh

**New Validation Function:**
```bash
verify_version_lifecycle() {
    # 1. Check dev has SNAPSHOT version
    dev_image=$(get_deployed_image "dev")
    assert_image_tag_matches "$dev_image" "*-SNAPSHOT-*"

    # 2. Check stage has RC version
    stage_image=$(get_deployed_image "stage")
    assert_image_tag_matches "$stage_image" "*-rc[0-9]*-*"

    # 3. Check prod has release version
    prod_image=$(get_deployed_image "prod")
    refute_image_tag_matches "$prod_image" "*-SNAPSHOT-*"
    refute_image_tag_matches "$prod_image" "*-rc[0-9]*-*"

    # 4. Verify same git hash across all environments
    assert_same_git_hash "$dev_image" "$stage_image" "$prod_image"

    # 5. Verify artifacts exist in Nexus
    assert_nexus_artifact_exists "example-app" "$dev_version" "maven-snapshots"
    assert_nexus_artifact_exists "example-app" "$stage_version" "maven-releases"
    assert_nexus_artifact_exists "example-app" "$prod_version" "maven-releases"
}
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Re-promoting same SNAPSHOT | Skip (same git hash = no new RC) |
| Promoting new SNAPSHOT | Increment RC number |
| Release version exists | Hard error, message to bump version |
| Source artifact missing | Fail fast, clear error message |
| Network/Nexus failure | Error out, re-run to retry (idempotent) |

## Rollback Consideration

Rolling back stage/prod does not require version changes:
- ArgoCD reverts to previous manifest (previous image tag)
- Old artifacts still exist in Nexus (immutable)
- No special rollback versioning needed

## Files to Create/Modify

| File | Action |
|------|--------|
| `k8s-deployments/scripts/promote-artifact.sh` | Create |
| `k8s-deployments/Jenkinsfile` | Modify `createPromotionMR()` |
| `scripts/test/validate-pipeline.sh` | Add version lifecycle validation |
| `scripts/demo/lib/assertions.sh` | Add version assertion helpers |
