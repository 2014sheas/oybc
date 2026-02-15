# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OYBC (On Your Bingo Card) — An offline-first, gamified task management app that turns goals into interactive bingo boards. Multi-platform (iOS native + web) with seamless offline functionality and background sync.

**Core Architecture**: Local-first design where local databases (GRDB on iOS, Dexie on web) are the source of truth, with Firestore providing background sync for multi-device support only.

## Code Quality Standards

- Type hints and docstrings are required for all functions and classes.
- Public APIs must have docstrings explaining parameters, return values, and exceptions.
- Functions must be focused and small.
- Follow established design patterns for offline-first apps on intial setup, follow existing patterns within the app exactly.
- Use consistent naming conventions and code style throughout the codebase.
- Class names should be in PascalCase, function and variable names in camelCase.
- Avoid code duplication; extract common logic into reusable functions or classes.
- Ensure proper error handling and logging for all operations, especially database and network interactions.
- Ensure security best practices are followed, especially when handling user data and authentication.
- Reference app store guidelines for iOS standards and ensure compliance.
- Update documentation as code changes are made to keep it current.
- Conduct regular code reviews to maintain quality and share knowledge among team members.
- Before importing any third-party libraries, evaluate options carefully to ensure they are necessary, well-maintained, and do not bloat the app size.

## Testing Standards

- All new features and bug fixes must include unit tests covering core logic.
- Aim for at least 80% code coverage in all packages.
- Use Jest for TypeScript tests and XCTest for Swift tests.
- Tests should be deterministic and not rely on external services or network calls.

## Feature Implementation Guidelines

**CRITICAL: Playground-First Development Process**

1. **ONE Feature at a Time**: Only implement the single feature that the user explicitly decides to work on. Do not proactively suggest or implement multiple features.

2. **User-Driven Selection**: The user determines which feature to implement. Do not assume or choose features independently.

3. **Playground Before Integration**: ALL features must first be added to a "Playground" page on both platforms (web and iOS) before any integration into the main application codebase.

4. **No Integration Without Approval**: Features must NOT be introduced into the tactical/production code until the user explicitly gives the green light after testing.

5. **Comprehensive Testing in Playground**: The Playground must demonstrate and allow testing of ALL use cases for the feature:
   - All user interactions
   - All edge cases
   - All error states
   - All data scenarios

6. **Display Mode Coverage**: If the feature has any UI component, the Playground implementation must consider and demonstrate:
   - **iOS**: Light mode, Dark mode, different device sizes
   - **Web**: Light mode, Dark mode, responsive layouts, different browsers
   - Cross-platform consistency

7. **Playground Persistence**: The Playground page persists across all feature development. New features are added to the existing Playground, not replacing previous features.

**Standard Development Process**:

- Ask as many clarifying questions as needed before starting implementation.
- Create a new branch for each feature or bug fix.
- Write tests before implementing the feature (TDD approach).
- Create a detailed plan before implementing new features, including data flow diagrams and state management strategies.

## Agent Team Development Guidelines

**When to Use Agent Teams**: For complex features that benefit from specialized expertise and parallel work. Simple features can be handled by a single agent.

### CRITICAL: Agent Accountability & Verification

**Every agent-driven implementation MUST follow this verification checklist:**

1. **Scope Adherence** - Agent must ONLY implement what was explicitly requested
   - ❌ No "nice-to-have" features
   - ❌ No "while I'm here" additions
   - ❌ No assumptions about what the user "probably wants"
   - ✅ ONLY what was specified in the prompt

2. **Compilation Verification** - Code must compile before delivery
   - iOS: Must build successfully in Xcode
   - Web: Must run `pnpm build` without errors
   - If it doesn't compile, IT'S NOT DONE

3. **Cross-Platform Consistency** - When working on both platforms
   - Both implementations must have feature parity
   - Both must compile/run successfully
   - No platform should get features the other doesn't have (unless explicitly scoped that way)

4. **Dependency Verification** - Before referencing any code
   - Verify the file exists
   - Verify it's properly imported/included in the project
   - For iOS: Verify it's in the Xcode project.pbxproj
   - For web: Verify it's in package.json or properly imported

5. **Mandatory Quality Gates Before Delivery**:
   - `testing-czar`: Run compilation and basic tests
   - `Jenny`: Verify implementation matches specification exactly
   - `karen`: Reality check - does it actually work or just look done?

