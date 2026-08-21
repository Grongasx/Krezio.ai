---
name: versioning-and-releases
description: Semantic versioning guidelines, release management workflows, Git tagging standards, release note generation, and CHANGELOG maintenance for Krezio.ai.
---

# Krezio.ai Versioning & Release Guidelines

This skill defines the Semantic Versioning (SemVer 2.0.0) policy, Git branching and tagging workflows, CHANGELOG maintenance rules, and release note documentation standards for **Krezio.ai**.

---

## 1. Versioning Scheme (SemVer 2.0.0)

Krezio.ai follows **Semantic Versioning 2.0.0** with pre-release identifiers:

`v<MAJOR>.<MINOR>.<PATCH>[-<PRE_RELEASE>]`

- **MAJOR (`X.0.0`):** Breaking changes to core architecture, API contracts, or storage schemas.
- **MINOR (`0.X.0`):** New features, model updates, new UI screens, or dataset expansions (backward-compatible).
- **PATCH (`0.0.X`):** Bug fixes, performance optimizations, rule tweaks, or documentation updates.
- **PRE-RELEASE (`-alpha`, `-beta`, `-rc.X`):**
  - `-alpha`: Internal development releases, experimental features, active benchmarks (Current: `v0.3.2-alpha`).
  - `-beta`: Feature-complete builds undergoing public user testing.
  - `-rc.X`: Release Candidate builds awaiting production rollout.

---

## 2. Release Workflow Runbook

When cutting a new release for Krezio.ai, follow this step-by-step procedure:

### Step 1: Update Version Identifiers
1. **`pubspec.yaml`**: Update the version tag:
   ```yaml
   version: 0.3.2+3
   ```
2. **`CHANGELOG.md`**: Add the release header and list all added, changed, fixed, and deprecated features:
   ```markdown
   ## [v0.3.2-alpha] - 2026-08-21
   ```

### Step 2: Create Release Notes Document
Create a dedicated release note artifact in `docs/releases/v<VERSION>.md` detailing:
- Executive Summary of the release.
- Benchmark Accuracy Metrics & Latency.
- New Features & Improvements.
- Architectural Decisions (ADRs) added.
- Upgrade/Migration instructions.

### Step 3: Git Commit & Semantic Tagging
1. Stage all changes:
   ```bash
   git add .
   ```
2. Create a conventional commit:
   ```bash
   git commit -m "feat(release): v0.3.2-alpha - On-Device NLP Engine, Flutter Chat UI & 2k Stress Benchmarks"
   ```
3. Create an annotated Git tag:
   ```bash
   git tag -a v0.3.2-alpha -m "Release v0.3.2-alpha"
   ```
4. Push to remote repository:
   ```bash
   git push origin main --tags
   ```

---

## 3. Conventional Commit Guidelines

- `feat(scope)`: A new feature for the user or engine.
- `fix(scope)`: A bug fix or error correction.
- `docs(scope)`: Documentation updates (TG, ADRs, release notes).
- `perf(scope)`: Performance optimization or latency reduction.
- `test(scope)`: Benchmark suite expansion or adversarial test additions.
- `refactor(scope)`: Code restructuring without changing external behavior.
