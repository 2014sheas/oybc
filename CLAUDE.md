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

- Ask as many clarifying questions as needed before starting implementation.
- Create a new branch for each feature or bug fix.
- Write tests before implementing the feature (TDD approach).
- Create a detailed plan before implementing new features, including data flow diagrams and state management strategies.
- Upon feature creation, do not implement into existing code without first being explicitly instructed to do so.
- New features will first be added to a preview page on all platforms for testing before being integrated into the main app.
- The preview page will persist across all features, with new features being added to it as they are developed.

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

**Prerequisites**: Phase 1.5 complete (working apps)

**Focus**:

- Board creation UI (both platforms)
- Board grid display (LazyVGrid on iOS, CSS Grid on web)
- Task completion with instant feedback
- Bingo detection algorithm
- Celebrations (animations/haptics)

**Testing**: Airplane mode, all operations < 10ms

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

**Current Phase**: Phase 1.5 - Working App Infrastructure 🚧 IN PROGRESS

**Priority**: Get iOS and web apps running locally before building features

**Immediate Goals**:
1. Set up web app infrastructure (Vite + React entry points)
2. Set up iOS app infrastructure (Xcode project + SwiftUI entry points)
3. Verify database connections on both platforms
4. Ensure apps can build and run successfully

**Next Phase**: Phase 2 - Core Game Loop (Offline-Only)
- Board creation UI
- Board grid display
- Task completion interaction
- Bingo detection
- Celebrations

**Timeline**: 12-14 weeks to production (see ARCHITECTURE.md)