**If ANY of these fail, the work is INCOMPLETE and must be fixed before delivery.**

## Agent Team Development Guidelines (Original)

**When to Use Agent Teams**: For complex features that benefit from specialized expertise and parallel work. Simple features can be handled by a single agent.

### Feature Development Workflow with Agents

**Phase 1: Planning & Design**

1. **system-design-engineer**: Creates technical specifications for the feature
   - Define data models and schema changes
   - Specify API contracts
   - Document cross-platform considerations
   - Create architecture diagrams

2. **design-research-analyst**: Research implementation approaches (if needed)
   - Evaluate library options
   - Research best practices for offline-first patterns
   - Investigate cross-platform solutions
   - Compare architectural approaches

3. **Plan agent**: Creates detailed implementation plan
   - Break down work into tasks
   - Identify dependencies
   - Estimate complexity
   - Define success criteria

4. **karen** ⚠️ GATE #1: Plan Review (MANDATORY)
   - **Review the plan BEFORE implementation starts**
   - Verify plan only includes explicitly requested features
   - Cut any "nice-to-have" or "while we're here" additions
   - Ensure plan is realistic and matches user requirements exactly
   - **GATE**: If scope creep detected, plan must be revised
   - **OUTPUT**: Approved plan with scope confirmed

**Phase 2: Playground Implementation**

5. **cross-platform-coordinator**: Orchestrates cross-platform implementation
   - Ensure UI/UX consistency between web and iOS
   - Coordinate feature parity
   - Manage shared type definitions
   - **CRITICAL**: Prevent scope creep - only implement what was requested
   - **CRITICAL**: Verify BOTH platforms compile before delivery
   - **CRITICAL**: Must invoke karen at mid-point and completion

6. **react-web-implementer**: Builds web Playground feature
   - Implement React components in Playground
   - Use Dexie for local database operations
   - Follow iOS design patterns for consistency
   - Test all display modes (light/dark, responsive)
   - **MUST ONLY** implement features from approved plan

7. **steve-jobs** (ios-developer): Builds iOS Playground feature
   - Implement SwiftUI views in Playground
   - Use GRDB for local database operations
   - Ensure cross-platform design consistency
   - Test all display modes and device sizes
   - **MUST ONLY** implement features from approved plan

8. **karen** ⚠️ GATE #2: Mid-Implementation Check (MANDATORY)
   - **Check in when ~50% complete**
   - Review what's been implemented so far
   - Verify implementation matches approved plan
   - Catch scope creep early before too much work is done
   - Check for "bonus features" or assumptions
   - **GATE**: If scope creep detected, stop and remove it immediately
   - **OUTPUT**: Confirmation to continue or corrections needed

9. **sync-specialist**: Implements sync logic (if feature requires sync)
   - Design sync queue operations
   - Implement conflict resolution
   - Handle offline scenarios
   - Ensure local-first principles
   - **MUST ONLY** implement sync for features in approved plan

**Phase 3: Testing & Quality Assurance**

10. **unit-test-generator**: Creates comprehensive unit tests
    - Test business logic in `packages/shared`
    - Test database operations
    - Test edge cases and error handling
    - Aim for 80%+ coverage
    - **ONLY** test features from approved plan

11. **ui-comprehensive-tester**: Performs end-to-end UI testing
    - Test user flows in Playground
    - Verify cross-platform consistency
    - Test offline scenarios
    - Validate accessibility

12. **testing-czar**: Comprehensive quality validation (REQUIRED)
    - **MUST verify code compiles on all platforms**
    - Run all tests across platforms
    - Check code coverage
    - Verify no regressions
    - Ensure security best practices
    - **GATE**: If compilation fails, work is INCOMPLETE

