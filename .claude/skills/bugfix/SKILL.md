---
name: bugfix
description: Diagnose and fix bugs with systematic debugging, plugin-driven verification, and user review
user-invocable: true
---

# Bug Fix Skill

**Usage**: `/bugfix [bug description or symptom]`

**Purpose**: Systematically diagnose and fix bugs with evidence-based verification. No Playground required — fixes go directly into the affected code.

---

## Workflow: Three-Phase Process

### PHASE 1: Diagnosis

**Goal**: Understand the bug before touching any code.

**Steps**:

1. **Reproduce & Understand**
   - Use `superpowers:systematic-debugging` skill for the investigation approach
   - Clarify symptoms with the user if the report is vague
   - Identify: What's happening? What should happen? When did it start?

2. **Investigate Root Cause**
   - Use **Serena** (`find_symbol`, `find_referencing_symbols`, `get_symbols_overview`) to trace the code path
   - If web UI bug: use **Playwright** to reproduce and screenshot the broken behavior
   - If complex/deep bug: use `ultrathink-debugger` agent
   - Identify the root cause, not just the symptom

3. **Present Diagnosis to User** (MANDATORY)
   - **STOP and explain what you found**
   - Show:
     - Root cause (with file references)
     - Proposed fix (what will change and why)
     - Risk assessment (what else could be affected)
     - Which platform(s) need changes
   - User can:
     - Approve fix approach -> Proceed to Phase 2
     - Suggest alternative -> Adjust approach
     - Provide more context -> Continue diagnosis

---

### PHASE 2: Fix & Verify

**Goal**: Apply the minimal fix and prove it works.

**Steps**:

1. **Apply Fix**
   - Fix the root cause, not the symptom
   - Minimal change — don't refactor surrounding code
   - If fix touches both platforms, ensure both are updated consistently
   - Use **Context7** for library API questions if needed

2. **Verify** (MANDATORY)
   - **Compile both platforms** (if fix touches shared code or both platforms)
   - **Run tests**: `pnpm test` for web/shared, Xcode tests for iOS
   - **Playwright** (MANDATORY if web UI was affected):
     - Reproduce the original bug scenario — confirm it's fixed
     - Screenshot the fixed behavior
     - Check for regressions in related UI areas
   - **Run `superpowers:verification-before-completion`**

---

### PHASE 3: Present Fix

**Goal**: Show the user evidence that the bug is fixed.

**Steps**:

1. **Present to User** (MANDATORY)
   - Show:
     - What was changed (file paths and brief diff summary)
     - Why this fixes the root cause
     - Verification evidence (test results, Playwright screenshots if applicable)
     - Compilation results
   - User can:
     - Approve -> Bug fix is COMPLETE
     - Request changes -> Return to Phase 2
     - Report still broken -> Return to Phase 1

---

## Scope Rules

- **Fix the bug. Nothing else.** No "while I'm here" cleanup.
- Don't refactor code adjacent to the fix.
- Don't add tests for unrelated code.
- Don't upgrade dependencies unless they caused the bug.
- If you discover other bugs during investigation, mention them but don't fix them.

## When to Branch

- **Simple fix** (1-3 files, low risk): Fix on current branch, user decides on commit.
- **Complex fix** (multiple files, cross-platform, risky): Create `bugfix/description` branch first.
- Ask the user if unsure.
