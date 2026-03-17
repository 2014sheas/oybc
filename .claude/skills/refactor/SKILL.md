---
name: refactor
description: Refactor code with safety verification — restructure without changing behavior
user-invocable: true
---

# Refactor Skill

**Usage**: `/refactor [what to refactor and why]`

**Purpose**: Restructure code for clarity, maintainability, or performance without changing external behavior. No Playground required — changes go directly into the affected code.

---

## Workflow: Three-Phase Process

### PHASE 1: Plan

**Goal**: Understand scope, assess risk, and get user approval before changing anything.

**Steps**:

1. **Analyze Current State**
   - Use **Serena** (`get_symbols_overview`, `find_symbol`, `find_referencing_symbols`) to understand:
     - What's being refactored and its current structure
     - All references and dependents (blast radius)
     - Cross-platform implications (does iOS need matching changes?)
   - Run existing tests to establish a passing baseline

2. **Create Refactoring Plan**
   - Document:
     - What changes (files, symbols, structure)
     - Why (the specific improvement)
     - What does NOT change (external behavior, APIs, data formats)
     - Blast radius (all files/symbols affected)
     - Platform impact (web only, iOS only, or both)
   - **Scope discipline**: Only refactor what was requested. Don't cascade into "might as well also clean up..."

3. **User Approval** (MANDATORY)
   - **STOP and present the plan**
   - User can:
     - Approve -> Proceed to Phase 2
     - Adjust scope -> Revise plan
     - Cancel -> Stop work

---

### PHASE 2: Execute & Verify

**Goal**: Apply the refactoring and prove nothing broke.

**Steps**:

1. **Create Branch**
   - Branch: `refactor/description`
   - Refactoring always gets its own branch — never done on master

2. **Apply Changes**
   - Use **Serena** (`replace_symbol_body`, `rename_symbol`, `insert_after_symbol`) for structural changes
   - If renaming: use `find_referencing_symbols` to find and update ALL references
   - If cross-platform: ensure both platforms are updated consistently
   - Work incrementally — compile after each logical step

3. **Verify** (MANDATORY)
   - **Compile both platforms** (if both are affected)
   - **Run ALL tests**: `pnpm test` for web/shared, Xcode tests for iOS
   - **Playwright** (if web UI components were restructured):
     - Navigate affected pages/features
     - Screenshot to confirm UI is visually unchanged
   - **Run `superpowers:verification-before-completion`**
   - **Confirm behavior is identical** — refactoring must not change what the user sees or how the app works

---

### PHASE 3: Present Changes

**Goal**: Show the user what changed and prove nothing broke.

**Steps**:

1. **Present to User** (MANDATORY)
   - Show:
     - What was restructured (before/after summary)
     - All files changed
     - Test results (all passing)
     - Compilation results
     - Playwright screenshots (if UI components touched)
     - Confirmation: external behavior unchanged
   - User can:
     - Approve -> Refactoring is COMPLETE
     - Request adjustments -> Return to Phase 2
     - Revert -> Discard branch

---

## Scope Rules

- **Refactor what was requested. Nothing else.**
- Don't fix bugs you find during refactoring — report them separately.
- Don't add features or change behavior.
- Don't change APIs, data formats, or database schemas (those are features, not refactoring).
- If the refactoring reveals a deeper structural problem, present it to the user as a finding — don't unilaterally expand scope.

## What Counts as Refactoring

- Renaming for clarity
- Extracting shared utilities (the "extract at three" rule)
- Simplifying complex functions
- Restructuring file organization
- Removing dead code
- Improving type safety

## What Does NOT Count (use `/feature` or `/bugfix` instead)

- Adding new functionality
- Changing external behavior
- Fixing bugs
- Upgrading dependencies
- Database schema changes
