# JENKINS-26: Handle Maven release artifact duplicate on re-run

**Date:** 2026-02-09
**Files:** `example-app/Jenkinsfile` (Build & Publish stage)

## Problem

In the Build & Publish stage, Docker image push (via Quarkus Jib) happens before Maven artifact deploy. This causes two issues:

1. **State divergence on partial failure:** If Maven deploy fails (e.g., duplicate release artifact in `maven-releases`), the Docker image already exists in the registry but the Maven artifact doesn't.
2. **Re-run failure:** For release versions (non-SNAPSHOT), Nexus `maven-releases` rejects duplicate GAV coordinates. Re-running a successful build crashes at `mvn deploy`.

## Design

Reorder the Build & Publish stage into two commands:

1. `mvn clean deploy -DskipTests` with Maven settings — clean build + deploy Maven artifact to Nexus first. Fails fast on duplicate release before any image is pushed.
2. `mvn package` with Quarkus container-image flags (no `clean`) — reuses compiled output from step 1, only builds/pushes the Docker image via Jib.

### Why two commands instead of one

Maven lifecycle phases are fixed: `package` (where Quarkus pushes the Docker image) always runs before `deploy` (where Maven publishes artifacts). A single `mvn deploy` with container-image flags would still push the Docker image before the Maven artifact, preserving the state divergence problem.

### Why no `clean` on the second command

The first command already does a clean build. Dropping `clean` from the second command avoids redundantly wiping `target/` and rebuilding, since `mvn package` reuses the existing build output.

## Acceptance criteria

- Re-running a build that previously succeeded does not fail (SNAPSHOT versions are idempotent; release versions fail fast before image push)
- On partial failure, no state divergence between Nexus and Docker registry
