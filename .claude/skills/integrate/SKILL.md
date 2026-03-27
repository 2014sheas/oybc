---
name: integrate
description: Move a tested Playground feature into the production app with Two-Gate safety
user-invocable: true
---

# Integration Skill

**Usage**: `/integrate [feature name from Playground]`

**Purpose**: Move a user-approved Playground feature into the production app. This is the highest-risk workflow — it modifies the real app that users interact with.

---

## Prerequisites

Before starting, the feature MUST have:

- Been implemented and tested in Playground via `/feature`
- Received explicit user approval in the Playground
- Both platforms compiling with the feature in Playground

If any prerequisite is missing, **STOP and tell the user**.

---

## Workflow: Three-Phase Process

### PHASE 1: Integration Plan

**Goal**: Map out exactly how Playground code becomes production code, and get user approval.

**Steps**:

1. **Audit Playground Feature**
   - Use **Serena** (`get_symbols_overview`, `find_symbol`) to catalog:
     - All components/files that make up the feature in Playground
     - Dependencies on playground utilities (`playgroundUtils.ts`, `PlaygroundUtils.swift`)
     - Any test/demo data that must be replaced with real data sources
   - Identify what needs to change for production:
     - Playground test data -> real database queries
     - Playground-specific UI (collapsible sections, demo controls) -> production UI
     - Playground utility imports -> production utility imports or inline

2. **Create Integration Plan**
   - For each Playground file, document:
     - **Move, adapt, or new**: Is the component moving as-is, being adapted, or does production need a different version?
     - **Target location**: Where in the production app does this go?
     - **Data source changes**: What switches from test data to real data?
     - **Dependencies**: What production infrastructure does this need (routes, navigation, database hooks)?
   - Document what happens to the Playground:
     - Remove the integrated feature section (it's now in the real app)
     - Keep other Playground features intact
   - Cross-platform parity: both platforms must be integrated simultaneously

3. **GATE 1: User Approves Integration Plan** (MANDATORY)
   - **STOP and present the plan**
   - Show:
     - What moves from Playground to production
     - Where it goes in the production app
     - What changes during the move (data sources, UI adjustments)
     - What gets removed from Playground
     - Risks and rollback approach
   - User can:
     - Approve -> Proceed to Phase 2
     - Adjust -> Revise plan
     - Cancel -> Feature stays in Playground

---

### PHASE 2: Execute Integration

**Goal**: Move the feature into production on both platforms.

**Steps**:

1. **Create Branch**
   - Branch: `feature/integrate-[feature-name]`
   - Integration always gets its own branch

2. **Integrate on Both Platforms**
   - Use `cross-platform-coordinator` to orchestrate if complex
   - Follow the plan exactly — no bonus features during integration
   - Web: Update routes in `App.tsx` if new pages are needed
   - iOS: Update navigation in `ContentView.swift` if new screens are needed
   - Replace test data with real database queries/hooks
   - Remove demo-specific UI (playground controls, test data generators)

3. **Clean Up Playground**
   - Remove the integrated feature's section from Playground container views
   - Remove Playground-specific files that are no longer needed
   - Keep Playground utilities that other features still use
   - Verify remaining Playground features still work

4. **Verify** (MANDATORY)
   - **Compile both platforms**
   - **Run ALL tests**
   - **Playwright** (MANDATORY for web):
     - Navigate to the new production location — verify feature works with real data
     - Navigate to Playground — verify remaining features still work
     - Screenshot both
   - **Run `superpowers:verification-before-completion`**

---

### PHASE 3: User Review

**Goal**: User verifies the feature works in the production app.

**Steps**:

1. **GATE 2: User Reviews Integration** (MANDATORY)
   - **Present to user**:
     - Feature working in production (Playwright screenshots)
     - How to test locally on both platforms
     - What was removed from Playground
     - Compilation and test results
   - User tests the feature in the production app (not Playground)
   - User can:
     - Approve -> Integration is COMPLETE
     - Request changes -> Return to Phase 2
     - Revert -> Discard branch, feature returns to Playground-only

---

## Scope Rules

- **Integrate only the approved feature. Nothing else.**
- Don't "improve" the feature during integration — that's a new `/feature` request.
- Don't refactor production code to accommodate the feature — if refactoring is needed, do `/refactor` first.
- Don't integrate multiple features at once unless the user explicitly requests it.
- If integration reveals the feature doesn't work with real data, stop and report — don't fix it inline.

## Rollback

If anything goes wrong:

- The branch can be discarded — dev is untouched
- The feature remains in Playground, working as before
- Document what went wrong for the next integration attempt
