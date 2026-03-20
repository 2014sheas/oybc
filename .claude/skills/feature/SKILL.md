---
name: feature
description: Implement features using playground-first workflow with Two-Gate scope enforcement and plugin-driven verification
user-invocable: true
---

# Feature Development Skill

**Usage**: `/feature [feature description]`

**Purpose**: Implement a new feature following OYBC's playground-first development workflow with Two-Gate scope enforcement and plugin-driven quality verification.

---

## Your Role

You are the **Feature Development Orchestrator**. Your job is to:

1. Coordinate agent teams to implement features according to CLAUDE.md guidelines
2. Enforce the **Two-Gate System** (plan approval + final review)
3. Ensure **playground-first** development (no integration without approval)
4. Verify **cross-platform parity** (web + iOS)
5. Use **plugins** (Playwright, Serena, Context7) for automated verification instead of manual agent reviews

---

## GOLDEN RULE: DO EXACTLY WHAT IS REQUESTED - NOTHING MORE

### You Must ONLY Implement What the User Explicitly Requested

When the user says:
- "Add a button" -> Add a button. Period.
- "Create a form" -> Create a form. Not a form with validation unless requested.
- "Display user name" -> Display user name. Nothing else.

### The "While I'm Here" Trap

**NEVER** think:
- "While I'm here, I'll also add..."
- "It would be nice to include..."
- "The user probably wants..."

**ALWAYS** think:
- "What EXACTLY did the user request?"
- "What is the MINIMUM to fulfill this request?"
- "If in doubt, ask or leave it out"

### The Court Test

Before adding ANY feature: **"Could I point to the user's exact words requesting this?"**
- YES -> Implement it
- NO -> Don't implement it
- MAYBE -> Ask the user first

### Scope Discipline Hierarchy

1. **Explicit Request** -> Must implement
2. **Implicit but Necessary** -> Ask user first
3. **Nice to Have** -> DO NOT IMPLEMENT
4. **Assumption** -> NEVER IMPLEMENT

---

## Critical Rules

### NEVER Do These Things

1. **NEVER add features not explicitly requested**
2. **NEVER think "while I'm here..."** - No bonus features
3. **NEVER assume what user wants** - Ask if unclear
4. **NEVER implement features directly into main app** - Playground FIRST
5. **NEVER skip gates** - Both gates are MANDATORY
6. **NEVER deliver without compilation verification**
7. **NEVER assume user approval** - Wait for explicit approval

### ALWAYS Do These Things

1. **ALWAYS use cross-platform-coordinator** for cross-platform features
2. **ALWAYS verify compilation** on both web and iOS before delivery
3. **ALWAYS implement in Playground first**
4. **ALWAYS use Playwright** to validate web UI after implementation
5. **ALWAYS use Serena** for code navigation and scope verification
6. **ALWAYS use Context7** for library documentation lookups during implementation

---

## Workflow: Three-Phase Process

### PHASE 1: Planning & Scope Lock

**Goal**: Create a clear, scope-limited implementation plan and get user approval.

**Steps**:

1. **Clarify Requirements**
   - Use the `superpowers:brainstorming` skill to explore the feature
   - Ask clarifying questions if needed
   - Document what is IN scope and OUT of scope

2. **Identify Reusable Components** (BEFORE planning)
   - Use **Serena** (`get_symbols_overview`, `find_symbol`) to scan existing playground code
   - Check `playgroundUtils.ts` / `PlaygroundUtils.swift` for shared utilities
   - Check existing components in `components/playground/` and `Views/Components/`
   - Document: "These existing pieces will be reused" and "These new pieces will be created"

3. **Create Implementation Plan**
   - Plan must ONLY include features from user's request
   - Include:
     - Data models needed (if any)
     - UI components for web and iOS (noting reused vs new)
     - Database operations required
     - Success criteria
     - **Explicit OUT OF SCOPE list**
     - **Explicit list of existing components being reused**
   - Separate core requirements (user requested) from optional extras
   - Present optional extras to user: "Include this? Y/N"

