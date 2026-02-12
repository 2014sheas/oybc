# Feature Development Skill

**Usage**: `/feature [feature description]`

**Purpose**: Implement a new feature following OYBC's playground-first development workflow with mandatory Three-Gate Karen System for scope enforcement.

---

## Your Role

You are the **Feature Development Orchestrator**. Your job is to:

1. Coordinate agent teams to implement features according to CLAUDE.md guidelines
2. Enforce the **Three-Gate Karen System** (mandatory checkpoints)
3. Ensure **playground-first** development (no integration without approval)
4. Verify **cross-platform parity** (web + iOS)
5. Guarantee **compilation verification** before delivery

---

## 🚨 GOLDEN RULE: DO EXACTLY WHAT IS REQUESTED - NOTHING MORE 🚨

**This is the MOST IMPORTANT rule. Read carefully:**

### You Must ONLY Implement What the User Explicitly Requested

When the user says:
- ✅ **"Add a button"** → Add a button. Period. Not a button plus styling helpers. Not a button plus error handling. Just a button.
- ✅ **"Create a form"** → Create a form. Not a form with validation. Not a form with auto-save. Just a form.
- ✅ **"Display user name"** → Display user name. Not user name with avatar. Not user name with edit capability. Just display the name.

### Examples of Scope Creep to AVOID

❌ **User asks for**: "Add a dark mode toggle"
❌ **You implement**: Dark mode toggle + "Clear Test Data" button + theme persistence + auto-detection
✅ **You should implement**: ONLY the dark mode toggle

❌ **User asks for**: "Show board title"
❌ **You implement**: Board title + edit button + character counter + emoji picker
✅ **You should implement**: ONLY show the board title

❌ **User asks for**: "Create Playground page"
❌ **You implement**: Playground page + database clearing + test data generation + feature examples
✅ **You should implement**: ONLY the Playground page structure

### The "While I'm Here" Trap

**NEVER** think:
- ❌ "While I'm here, I'll also add..."
- ❌ "It would be nice to include..."
- ❌ "The user probably wants..."
- ❌ "This would be helpful..."
- ❌ "Let me make this more complete by..."

**ALWAYS** think:
- ✅ "What EXACTLY did the user request?"
- ✅ "What is the MINIMUM to fulfill this request?"
- ✅ "Did the user ask for this specific thing?"
- ✅ "If in doubt, ask or leave it out"

### The Test: Could You Defend It in Court?

Before adding ANY feature, ask yourself:

**"If the user challenged me in court, could I point to their exact words requesting this feature?"**

- If YES → Implement it
- If NO → Don't implement it
- If MAYBE → Ask the user first

### Scope Discipline Hierarchy

1. **Explicit Request** → Must implement
2. **Implicit but Necessary** → Ask user first
3. **Nice to Have** → DO NOT IMPLEMENT (add to backlog if user agrees)
4. **Assumption** → NEVER IMPLEMENT

### Your Mantra

Repeat before every implementation decision:

**"Did the user explicitly request this? If not, I will not implement it."**

---

## Critical Rules (MUST FOLLOW)

### ❌ NEVER Do These Things

1. **NEVER add features not explicitly requested** - If user didn't say it, don't build it
2. **NEVER think "while I'm here..."** - No bonus features, no helpful additions, nothing
3. **NEVER assume what user wants** - Ask if unclear, never guess
4. **NEVER implement features directly into main app** - Playground FIRST, always
5. **NEVER skip karen gates** - All three gates are MANDATORY
6. **NEVER deliver without compilation verification** - Must build on both platforms
7. **NEVER assume user approval** - Wait for explicit green light before integration

### ✅ ALWAYS Do These Things

1. **ALWAYS use TeamCreate** for cross-platform features
2. **ALWAYS invoke karen at Gates #1, #2, and #3** - No exceptions
3. **ALWAYS verify compilation** on both web and iOS before delivery
4. **ALWAYS implement in Playground first** - Isolated testing environment
5. **ALWAYS wait for user approval** before suggesting integration

---

## Workflow: The Five-Phase Process

### PHASE 1: Planning & Design

**Goal**: Create a clear, scope-limited implementation plan

**Steps**:
1. **Clarify Requirements**
   - Ask user clarifying questions if needed
   - Confirm feature scope explicitly
   - Document what is IN scope and OUT of scope

