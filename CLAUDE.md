# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OYBC (On Your Bingo Card) — An offline-first, gamified task management app that turns goals into interactive bingo boards. Multi-platform (iOS native + web) with seamless offline functionality and background sync.

**Core Architecture**: Local-first design where local databases (GRDB on iOS, Dexie on web) are the source of truth, with Firestore providing background sync for multi-device support only.

## Code Quality Standards

- Type hints and docstrings required for all functions and classes. Public APIs must document parameters, return values, and exceptions.
- Functions must be focused and small. PascalCase for classes, camelCase for functions/variables.
- Follow existing patterns within the app exactly.
- **Reuse before creating**: Search for existing utilities/components before writing new code.
- **Extract at three**: Same logic in 3+ places → extract to shared utility.
- **Share across platforms**: Constants, formatting, and validation that must be consistent across web and iOS should be centralised in a single definition.
- Proper error handling and logging for all database and network interactions.
- Evaluate third-party libraries carefully before importing — must be necessary, well-maintained, and not bloat app size.

## Testing Standards

- All new features and bug fixes must include unit tests covering core logic.
- Aim for at least 80% code coverage in all packages.
- Use Jest for TypeScript tests and XCTest for Swift tests.
- Tests should be deterministic and not rely on external services or network calls.

## Feature Implementation Guidelines

**CRITICAL: Playground-First Development Process**

1. **ONE Feature at a Time**: Only implement the single feature the user explicitly decides to work on.
2. **User-Driven Selection**: The user determines which feature to implement.
3. **Playground Before Integration**: ALL features must first be added to a "Playground" page on both platforms before integration into the main app.
4. **No Integration Without Approval**: Features must NOT be introduced into production code until the user explicitly approves after testing.
5. **Comprehensive Testing in Playground**: Must demonstrate all user interactions, edge cases, error states, and data scenarios.
6. **Display Mode Coverage**: UI features must demonstrate light/dark mode, responsive layouts, and cross-platform consistency.
7. **Playground Persistence**: New features are added to the existing Playground, not replacing previous features.
8. **Reuse Existing Infrastructure**: Shared constants in `playgroundUtils.ts` / `PlaygroundUtils.swift`. Reusable components in `apps/web/src/components/playground/` / `apps/ios/OYBC/Views/Components/`.
9. **Mirror File Structure**: Every playground feature must be a separate file on both platforms. Container views stay thin. See Cross-Platform File Structure below.

**Standard Development Process**: Ask clarifying questions first. Create a branch per feature/bugfix. TDD approach. Plan before implementing.

## Agent Guidelines

