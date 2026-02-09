# JENKINS-28: Replace /tmp/maven-settings.xml with scoped credential pattern

**Date:** 2026-02-09
**Status:** Implementing
**Files:** `example-app/Jenkinsfile`

## Problem

`createMavenSettings()` writes Nexus credentials to a hardcoded `/tmp/maven-settings.xml`. This is a bad pattern for a reference implementation — shared temp path, no automatic cleanup on abort/timeout.

## Solution

Delete `createMavenSettings()` and inline the settings file creation within the same `sh` block that runs `mvn deploy`, using `mktemp` + `trap EXIT` for automatic scoped cleanup.

This is consistent with the `mktemp` pattern already used in `k8s-deployments/scripts/promote-artifact.sh`.

## Changes

1. Remove `createMavenSettings()` function
2. Remove `createMavenSettings()` call in Build & Publish stage
3. Combine settings generation + `mvn deploy` into a single `sh` block with `mktemp` + `trap`

## Acceptance Criteria

- Maven settings file is scoped to the block that needs it (not written to a shared temp path)
- No cleanup code needed for the settings file