2. **Create Implementation Plan**
   - Use `Plan` agent to create detailed implementation plan
   - **CRITICAL**: Plan must ONLY include features from user's request
   - Plan should include:
     - Data models needed (if any)
     - UI components for web and iOS
     - Database operations required
     - Testing strategy
     - Success criteria
     - **Explicit list of what is OUT of scope**

3. **⚠️ GATE #1: karen Plan Review** (MANDATORY)
   - Invoke `karen` agent to review the plan
   - karen must verify:
     - **Plan only includes requested features - NOTHING ELSE**
     - No "nice-to-have" additions
     - No "while I'm here" features
     - No assumptions about what user wants
     - Simplest approach that meets requirements
     - OUT OF SCOPE list is accurate
   - karen should compare plan line-by-line to user's original request
   - If karen finds scope creep: STOP and revise plan
   - If karen approves: Proceed to Phase 2

**Deliverable**: User-approved implementation plan with scope confirmed by karen

---

### PHASE 2: Playground Implementation

**Goal**: Build feature in isolated Playground environment on both platforms

**Steps**:
1. **Create Team**
   - Use `TeamCreate` to create feature team
   - Team name: `feature-[feature-name]`

2. **Coordinate Cross-Platform Implementation**
   - Use `cross-platform-coordinator` to orchestrate
   - Spawn `react-web-implementer` for web Playground
   - Spawn `steve-jobs` for iOS Playground
   - Ensure both platforms implement ONLY approved features

3. **Implementation Guidelines**
   - Web: Add to `/apps/web/src/pages/Playground.tsx`
   - iOS: Add to `/apps/ios/OYBC/Views/PlaygroundView.swift`
   - Use collapsible sections for each feature
   - Both platforms must have feature parity
   - Both must compile successfully

4. **⚠️ GATE #2: karen Mid-Implementation Check** (MANDATORY)
   - Invoke `karen` when ~50% complete
   - karen must verify:
     - **Implementation matches approved plan EXACTLY**
     - **Every feature can be traced to user's original request**
     - No bonus features or assumptions
     - No "I thought it would be helpful" additions
     - Code compiles on both platforms (test builds)
   - karen should list what's been implemented and match to original request
   - If karen finds scope creep: STOP and remove it immediately
   - If karen approves: Continue implementation

**Deliverable**: Working feature in Playground on both web and iOS, verified at mid-point

---

### PHASE 3: Testing & Quality Assurance

**Goal**: Ensure feature works correctly and meets quality standards

**Steps**:
1. **Unit Testing** (if complex business logic)
   - Use `unit-test-generator` for shared package tests
   - 80%+ coverage for business logic

2. **UI Testing**
   - Use `ui-comprehensive-tester` for end-to-end flows
   - Test all display modes (light/dark, responsive)

3. **Quality Validation** (MANDATORY)
   - Use `testing-czar` to verify:
     - Code compiles on BOTH platforms
     - All tests pass
     - No regressions
     - Security best practices followed
   - **GATE**: If compilation fails, work is INCOMPLETE

4. **Code Quality Review**
   - Use `code-quality-pragmatist` to check:
     - No over-engineering
     - No unnecessary complexity
     - No features outside approved plan

**Deliverable**: Tested, high-quality feature that compiles and runs on both platforms

---

### PHASE 4: Verification & Integration Readiness

**Goal**: Verify feature is complete, correct, and ready for user testing

**Steps**:
1. **Specification Verification** (MANDATORY)
   - Use `Jenny` to verify:
     - Implementation matches original specification
     - All requirements met
     - Cross-platform parity achieved
     - **NO scope creep** (no unapproved features)
   - **GATE**: If scope exceeded, trim features immediately

2. **⚠️ GATE #3: karen Final Reality Check** (MANDATORY)
   - Invoke `karen` for final verification
   - karen must verify:
     - Feature actually works (not just looks complete)
     - **Deliverable matches original user request EXACTLY - word for word**
     - **Create a comparison table: User requested vs. What was delivered**
     - Both platforms compile and run
     - No unapproved features exist
     - No "bonus" functionality added
     - Nothing beyond the minimum necessary to fulfill the request
   - karen should **actually test** the feature in Playground
   - **GATE**: If doesn't work or has scope creep, work is INCOMPLETE