- Simple features (< 100 lines): single agent. Don't over-agent.
- Complex cross-platform features: use `cross-platform-coordinator` to orchestrate `react-web-implementer` (web) + `steve-jobs` (iOS).
- Before delivery: verify BOTH platforms compile, run `testing-czar`, `Jenny`, and `karen`.
- **Three-Gate Karen System**: Run `karen` after planning (Gate #1), at ~50% implementation (Gate #2), and before delivery (Gate #3). All three required or work is INCOMPLETE.
- iOS files must be added to `project.pbxproj` or they won't compile — always verify.

## Cross-Platform File Structure

Web and iOS must mirror each other's directory and file structure.

```
Web                                                  iOS
apps/web/src/                                        apps/ios/OYBC/
├── pages/
│   └── Playground.tsx          ←→                  Views/PlaygroundView.swift
│       (container only — no feature logic)              (container only)
├── components/
│   └── playground/
│       ├── playgroundUtils.ts  ←→                  Views/Playground/PlaygroundUtils.swift
│       ├── [X]Playground.tsx   ←→                  Views/Playground/[X]Playground.swift
│       ├── ProgressStepRow.tsx ←→                  Views/Components/ProgressStepRowView.swift
│       └── CountingStepFields.tsx ←→               Views/Components/CountingStepFieldsView.swift
│
└── components/
    ├── BingoBoard.tsx          ←→                  Views/Components/BingoBoard.swift
    └── BingoSquare.tsx         ←→                  Views/Components/BingoSquare.swift
```

**Rules**:
1. Container views stay thin — no form logic, no state, no database calls.
2. One file per playground feature, one file per reusable component.
3. Web: `[Name].tsx`. iOS: `[Name]View.swift` (views) or `[Name]Playground.swift` (features).
4. iOS: Every new Swift file must be added to `project.pbxproj` or it won't compile.
5. Verify both platforms have matching files before claiming completion.

## Commands

### Monorepo (Root)
```bash
pnpm install    # Install all dependencies
pnpm build      # Build all packages
pnpm test       # Run all tests
pnpm lint       # Lint all packages
pnpm clean      # Clean all build artifacts
```

### Shared Package (`packages/shared`)
```bash
cd packages/shared
pnpm build          # Build types and validation
pnpm dev            # Watch mode
pnpm test           # Run tests
pnpm test:watch     # Watch mode for tests
pnpm test:coverage  # Coverage report
```

### Web App (`apps/web`)
```bash
cd apps/web
pnpm dev        # Dev server (http://localhost:5173)
pnpm build      # Production build
pnpm preview    # Preview production build
pnpm typecheck  # Type checking
pnpm lint       # Lint
```

### iOS App (`apps/ios`)
```bash
open OYBC.xcodeproj  # Open in Xcode
# Build: ⌘R  |  Tests: ⌘U
swift build          # CLI build
swift test           # CLI tests
```

## Architecture

### Monorepo Structure
```
oybc/
├── apps/
│   ├── ios/           # SwiftUI + GRDB 6.24 (SQLite), iOS 17+, XcodeGen (project.yml)
│   └── web/           # React 18 + Vite + Dexie (IndexedDB) + React Router
├── packages/
│   └── shared/        # TypeScript types, algorithms, validation
└── docs/              # Architecture documentation
```

### Offline-First Design Principle

**Critical**: Local databases are the **source of truth**, NOT Firestore.

**Data Flow**: User action → Update local DB (< 10ms) → UI updates immediately → Queue sync → Background sync to Firestore when online.

**NOT**: ~~User action → Network request → Wait → Update UI~~

### Database Schema (Identical Across Platforms)

**Tables**: `users`, `boards`, `tasks`, `task_steps`, `board_tasks`, `progress_counters`, `sync_queue`

**Key Design Elements**:
- UUID primary keys (client-generated, enables offline creation)
- Version fields (optimistic locking for conflict resolution)
- Soft deletes (`isDeleted` flag, never hard delete)
- ISO8601 timestamps
- Denormalized stats (`board.completedTasks` for instant reads)

### Type System

**`packages/shared`** is the single source of truth for types: `Board`, `Task`, `TaskStep`, `BoardTask`, `ProgressCounter`, `User`, `SyncQueueItem`. Includes Zod validation schemas and enums (`BoardStatus`, `TaskType`, `Timeframe`, `CenterSquareType`).

- **iOS**: Swift models mirror TypeScript types using GRDB's `Codable`/`FetchableRecord`/`PersistableRecord`. JSON arrays stored as strings in SQLite.
- **Web**: Dexie uses TypeScript types directly from `@oybc/shared`. Compound indexes match iOS GRDB indexes.

### Sync Strategy

**Conflict Resolution** (MVP): Last-write-wins using version fields. Higher version wins; same version → newer timestamp wins.

**Cross-Board Features**: Achievement squares and bingo lines always recomputed from source data. Task step linking uses additive merge.

See `docs/SYNC_STRATEGY.md` for details.

## Key Conventions

### iOS (Swift)
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
- JSON arrays stored as JSON strings with custom `Codable` encode/decode
- Don't store derived values — compute from stored values

### Web (TypeScript)
```typescript
// Read
const boards = await fetchBoards(userId);
// Reactive queries
const boards = useBoards(userId); // useLiveQuery from dexie-react-hooks
// Fast compound index query
db.boards.where("[userId+isDeleted]").equals([userId, false]);
// Transaction
await db.transaction("rw", [db.tasks, db.taskSteps], async () => {
  await db.tasks.add(task);
  await Promise.all(steps.map((s) => db.taskSteps.add(s)));
});
```

### Shared Package
- No platform-specific code (no GRDB, Dexie, Firebase, React, SwiftUI)
- Only pure TypeScript: types, algorithms, validation, constants

## Important Patterns

- **Optimistic Updates**: Always update local DB first, then queue sync in background.
- **Soft Deletes**: Never hard delete. Use `isDeleted=true, deletedAt=timestamp`.
- **Denormalized Stats**: Update stats when source data changes (e.g., `board.completedTasks`).
- **Version Increment**: Always increment `version` field on updates (critical for conflict resolution).

## Common Pitfalls

- **Don't skip verification gates**: If karen/testing-czar/Jenny weren't invoked, work is INCOMPLETE.
- **Don't skip the Playground**: ALL features go through Playground first with explicit user approval.
- **Don't implement multiple features at once**: ONE at a time, user-directed.
- **Don't copy from MVP archive**: `oybc_v1.archive/` is reference only.
- **Don't use Firestore as primary storage**: Local DB is source of truth.
- **Don't hard delete**: Always soft delete for sync compatibility.
- **Don't trust denormalized values during conflicts**: Recompute from source data.
- **Don't block UI for sync**: All sync operations must be background/async.
- **Counting task field order**: Action → Max Count → Unit (not Action → Unit → Max Count).
- **Counting task title**: Optional and auto-generated from `action + maxCount + unit` if blank. Use `generateCounterTaskTitle()` from `@oybc/shared`. Not required like normal task titles.

## Performance Targets

- Local reads/writes: < 10ms
- Bingo detection: < 50ms
- Cross-board queries: < 200ms
- Sync: background only, never block UI

## Documentation

- `docs/ARCHITECTURE.md` — Technical plan, development phases
- `docs/OFFLINE_FIRST.md` — Offline-first design and data flow
- `docs/SYNC_STRATEGY.md` — Conflict resolution patterns
- `docs/TASK_SYSTEM.md` — Comprehensive task system documentation
- `docs/COMPOSITE_TASKS.md` — Composite/progress task system details

**Not yet configured**: CI/CD, Prettier, SwiftLint. Linting is ESLint only (web).

## Development Status

**Phase 1**: Local Database Setup — COMPLETE
**Phase 1.5**: Working App Infrastructure — COMPLETE (web + iOS + Playground + BingoSquare)

**Current Phase**: Phase 2 - Core Game Loop (Offline-Only)

| # | Feature | Status |
|---|---------|--------|
| 1 | 5x5 Bingo Board Grid | COMPLETE |
| 2 | Different Board Sizes (3x3, 4x4, 5x5) | COMPLETE |
| 3 | Bingo Detection Logic | COMPLETE |
| 4 | Board Randomization | COMPLETE |
| 5 | Center Space Logic | COMPLETE |
| 6 | Tasks & Task Creation | NEXT |
| 7 | Celebrations & Polish | — |

**Next**: Feature 6 - Tasks & Task Creation (real data, creation UI, board creation flow)

**Phase 3** (future): Authentication & Sync Layer (Firebase Auth, sync queue, conflict resolution)

**Approach**: Implement one feature at a time in Playground → test → get user approval → integrate.

## Branching Strategy

- Feature branches: `feature/feature-name`
- Bugfix branches: `bugfix/bug-description`
- Merge to `master` only after code review and passing all tests.