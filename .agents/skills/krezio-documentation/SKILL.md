---
name: krezio-documentation
description: >-
  Guidelines and standards for documenting all software development processes, architecture decisions, feature specs, and changelogs for Krezio.ai.
  Use whenever planning, creating new features, refactoring architecture, writing technical specs, or documenting development progress.
---

# Krezio.ai Software Process Documentation Skill

This skill defines the mandatory guidelines and workflows for documenting the entire software development lifecycle of **Krezio.ai**. It ensures that all architecture decisions, feature specifications, API contracts, code changes, and progress updates are consistently documented and tracked.

---

## 1. Documentation Taxonomy & Hierarchy

All project documentation must be organized cleanly under the repository root:

```text
Krezio.ai/
├── .agents/
│   └── skills/                  # AI agent skills & runbooks
│       ├── krezio-brand/        # Brand, design system & UX writing rules
│       └── krezio-documentation/ # Software process documentation skill
├── docs/                        # Technical & Project Documentation
│   ├── architecture/            # System architecture, data flow, state management
│   │   └── adr/                 # Architecture Decision Records (ADRs)
│   ├── features/                # Feature specs, user flows, and acceptance criteria
│   ├── api/                     # API specifications, endpoints, AI integration docs
│   └── guides/                  # Onboarding, setup, deployment, testing runbooks
├── CHANGELOG.md                 # Product version history & release notes
└── README.md                    # Project overview & quickstart
```

---

## 2. Architecture Decision Records (ADR) Protocol

Whenever a major architectural decision is made (e.g., state management pattern, local database choice, encryption strategy, AI service integration), create an ADR file under `docs/architecture/adr/YYYY-MM-DD-title.md` using this format:

```markdown
# ADR-[ID]: [Short Title]

- **Status:** Proposed | Accepted | Deprecated | Superseded
- **Date:** YYYY-MM-DD
- **Authors:** [Name/Team]

## Context & Problem Statement
Describe the problem being solved and the technical background.

## Decision Drivers
- [Driver 1]
- [Driver 2]

## Considered Options
1. [Option 1]
2. [Option 2]

## Decision Outcome
Chosen Option: **[Option Name]** because [rationale].

## Consequences
- **Positive:** [Benefits]
- **Negative/Risks:** [Drawbacks & Mitigation]
```

---

## 3. Feature & User Story Documentation Standard

Before implementing any non-trivial feature, write or update its specification document under `docs/features/<feature-name>.md`:

1. **Overview & Goal:** What user value does this feature deliver?
2. **Brand & UX Alignment:** Ensure UX copy aligns with `krezio-brand` guidelines (empowering, non-punitive, data-driven).
3. **Data Schema & Models:** Define data structures, DTOs, and state contracts.
4. **UI Wireframe/Flow:** Screen hierarchy, navigation steps, and state transitions (Loading, Success, Empty, Error).
5. **Acceptance Criteria:** Testable conditions required to mark the feature complete.

---

## 4. Automated & Change Documentation Workflow

Whenever implementing changes in the codebase, follow these continuous documentation steps:

### A. Code Comments & Self-Documentation
- Add docstrings to public classes, repositories, state providers, and complex logic blocks.
- Preserve existing comments during refactoring.

### B. Git Commit Messages (Conventional Commits)
Format git commit messages as:
- `feat(scope): brief description` — New features.
- `fix(scope): brief description` — Bug fixes.
- `docs(scope): brief description` — Documentation changes.
- `refactor(scope): brief description` — Code restructuring without feature changes.

### C. Changelog Updates
Update `CHANGELOG.md` under the appropriate version section (`[Unreleased]`, `[vX.Y.Z]`):
- **Added:** New user-facing features or infrastructure.
- **Changed:** Changes in existing functionality.
- **Fixed:** Bug resolutions.
- **Security:** Security hardening.

---

## 5. Agent Execution Protocol

When asked to document software processes or build new features for Krezio.ai:
1. **Check Existing Docs:** Inspect `docs/` and existing ADRs to maintain architectural coherence.
2. **Keep Specs Updated:** When modifying feature behavior, immediately update the corresponding `.md` spec in `docs/features/`.
3. **Update Changelog:** Summarize key changes in `CHANGELOG.md` upon completing major iterations.
4. **Verify Consistency:** Ensure technical docs respect `krezio-brand` design tokens and UX voice principles.