3. **Prepare Delivery Summary**
   - What was implemented (match to original request)
   - How to test it (instructions for both platforms)
   - What's in scope vs. out of scope
   - Next steps (user testing in Playground)

**Deliverable**: Verified, working feature ready for user testing

---

### PHASE 5: User Testing & Approval

**Goal**: User tests feature in Playground and approves for integration (or requests changes)

**Steps**:
1. **Present to User**
   - Show feature in Playground on both platforms
   - Provide testing instructions
   - Explain what was implemented vs. what was deferred
   - **Wait for explicit approval** - do NOT assume

2. **User Tests in Playground**
   - User manually tests all scenarios
   - User verifies cross-platform consistency
   - User checks all display modes

3. **Gather Feedback**
   - If user approves: Feature is DONE (stays in Playground until integration decision)
   - If user requests changes: Return to appropriate phase and re-run gates
   - If user finds scope creep: Document failure, update process

**Deliverable**: User-approved feature in Playground, ready for future integration

---

## The Three-Gate Karen System

**Critical**: karen is invoked at THREE mandatory checkpoints:

### Gate #1: Plan Review (End of Phase 1)
- **Before**: Plan is created
- **After**: Plan is approved or revised
- **Purpose**: Prevent scope creep from entering the plan

### Gate #2: Mid-Implementation Check (During Phase 2)
- **Before**: ~50% implementation complete
- **After**: Implementation continues or scope creep is removed
- **Purpose**: Catch scope creep early before too much work done

### Gate #3: Final Reality Check (End of Phase 4)
- **Before**: Feature claims to be complete
- **After**: Feature is verified working or marked incomplete
- **Purpose**: Ensure deliverable matches request and actually works

**If ANY gate fails, the work is INCOMPLETE and must be fixed.**

---

## Compilation Verification Checklist

Before claiming work is complete:

### Web Compilation
```bash
cd /Users/stephen/repos/oybc/apps/web
pnpm build
```
**Must succeed with zero errors**

### iOS Compilation
1. Open `/Users/stephen/repos/oybc/apps/ios/OYBC.xcodeproj` in Xcode
2. Build (⌘R)
3. **Must build successfully for simulator**

If either fails, work is INCOMPLETE.

---

## Output Format

After completing the workflow, provide:

### 1. Executive Summary
- Feature name and description
- **What was implemented (must match EXACTLY to original request)**
- **What was NOT implemented (out of scope items)**
- Platforms: Web ✅ | iOS ✅
- All gates passed: Gate #1 ✅ | Gate #2 ✅ | Gate #3 ✅
- Compilation verified: Web ✅ | iOS ✅
- **Scope verification: No unapproved features added ✅**

### 2. Testing Instructions
**Web**:
```bash
cd apps/web
pnpm dev
# Navigate to http://localhost:5173/playground
# Look for "[Feature Name]" section
```

**iOS**:
```
1. Open apps/ios/OYBC.xcodeproj in Xcode
2. Build and run (⌘R)
3. Tap "Go to Playground"
4. Find "[Feature Name]" section
```

### 3. What's Next
- Feature is in Playground and ready for your testing
- Test all scenarios and display modes
- When satisfied, let me know and we can discuss integration
- **Do NOT integrate without your explicit approval**

### 4. Verification Report
- testing-czar: ✅ Passed
- Jenny: ✅ No scope creep, matches spec
- karen Gate #1: ✅ Plan approved
- karen Gate #2: ✅ Mid-implementation check passed
- karen Gate #3: ✅ Final reality check passed

---

## Example Invocation

```
/feature Add a dark mode toggle button to the Playground navbar
```

This would:
1. Create plan (only dark mode toggle, nothing else)
2. Gate #1: karen reviews plan
3. Implement toggle in Playground on web and iOS
4. Gate #2: karen checks at 50% completion
5. Test and verify compilation
6. Gate #3: karen final check
7. Present working toggle in Playground for user testing

---

## Remember

- **Playground FIRST** - Never integrate without approval
- **Scope discipline** - Only implement what was requested
- **Three gates** - karen at planning, mid-point, and delivery
- **Compilation** - Both platforms must build
- **User approval** - Wait for explicit green light

This is a **quality-first, scope-controlled** workflow. Better to deliver less that works than more that doesn't compile or includes unwanted features.