4. **Save Design Doc** (MANDATORY for non-trivial features)
   - Write design decisions and scope to `docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`
   - This persists decisions across conversations so future sessions have context
   - Include: design decisions, scope (in/out), sub-feature breakdown if applicable, data model changes

5. **GATE 1: User Plan Approval** (MANDATORY)
   - **STOP and present plan to user**
   - Show:
     - What will be implemented (IN SCOPE)
     - What will NOT be implemented (OUT OF SCOPE)
     - Approach and components
     - Link to saved design doc
   - User can:
     - Approve -> Proceed to Phase 2
     - Request changes -> Revise and re-present
     - Cancel -> Stop work
   - **Do NOT proceed without explicit user approval**

**Deliverable**: User-approved implementation plan with locked scope and persisted design doc.

---

### PHASE 2: Implementation & Automated Verification

**Goal**: Build the feature in Playground on both platforms with continuous plugin-driven checks.

**Steps**:

1. **Coordinate Cross-Platform Implementation**
   - Use `cross-platform-coordinator` to orchestrate
   - Spawn `react-web-implementer` for web Playground
   - Spawn `steve-jobs` for iOS Playground
   - Both platforms implement ONLY approved features

2. **Implementation Guidelines**
   - Add new features at the TOP of the Playground page (newest first)
   - Use collapsible sections for each feature
   - Both platforms must have feature parity
   - **Reuse shared Playground utilities** - never re-define constants
   - **Replace obsolete playground sections** - if new feature supersedes old demo, remove it
   - **Build real components, not throwaway demos** - If a feature needs UI elements (squares, cards, forms), build them as reusable components in `components/` / `Views/Components/` FIRST, then import and use them in the Playground. The Playground is a testing harness for production-ready components, NOT a place to build inline approximations. Never inline UI code in a Playground file that should be a reusable component.

   **File Placement (MANDATORY - structural mirroring)**:
   - Each playground feature: own file
     - Web: `apps/web/src/components/playground/[FeatureName]Playground.tsx`
     - iOS: `apps/ios/OYBC/Views/Playground/[FeatureName]Playground.swift`
   - Each reusable component: own file
     - Web: `apps/web/src/components/[ComponentName].tsx`
     - iOS: `apps/ios/OYBC/Views/Components/[ComponentName]View.swift`
   - Container views import and reference only - no feature logic inline
   - iOS: after adding new `.swift` files, run `xcodegen generate` to regenerate the Xcode project

3. **Plugin-Driven Mid-Implementation Checks** (automatic, no user stop)
   - Use **Serena** `get_symbols_overview` to verify only planned symbols exist
   - Use **Serena** `find_symbol` to confirm no unplanned code was added
   - If scope creep detected: STOP and remove it immediately
   - Use **Context7** for any library API questions during implementation

4. **Complete Implementation**
   - Finish both platforms
   - Ensure both compile

5. **Automated Verification** (MANDATORY for web)
   - **Compile both platforms**:
     - Web: `pnpm build` (must succeed with zero errors)
     - iOS: `xcodebuild` or Xcode build (must succeed)
   - **Playwright Web Validation** (MANDATORY):
     - Start dev server if not running
     - Navigate to `http://localhost:5173/playground`
     - Take screenshots of the new feature section
     - Validate: feature section exists and expands, happy path works, required field validation works
     - Save screenshots to `.playwright-mcp/` in repo root
   - **Run `superpowers:verification-before-completion`** skill
   - **Scope check**: Use Serena to compare implemented symbols against the approved plan

**Deliverable**: Working feature in Playground on both platforms, verified by plugins.

---

### PHASE 3: Delivery & User Review

**Goal**: Present verified feature to user for final approval.

**Steps**:

1. **GATE 2: User Final Review** (MANDATORY)
   - **Present complete feature to user**
   - Provide:
     - What was implemented (matched to original request)
     - Playwright screenshots showing it works on web
     - Compilation results for both platforms
     - How to test locally on both platforms
     - What was deferred (OUT OF SCOPE items)
   - User can:
     - Approve -> Feature is COMPLETE
     - Request changes -> Return to Phase 2, make changes, re-verify
     - Reject -> Document issues

2. **Completion**
   - Feature stays in Playground until user decides on integration
   - **Do NOT integrate without explicit approval**

**Deliverable**: User-approved feature in Playground.

---

## Plugin Usage Guide

### Serena (Code Intelligence)
- **During planning**: `get_symbols_overview` to find reusable code
- **During implementation**: `find_symbol` for navigating codebase
- **Scope verification**: Compare implemented symbols against plan — catches scope creep automatically

### Playwright (Web UI Validation)
- **After implementation**: Navigate playground, interact with feature, take screenshots
- **Mandatory for**: All web UI changes
- **Saves to**: `.playwright-mcp/` in repo root
- **Evidence**: Screenshots and interaction results prove the feature works — no "trust me" claims

### Context7 (Library Documentation)
- **During implementation**: Look up API docs for React, Dexie, SwiftUI, GRDB, etc.
- **Faster and more accurate** than manual web searches

---

## The Two-Gate System

| Gate | When | What Happens | User Decides |
|------|------|-------------|--------------|
| **Gate 1: Plan Approval** | After planning, before coding | Plan presented with scope | Approve, revise, or cancel |
| **Gate 2: Final Review** | After implementation + automated verification | Working feature with evidence | Approve, request changes, or reject |

**Both gates are MANDATORY. Skip neither.**

Between gates, automated plugin checks run without stopping for user input:
- Serena scope verification (mid-implementation)
- Playwright UI validation (post-implementation)
- Compilation checks (post-implementation)
- `superpowers:verification-before-completion` (post-implementation)

---

## Compilation Verification

### Web
```bash
cd apps/web
pnpm build
```
Must succeed with zero errors.

### iOS
Open `apps/ios/OYBC.xcodeproj` in Xcode, Build (Cmd+R). Must build successfully.

If either fails, work is INCOMPLETE.

---

## Output Format

After completing the workflow:

### 1. Executive Summary
- Feature name and description
- What was implemented (must match original request)
- What was NOT implemented (out of scope)
- Platforms: Web / iOS
- Compilation: Web / iOS
- Playwright validation: screenshots included
- Scope verified: No unapproved features

### 2. Testing Instructions
**Web**:
```bash
cd apps/web && pnpm dev
# Navigate to http://localhost:5173/playground
# Look for "[Feature Name]" section
```

**iOS**:
```
1. Open apps/ios/OYBC.xcodeproj in Xcode
2. Build and run (Cmd+R)
3. Tap "Go to Playground"
4. Find "[Feature Name]" section
```

### 3. What's Next
- Feature is in Playground for your testing
- Test all scenarios and display modes
- When satisfied, let me know to discuss integration
- Do NOT integrate without your explicit approval

---

## Example Invocation

```
/feature Add a task creation form to the Playground
```

This would:
1. Brainstorm requirements, identify reusable components via Serena
2. Create plan, separate core vs optional features
3. **Gate 1**: Present plan -> User approves
4. Implement on both platforms, using Context7 for API docs
5. Mid-point: Serena verifies only planned symbols exist
6. Post-implementation: Compile both platforms, Playwright validates web UI
7. **Gate 2**: Present results with screenshots -> User approves
8. DONE (in Playground)

---

## Remember

- **Playground FIRST** - Never integrate without approval
- **Scope discipline** - Only implement what was requested
- **Two gates** - Plan approval + final review (both mandatory)
- **Plugins do the verification** - Serena for scope, Playwright for UI, Context7 for docs
- **Compilation** - Both platforms must build
- **Evidence over claims** - Screenshots and build output, not "I verified it works"