13. **code-quality-pragmatist**: Review for over-engineering
    - Check for unnecessary complexity
    - Ensure YAGNI (You Aren't Gonna Need It)
    - Verify simplicity and maintainability
    - Flag premature abstractions
    - Flag features that weren't in the approved plan

**Phase 4: Verification & Integration** (MANDATORY - NOT OPTIONAL)

14. **Jenny**: Verify implementation matches specifications (REQUIRED)
    - Compare implementation to original spec
    - Identify gaps or deviations
    - **Check for scope creep** (features not requested)
    - Ensure all requirements met
    - Validate cross-platform parity
    - **GATE**: If scope was exceeded, work must be trimmed

15. **karen** ⚠️ GATE #3: Final Reality Check (REQUIRED)
    - **This is the THIRD karen checkpoint** (after Plan Review and Mid-Implementation)
    - Cut through incomplete implementations
    - **Actually test the feature** (not just read code)
    - Verify ONLY approved features were implemented
    - Compare deliverable to original user request
    - Identify what actually works vs. claimed
    - Ensure no BS, production-ready code
    - **GATE**: If it doesn't actually work OR has scope creep, work is INCOMPLETE
    - **OUTPUT**: Final approval or list of issues to fix

**Phase 5: Debugging (as needed)**

16. **ultrathink-debugger**: Deep debugging for complex issues
    - Root cause analysis for bugs
    - Trace execution paths
    - Diagnose environment-specific failures
    - Implement robust fixes

---

### The Three-Gate Karen System (Scope Creep Prevention)

**Problem**: Scope creep happens incrementally throughout development. Catching it only at the end is too late and wastes effort.

**Solution**: `karen` acts as a scope enforcer at THREE mandatory checkpoints:

#### Gate #1: Plan Review (After Phase 1)
**When**: Immediately after `Plan` agent creates implementation plan, BEFORE any coding starts
**Purpose**: Prevent scope creep from entering the plan itself
**Karen's Questions**:
- Does this plan include anything the user didn't explicitly request?
- Are there "nice-to-have" features that crept in?
- Is this the simplest approach that meets the actual requirements?
**Action**: Remove any features not in the original request

#### Gate #2: Mid-Implementation Check (During Phase 2)
**When**: When implementation is ~50% complete
**Purpose**: Catch scope creep early before too much work is wasted
**Karen's Questions**:
- What features have been implemented so far?
- Does each feature map directly to the approved plan?
- Are there any "bonus" features or assumptions?
**Action**: Stop immediately and remove scope creep before more work is done

#### Gate #3: Final Reality Check (End of Phase 4)
**When**: After all implementation and testing, before delivery
**Purpose**: Final verification that deliverable matches original request exactly
**Karen's Questions**:
- Does the deliverable match the original user request?
- Does it actually work, or just look complete?
- Are there features that weren't requested?
**Action**: Reject delivery if scope creep exists or if it doesn't actually work

**Key Principle**: karen is not optional at any of these three gates. If karen wasn't invoked, the work is INCOMPLETE.

---

### Agent Team Best Practices

**Mandatory: The Three-Gate Karen System**:
- **Gate #1**: After planning, before implementation
- **Gate #2**: Mid-implementation (~50% complete)
- **Gate #3**: Before delivery
- **ALL THREE are REQUIRED** - not optional
- If karen wasn't invoked at all three gates, work is INCOMPLETE

**Team Coordination**:
- Use `TeamCreate` to establish a team for complex features
- Use `TaskCreate` to break down work into specific tasks
- Assign tasks to specialized agents based on their expertise
- Agents should communicate via `SendMessage` for coordination
- **cross-platform-coordinator is responsible** for invoking karen at checkpoints

**Parallel vs. Sequential Work**:
- **Parallel**: Web and iOS Playground implementation can happen simultaneously
- **Sequential**: Design → Implementation → Testing → Integration must be sequential
- **Dependencies**: Sync logic requires database implementation to be complete first

**Agent Selection Rules**:

1. **Always use for cross-platform features**:
   - `cross-platform-coordinator` to orchestrate
   - `react-web-implementer` for web
   - `steve-jobs` for iOS

2. **Always use for sync features**:
   - `sync-specialist` for any feature involving Firestore sync
   - Critical for maintaining offline-first principles

3. **Always use before integration**:
   - `testing-czar` for quality validation
   - `Jenny` to verify spec compliance
   - `karen` for reality check

4. **Use conditionally**:
   - `design-research-analyst` for novel or complex features
   - `ultrathink-debugger` only when debugging complex issues
   - `unit-test-generator` for complex business logic (simple features can write tests inline)

**Avoid Over-Agenting**:
- Don't spawn 15 agents for a simple button component
- Simple features (< 100 lines) can be handled by a single agent
- Use teams for features that touch multiple platforms, involve sync, or have complex business logic

**Communication Patterns**:
- Agents should report completion to the team lead
- Use task status updates (`TaskUpdate`) to track progress
- Block on dependencies using `addBlockedBy` in task management
- Share findings in concise messages (avoid long reports)

### Project-Specific Agent Priorities

**For OYBC specifically**:

1. **Offline-first enforcement**: `sync-specialist` is critical for any feature that touches data
2. **Cross-platform consistency**: `cross-platform-coordinator` should oversee all UI features
3. **Quality gates**: `testing-czar`, `Jenny`, and `karen` are non-negotiable before integration
4. **Playground-first**: All implementation agents work in Playground first, no exceptions

### Quick Reference: Which Agent to Use

| Task Type | Agent(s) | When to Use |
|-----------|----------|-------------|
| **Architecture & Design** | `system-design-engineer` | New features, schema changes, API design |
| **Research** | `design-research-analyst` | Library selection, pattern research, approach evaluation |
| **Planning** | `Plan` | Breaking down complex features into tasks |
| **Cross-Platform Coordination** | `cross-platform-coordinator` | Any feature for both web + iOS |
| **Web Implementation** | `react-web-implementer` | React components, web UI, Dexie operations |
| **iOS Implementation** | `steve-jobs` | SwiftUI views, GRDB operations, iOS UI |
| **Sync Logic** | `sync-specialist` | Firestore sync, conflict resolution, offline-first patterns |
| **Unit Testing** | `unit-test-generator` | Creating tests for business logic, algorithms |
| **UI Testing** | `ui-comprehensive-tester` | End-to-end testing, user flows, cross-platform validation |
| **Quality Validation** | `testing-czar` | Pre-integration quality gates, coverage checks |
| **Over-engineering Check** | `code-quality-pragmatist` | Reviewing for unnecessary complexity |
| **Spec Verification** | `Jenny` | Ensuring implementation matches requirements |
| **Completion Validation** | `task-completion-validator` | Verifying features are truly complete |
| **Scope Enforcement (Gate #1)** | `karen` | Plan review - prevent scope creep in planning |
| **Scope Enforcement (Gate #2)** | `karen` | Mid-implementation check - catch scope creep early |
| **Reality Check (Gate #3)** | `karen` | Final check - cutting through BS, verify actual work |
| **Debugging** | `ultrathink-debugger` | Complex bugs, root cause analysis |
| **Codebase Exploration** | `Explore` | Finding files, understanding patterns |
| **Backlog Management** | `project-backlog-manager` | Managing tasks, priorities, project status |

### Example Team Composition

**Simple UI Feature** (e.g., Settings Toggle):
- Solo: `react-web-implementer` or `steve-jobs` handles everything
- No team needed

**Medium Feature** (e.g., Board Creation Form):
- `Plan` (create implementation plan)
- `karen` **Gate #1** (review plan for scope creep)
- `cross-platform-coordinator` (orchestrate)
- `react-web-implementer` (web implementation)
- `steve-jobs` (iOS implementation)
- `karen` **Gate #2** (mid-implementation check)
- `testing-czar` (quality validation)
- `karen` **Gate #3** (final reality check)

**Complex Feature** (e.g., Task Progress Tracking with Sync):
- `system-design-engineer` (architecture)
- `Plan` (detailed implementation plan)
- `karen` **Gate #1** (review plan for scope creep)
- `cross-platform-coordinator` (orchestrate)
- `react-web-implementer` (web implementation)
- `steve-jobs` (iOS implementation)
- `sync-specialist` (sync logic and conflict resolution)
- `karen` **Gate #2** (mid-implementation check)
- `unit-test-generator` (business logic tests)
- `ui-comprehensive-tester` (UI testing)
- `testing-czar` (quality validation)
- `Jenny` (spec verification)
- `karen` **Gate #3** (final reality check before integration)

## Playground Development Environment

**Purpose**: Safe, isolated environment for testing new features before production integration.

**Structure**:

- **Web**: `/apps/web/src/pages/Playground.tsx` (accessible via `/playground` route)
- **iOS**: `PlaygroundView.swift` (accessible from main navigation during development)

**Requirements**:

1. **Feature Isolation**: Each feature in the Playground should be clearly labeled and visually separated
2. **Display Mode Testing**: Toggle buttons/controls to switch between:
   - Light/Dark mode
   - Different device sizes (iOS)
   - Responsive layouts (web)
3. **Use Case Coverage**: For each feature, include:
   - Normal operation examples
   - Edge case scenarios
   - Error state demonstrations
   - Different data states (empty, partial, complete)
4. **Documentation**: Each feature should have a brief description of what it does and what to test
5. **Persistence**: Previous features remain in Playground for regression testing

**Workflow**:

1. Implement feature in Playground
2. User tests all scenarios manually
3. User approves feature
4. Extract feature from Playground and integrate into main app
5. Feature remains in Playground for future reference

## Branching Strategy

- Use feature branches named `feature/feature-name` for new features.
- Use bugfix branches named `bugfix/bug-description` for bug fixes.
- Merge to `main` only after code review and passing all tests.

## Commands

### Monorepo (Root)

```bash
# Install all dependencies
pnpm install

# Build all packages
pnpm build

# Run all tests
pnpm test

# Lint all packages
pnpm lint

# Clean all build artifacts
pnpm clean
```

### Shared Package (`packages/shared`)

```bash
cd packages/shared

# Build types and validation
pnpm build

# Watch mode for development
pnpm dev

# Run tests
pnpm test

# Watch mode for tests
pnpm test:watch

# Coverage report
pnpm test:coverage
```

### Web App (`apps/web`)

```bash
cd apps/web

# Start dev server (http://localhost:5173)
pnpm dev

# Build for production
pnpm build

# Preview production build
pnpm preview

# Type checking
pnpm typecheck

# Lint
pnpm lint
```

### iOS App (`apps/ios`)

```bash
cd apps/ios

# Open in Xcode
open OYBC.xcodeproj

# Build and run (in Xcode): ⌘R

# Run tests (in Xcode): ⌘U

# Or via command line
swift build
swift test
```

## Architecture

### Monorepo Structure

```
oybc/
├── apps/
│   ├── ios/           # SwiftUI + GRDB (SQLite)
│   └── web/           # React + Vite + Dexie (IndexedDB)
├── packages/
│   └── shared/        # TypeScript types, algorithms, validation
└── docs/              # Architecture documentation
```

### Offline-First Design Principle

**Critical**: Local databases are the **source of truth**, NOT Firestore.

**Data Flow**:

1. User action → Update local DB (< 10ms)
2. UI updates immediately
3. Queue sync operation
4. Background: Sync to Firestore when online

**NOT**:

1. ~~User action → Network request → Wait for response~~
2. ~~Loading spinner → Update UI~~

All reads must be from local database for instant UX (< 10ms target).

### Database Schema - Identical Across Platforms

Both iOS (SQLite) and web (IndexedDB) use the same schema:

**Tables**:

- `users` - User profiles
- `boards` - Game boards
- `tasks` - Reusable task definitions
- `task_steps` - Progress task steps
- `board_tasks` - Junction table (board ↔ task with completion state)
- `progress_counters` - Cross-board cumulative tracking
- `sync_queue` - Pending Firestore operations

**Key Design Elements**:

- **UUID primary keys** - Client-generated, enables offline creation
- **Version fields** - Optimistic locking for conflict resolution
- **Soft deletes** - `isDeleted` flag, never hard delete (sync-friendly)
- **ISO8601 timestamps** - Cross-platform consistency
- **Denormalized stats** - `board.completedTasks` stored directly for instant reads

### Type System - Single Source of Truth

**TypeScript types in `packages/shared`** define all data structures:

- `Board`, `Task`, `TaskStep`, `BoardTask`, `ProgressCounter`, `User`, `SyncQueueItem`
- Zod validation schemas for input validation
- Enums: `BoardStatus`, `TaskType`, `Timeframe`, `CenterSquareType`

**iOS Swift models** mirror TypeScript types exactly:

- Use GRDB's `Codable`, `FetchableRecord`, `PersistableRecord` protocols
- Custom encoding/decoding for JSON arrays (stored as strings in SQLite)
- Enums conform to `DatabaseValueConvertible`

**Web Dexie** uses TypeScript types directly:

- Import from `@oybc/shared`
- Compound indexes match iOS GRDB indexes
- Same query patterns across platforms

### Sync Strategy

**Conflict Resolution**: Last-write-wins using version fields (MVP)

- Higher version number wins
- Same version → newer timestamp wins
- Alternative (v1.1): Additive resolution for ProgressCounters

**Cross-Board Features**:

- **Achievement Squares**: Recompute from source data (not stored value)
- **Task Step Linking**: Additive merge of `completedStepIds` arrays
- **Bingo Lines**: Always recompute from task completion grid (derived data)

See `docs/SYNC_STRATEGY.md` for detailed conflict resolution patterns.

## Development Workflow

### Phase 1: Local Database

**Status**: ✅ Complete

- [x] iOS GRDB implementation (Schema.sql, Swift models, AppDatabase)
- [x] Web Dexie implementation (database.ts, operations/, hooks/)
- [x] Shared TypeScript types and validation schemas

### Phase 1.5: Working App Infrastructure (Current Phase)

**Status**: 🚧 In Progress

**Goal**: Get both iOS and web apps running locally for rapid testing

**Priority**: Must complete BEFORE building Phase 2 features

**iOS**:
- [ ] Create/verify Xcode project structure
- [ ] OYBCApp.swift entry point
- [ ] ContentView.swift with basic navigation
- [ ] Verify database connection (AppDatabase.shared)
- [ ] App builds and runs in simulator

**Web**:
- [ ] index.html entry point
- [ ] main.tsx with React setup
- [ ] App.tsx with basic structure
- [ ] Verify database connection (Dexie)
- [ ] `pnpm dev` runs successfully

**Success Criteria**:
- ✅ iOS app builds in Xcode and displays "Hello OYBC"
- ✅ Web app runs on localhost:5173 and displays "Hello OYBC"
- ✅ Both apps can initialize and read from local databases
- ✅ No compilation errors
- ✅ Ready for Phase 2 feature development

### Phase 2: Core Game Loop (Offline-Only)

**Goal**: Complete bingo game working entirely offline

**Prerequisites**: Phase 1.5 complete ✅ (working apps)

**Implementation Order** (Playground-first for each):

1. **5×5 Bingo Board Grid** ✅ COMPLETE - Grid layout with BingoSquare components, hardcoded task names
2. **Different Board Sizes** ✅ COMPLETE - 3×3, 4×4, 5×5 variants with size selector
3. **Bingo Detection Logic** ✅ COMPLETE - Detect rows, columns, diagonals; visual indication, GREENLOG
4. **Board Randomization** - Shuffle/randomize the faux task names on board creation/reset
5. **Free Space Logic** - Center square auto-complete, special handling for odd-sized boards
6. **Tasks & Task Creation** - Real task data, creation UI, board creation flow
7. **Celebrations & Polish** - Animations, haptics, visual effects

**Focus**:
- Board grid display (LazyVGrid on iOS, CSS Grid on web)
- Task completion with instant feedback
- Bingo detection algorithm
- Board randomization and free space mechanics
- Board creation UI (both platforms)
- Celebrations (animations/haptics)

**Testing**: Airplane mode, all operations < 10ms

**Rationale for Order**: Complete all basic board mechanics (grid, detection, randomization, free space) with faux data before introducing the task system. This allows testing core gameplay without database complexity.

### Phase 3: Authentication & Sync Layer

**Goal**: Firebase auth + background sync

**Key Components**:

- Firebase Auth (sign up, sign in, sign out)
- Sync queue processing (batch operations, retry logic)
- Pull sync (fetch remote changes)
- Conflict resolution (version comparison)

**Testing**: Multi-device scenarios, offline/online switching

## Key Conventions

### iOS (Swift)

**Database Access**:

```swift
// Read
let boards = try AppDatabase.shared.fetchBoards(userId: userId)

// Write
try AppDatabase.shared.saveBoard(board)

// Transaction
try AppDatabase.shared.write { db in
    try task.save(db)
    try steps.forEach { try $0.save(db) }
}
```

**JSON Arrays in SQLite**:

- Arrays stored as JSON strings in database
- Custom `Codable` encode/decode to convert between Swift arrays and JSON strings
- Example: `completedLineIds: [String]?` ↔ `'["row_0", "col_1"]'`

**Computed Properties**:

- Don't store derived values (e.g., `completionPercentage`)
- Compute from stored values to avoid drift

### Web (TypeScript)

**Database Access**:

```typescript
// Read
const boards = await fetchBoards(userId);

// Write
await createBoard(userId, input);

// Transaction
await db.transaction("rw", [db.tasks, db.taskSteps], async () => {
  await db.tasks.add(task);
  await Promise.all(steps.map((s) => db.taskSteps.add(s)));
});
```

**React Hooks - Reactive Queries**:

```typescript
// Automatically re-renders when database changes
const boards = useBoards(userId); // useLiveQuery from dexie-react-hooks
const board = useBoard(boardId);
```

**Compound Indexes**:

```typescript
// Fast (uses index)
db.boards.where("[userId+isDeleted]").equals([userId, false]);

// Slow (table scan)
db.boards.filter((b) => b.userId === userId && !b.isDeleted);
```

### Shared Package (TypeScript)

**No Platform-Specific Code**:

- ❌ No database code (GRDB, Dexie, Room)
- ❌ No Firebase code (Auth, Firestore)
- ❌ No React components or SwiftUI views
- ✅ Only pure TypeScript: types, algorithms, validation, constants

**Testing**:

- All algorithms must have Jest tests
- Target: 80%+ code coverage
- Test files in `__tests__/` adjacent to source

## Important Patterns

### Optimistic Updates

**Always** update local database before syncing:

```typescript
// ✅ Correct
async function completeTask(taskId: string) {
  // 1. Update local DB (instant)
  await db.boardTasks.update(taskId, { isCompleted: true });

  // 2. UI updates automatically (reactive)

  // 3. Queue sync (background)
  await addToSyncQueue("board_task", taskId, "UPDATE", task);
}

// ❌ Wrong
async function completeTask(taskId: string) {
  // Don't wait for network!
  await firestore
    .collection("board_tasks")
    .doc(taskId)
    .update({ isCompleted: true });
  await db.boardTasks.update(taskId, { isCompleted: true });
}
```

### Soft Deletes

**Never** hard delete records:

```typescript
// ✅ Correct
await deleteBoard(boardId); // Sets isDeleted=true, deletedAt=timestamp

// ❌ Wrong
await db.boards.delete(boardId); // Breaks sync, can't propagate to other devices
```

### Denormalized Stats

Update stats when source data changes:

```typescript
// When completing a task, update board stats
await db.boardTasks.update(taskId, { isCompleted: true });
await updateBoardStats(boardId, {
  completedTasks: board.completedTasks + 1,
});
```

### Version Field Increment

Always increment version on updates:

```typescript
await db.boards.update(id, {
  name: newName,
  updatedAt: currentTimestamp(),
  version: board.version + 1, // Critical for conflict resolution
});
```

## Performance Targets

- **Local reads**: < 10ms
- **Local writes**: < 10ms
- **Bingo detection**: < 50ms
- **Cross-board queries**: < 200ms
- **Sync (background)**: Don't block UI

## Common Pitfalls

### ❌ Don't Skip Verification Gates

**CRITICAL FAILURE MODE**: Delivering code that doesn't compile or has scope creep.

**Real Example** (2026-02-07): The Playground infrastructure was delivered with:
- iOS code that referenced `OYBC.Task` without verifying the model was in the Xcode project
- "Clear Test Data" functionality that was NOT requested (scope creep)
- No compilation verification before delivery
- testing-czar, Jenny, and karen were never invoked

**Prevention - The Three-Gate Karen System**:
1. **Gate #1 (karen)**: Review plan after creation, before implementation
2. **Gate #2 (karen)**: Check implementation at 50% completion
3. **Gate #3 (karen)**: Final reality check before delivery
4. **ALWAYS run testing-czar** before claiming work is done
5. **ALWAYS run Jenny** to verify scope adherence
6. **Test compilation** on BOTH platforms before delivery
7. **Never add "nice-to-have" features** without explicit approval

**Rule**: If karen was not invoked at ALL THREE gates, the work is INCOMPLETE. If testing-czar or Jenny were not invoked, the work is INCOMPLETE.

### ❌ Don't Skip the Playground

**NEVER** integrate features directly into the main app. ALL features must go through Playground testing first and receive explicit user approval before integration.

### ❌ Don't Implement Multiple Features at Once

Only work on ONE feature at a time. Wait for user direction before moving to the next feature.

### ❌ Don't Assume Feature Approval

Just because a feature works in the Playground does NOT mean it's ready for integration. Wait for explicit user approval.

### ❌ Don't Copy Code from MVP Archive

The `oybc_v1.archive/` directory is for **reference only** (algorithm patterns). This is a fresh rebuild with simplified architecture.

### ❌ Don't Use Firestore as Primary Storage

Local database is source of truth. Firestore is sync layer only.

### ❌ Don't Hard Delete

Always use soft deletes (`isDeleted` flag) for sync compatibility.

### ❌ Don't Trust Denormalized Values During Conflicts

Achievement squares, bingo lines, completion percentages — always recompute from source data during conflict resolution.

### ❌ Don't Block UI for Sync

All sync operations must be background/async. User should never see "Syncing..." spinners.

## Documentation

- **ARCHITECTURE.md** - Comprehensive technical plan, development phases
- **OFFLINE_FIRST.md** - Why offline-first, how it works, data flow examples
- **SYNC_STRATEGY.md** - Conflict resolution patterns, cross-board queries
- **README.md** - Project overview, setup instructions

## Development Status

**Phase 1**: Local Database Setup ✅ COMPLETE

**Phase 1.5**: Working App Infrastructure ✅ COMPLETE
- ✅ Web app infrastructure (Vite + React)
- ✅ iOS app infrastructure (Xcode + SwiftUI)
- ✅ Database connections verified
- ✅ Apps build and run successfully
- ✅ Playground infrastructure (both platforms)
- ✅ BingoSquare component (2026-02-13)

**Current Phase**: Phase 2 - Core Game Loop (Offline-Only) 🚧 IN PROGRESS

**Progress**: Features 1-5 COMPLETE (Basic board mechanics done)

**Next**: Feature 6 - Tasks & Task Creation (Real data integration)

**Priority**: Build game loop features in Playground, test, then integrate

**Phase 2 Implementation Plan** (Playground-first approach):

### Feature 1: 5×5 Bingo Board Grid ✅ COMPLETE
- 5 rows × 5 columns grid layout
- Uses BingoSquare components
- Hardcoded task names ("Task 1", "Task 2", etc.)
- All squares toggleable
- Center square special styling
- Both web (CSS Grid) and iOS (LazyVGrid)

### Feature 2: Different Board Sizes ✅ COMPLETE
- 3×3 mini board
- 4×4 standard board
- 5×5 full board (from Feature 1)
- Existing board sections in Playground

### Feature 3: Bingo Detection Logic ✅ COMPLETE (2026-02-15)
- Detect completed rows (5 in a row)
- Detect completed columns (5 in a column)
- Detect completed diagonals (2 diagonals)
- Visual indication when bingo detected (gold highlighting)
- Bingo message display ("Bingo! (row_0, col_2)")
- GREENLOG detection (all squares complete)
- 100% test coverage (48 tests passing)

### Feature 4: Board Randomization ✅ COMPLETE
- Shuffle/randomize the faux task names on board creation
- Randomize on board reset
- Different randomization each time
- Same randomization algorithm across platforms
- Shuffle button in Playground boards
- Preserves auto-completed center squares (FREE, CUSTOM_FREE)
- Keeps CHOSEN center square fixed during shuffle

### Feature 5: Center Space Logic ✅ COMPLETE (2026-02-15)
- Four center space types for odd-sized boards (3×3, 5×5):
  - True Free Space: auto-completed, locked, shows "FREE SPACE"
  - Customizable Free Space: auto-completed, locked, shows custom name
  - User-Chosen Center: NOT auto-completed, toggleable, stays fixed during shuffle
  - No Center Space: ordinary square, no special treatment
- Five Playground demo sections (both platforms)
- Data model complete (CenterSquareType enum, helper functions, Zod validation)
- 86 tests passing with 100% coverage
- Orange border for special centers (FREE, CUSTOM_FREE, CHOSEN)
- No border for NONE type
- Even-sized boards (4×4): No center space logic

### Feature 6: Tasks & Task Creation (NEXT)
- Real task data from database
- Task creation UI
- Task assignment to board squares
- Board creation flow

### Feature 7: Celebrations & Polish
- Animations when bingo detected
- Haptic feedback (iOS)
- Visual effects
- Sound effects (optional)

**Approach**:
- Implement one feature at a time in Playground
- Test all display modes and use cases
- Get user approval before moving to next feature
- Integration into main app happens AFTER all Playground features approved

**Timeline**: 12-14 weeks to production (see ARCHITECTURE.md)
