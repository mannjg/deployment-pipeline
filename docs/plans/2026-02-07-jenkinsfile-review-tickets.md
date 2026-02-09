# Jenkinsfile Review - Improvement Tickets

**Date:** 2026-02-07
**Scope:** All Jenkinsfiles, supporting scripts, Jenkins agent Dockerfile
**Source:** Comprehensive review covering security, correctness, operability, idempotency, failure modes, and race conditions.

Tickets are grouped for efficient single-session execution and ordered so prerequisites come first.

---

## JENKINS-11: Remove vestigial Docker socket mount from example-app

**Files:** `example-app/Jenkinsfile`

**Problem:** Lines 228-233 mount the host Docker socket (`/var/run/docker.sock`) into the agent pod. This grants root-equivalent access to the host. The pipeline builds images via Quarkus/Jib (which pushes directly to the registry without a Docker daemon), so the socket mount is unused.

The k8s-deployments pipeline correctly uses a DinD sidecar instead.

**Fix:** Remove the `volumeMounts` and `volumes` entries for `docker-sock` from the pod YAML template.

**Acceptance criteria:**
- Pod YAML has no `docker-sock` volume or volumeMount
- `mvn clean package -Dquarkus.container-image.build=true -Dquarkus.container-image.push=true` still succeeds

