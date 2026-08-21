---
name: code-review-graph
description: >-
  Persistent incremental knowledge graph tool for code reviews, impact analysis (blast radius), dead code detection, architectural query, and AST dependency mapping.
  Use whenever analyzing code structure, assessing change impact, reviewing pull requests, running blast radius analysis, or searching project code relationships.
---

# Code Review Graph Skill for Krezio.ai

This skill integrates **`code-review-graph`** into the Krezio.ai repository. `code-review-graph` maintains a persistent, SQLite-backed Abstract Syntax Tree (AST) dependency graph (parsed via Tree-sitter) that tracks calls, imports, inheritance, and test coverage across the project.

---

## 1. Core Capabilities

- **Token-Efficient Context:** Provides a precise graph-slice of affected dependencies instead of scanning unnecessary files.
- **Blast Radius Analysis:** Identifies all upstream callers, downstream dependents, and related test files affected by a code modification.
- **Dead Code Detection:** Pinpoints unreferenced functions, classes, and orphaned logic.
- **Interactive Visualization:** Renders interactive HTML views of system components and execution flows.

---

## 2. Commands Cheatsheet

Always execute commands using `python -m code_review_graph <subcommand>` in the terminal:

### Building & Updating the Graph
```bash
# Re-parse all files and rebuild the graph
python -m code_review_graph build

# Incremental update for modified files only
python -m code_review_graph update

# Watch directory for live updates during development
python -m code_review_graph watch
```

### Code Review & Impact Analysis
```bash
# Calculate blast radius for modified files
python -m code_review_graph impact --files lib/main.dart

# Detect unreferenced functions or unused classes
python -m code_review_graph dead-code

# Query specific code relationships
python -m code_review_graph query

# Find functions with high complexity or line counts
python -m code_review_graph large-functions
```

### Architecture & Visualization
```bash
# Overview of system clusters and code structure
python -m code_review_graph architecture

# Generate interactive HTML graph in browser
python -m code_review_graph visualize
```

---

## 3. Agent Integration Guidelines

When conducting code reviews or major refactoring tasks:
1. Run `python -m code_review_graph update` to ensure graph data is up to date.
2. Run `python -m code_review_graph impact` to check potential regression risks before completing refactors.
3. Check `dead-code` outputs when cleaning up deprecated features or code paths.
