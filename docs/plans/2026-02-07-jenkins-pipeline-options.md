# JENKINS-03: Pipeline Options (timestamps + ansiColor) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `timestamps()` and `ansiColor('xterm')` to all pipeline options blocks so console output includes timestamps and renders ANSI color codes.

**Architecture:** Add two Jenkins plugins to Helm values, then add the corresponding pipeline options to each Jenkinsfile. `timestamps()` goes in all 4 Jenkinsfiles; `ansiColor('xterm')` goes in 3 (excluding auto-promote which is a lightweight router with `agent none`).

**Tech Stack:** Jenkins Declarative Pipeline, Helm values.yaml

---

### Task 1: Add timestamper and ansicolor plugins to Helm values

**Files:**
- Modify: `k8s/jenkins/values.yaml:67-80`

**Step 1: Add both plugins to installPlugins list**

After line 80 (`build-token-root`), add:

```yaml
    - timestamper:1.30
    - ansicolor:536.v13fa_b_860c267
```

The full `installPlugins` block should read:

```yaml
  installPlugins:
    - kubernetes:4358.v6b_9051ba_aa_87
    - workflow-aggregator:600.vb_57cdd26fdd7
    - git:5.7.1
    - configuration-as-code:1900.v1e167e2b_bd2f
    - gitlab-plugin:1.9.4
    - docker-workflow:580.vc0c340686b_54
    - pipeline-stage-view:2.35
    - credentials-binding:713.ve4cb_8839a_9c5
    - job-dsl:1.93
    - matrix-auth:3.2.4
    - pipeline-utility-steps:2.17.0
    - http_request:1.20
    - build-token-root:151.va_e52fe3215fc  # Enables token-based remote builds bypassing CRUMB
    - timestamper:1.30
    - ansicolor:536.v13fa_b_860c267
```

**Step 2: Commit**

```bash
git add k8s/jenkins/values.yaml
git commit -m "feat(jenkins): add timestamper and ansicolor plugins to Helm values"
```

---

### Task 2: Add timestamps() and ansiColor('xterm') to example-app/Jenkinsfile

**Files:**
- Modify: `example-app/Jenkinsfile:238-242`

**Step 1: Add both options**

The current `options` block (lines 238-242):

```groovy
    options {
        timeout(time: 1, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '10', daysToKeepStr: '30'))
        disableConcurrentBuilds()
    }
```

Replace with:

```groovy
    options {
        timestamps()
        ansiColor('xterm')
        timeout(time: 1, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '10', daysToKeepStr: '30'))
        disableConcurrentBuilds()
    }
```

**Step 2: Commit**

```bash
git add example-app/Jenkinsfile
git commit -m "feat(jenkins): add timestamps and ansiColor to example-app pipeline"
```

---

### Task 3: Add timestamps() and ansiColor('xterm') to k8s-deployments/Jenkinsfile

**Files:**
- Modify: `k8s-deployments/Jenkinsfile:593-597`

**Step 1: Add both options**

The current `options` block (lines 593-597):

```groovy
    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '60'))
        disableConcurrentBuilds()
    }
```

Replace with:

```groovy
    options {
        timestamps()
        ansiColor('xterm')
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '60'))
        disableConcurrentBuilds()
    }
```

**Step 2: Commit**

```bash
git add k8s-deployments/Jenkinsfile
git commit -m "feat(jenkins): add timestamps and ansiColor to k8s-deployments pipeline"
```

---

### Task 4: Add timestamps() and ansiColor('xterm') to Jenkinsfile.promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.promote:90-94`

**Step 1: Add both options**

The current `options` block (lines 90-94):

```groovy
    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', daysToKeepStr: '30'))
        disableConcurrentBuilds()
    }
```

Replace with:

```groovy
    options {
        timestamps()
        ansiColor('xterm')
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20', daysToKeepStr: '30'))
        disableConcurrentBuilds()
    }
```

**Step 2: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.promote
git commit -m "feat(jenkins): add timestamps and ansiColor to promote pipeline"
```

---

### Task 5: Add timestamps() only to Jenkinsfile.auto-promote

**Files:**
- Modify: `k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote:25-28`

**Step 1: Add timestamps() only (no ansiColor — lightweight router with agent none)**

The current `options` block (lines 25-28):

```groovy
    options {
        timeout(time: 2, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '50', daysToKeepStr: '7'))
    }
```

Replace with:

```groovy
    options {
        timestamps()
        timeout(time: 2, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '50', daysToKeepStr: '7'))
    }
```

**Step 2: Commit**

```bash
git add k8s-deployments/jenkins/pipelines/Jenkinsfile.auto-promote
git commit -m "feat(jenkins): add timestamps to auto-promote pipeline"
```
