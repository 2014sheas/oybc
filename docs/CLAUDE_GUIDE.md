# Claude Code Guide for OYBC

This guide helps Claude Code work effectively on the OYBC project.

## Architecture Overview

**Critical**: OYBC uses **offline-first, local-first architecture**:

- **Local DB = Source of Truth**: GRDB (iOS), Dexie (web)
- **Firestore = Sync Layer ONLY**: Background sync, NOT primary storage
- **All writes**: Update local DB first (< 10ms), sync in background
- **All reads**: From local DB only (no Firestore queries for normal operations)
- **NO copying from MVP**: Fresh design, simplified architecture

## Project Structure

```
oybc/
├── apps/
│   ├── ios/          # SwiftUI + GRDB + Firebase
│   └── web/          # Next.js + Dexie + Firebase
├── packages/
│   ├── shared/       # TypeScript only (types, algorithms, validation)
│   └── design-tokens/
└── docs/             # Documentation
```

## Working on iOS (apps/ios/)

### Tech Stack
- **UI**: SwiftUI
- **Database**: GRDB.swift (SQLite wrapper)
- **Sync**: Firebase iOS SDK (Auth, Firestore)
- **State**: Combine + @Observable

### Key Directories
- `Database/`: GRDB setup, schema, models, queries
- `Sync/`: Firebase sync service (background only)
- `Features/`: Feature-based UI organization
  - `Auth/`: Login, register views
  - `Boards/`: Board CRUD, grid view
  - `Tasks/`: Task modals, components
- `Models/`: Swift data models
- `Utils/`: Swift utilities

### Guidelines
1. **All database operations use GRDB** (NOT Firebase)
2. **Firebase is for sync only** (background, non-blocking)
3. Use `async/await` for database operations
4. Use `@Observable` for reactive state
5. Follow SwiftUI best practices (small, composable views)

### Example: Creating a Board

```swift
// ✅ CORRECT: Save to local DB first, sync in background
func createBoard(_ input: CreateBoardInput) async throws -> Board {
    // 1. Create board in local GRDB database
    let board = try await dbService.createBoard(input)

    // 2. Queue sync operation (background)
    try await syncQueue.enqueue(.create, entity: board)

    return board
}

// ❌ WRONG: Don't save to Firestore first
func createBoard(_ input: CreateBoardInput) async throws -> Board {
    // DON'T DO THIS - Firestore is not the source of truth
    let board = try await firestore.createBoard(input)
    return board
}
```

## Working on Web (apps/web/)

### Tech Stack
- **Framework**: Next.js 14 (App Router)
- **Database**: Dexie.js (IndexedDB wrapper)
- **Sync**: Firebase JS SDK v10 (Auth, Firestore)
- **State**: Zustand
- **Styling**: Tailwind CSS + shadcn/ui

### Key Directories
- `src/app/`: Next.js App Router pages
- `src/db/`: Dexie setup, schema, services
- `src/sync/`: Firebase sync service (background only)
- `src/components/`: React components
- `src/lib/`: Utilities, helpers

### Guidelines
1. **All database operations use Dexie** (NOT Firebase)
2. **Firebase is for sync only** (background, non-blocking)
3. Use Server Components where possible
4. Client Components for interactivity (mark with 'use client')
5. Import shared types from `@oybc/shared`

### Example: Creating a Board

```typescript
// ✅ CORRECT: Save to local DB first, sync in background
async function createBoard(input: CreateBoardInput): Promise<Board> {
  // 1. Validate input
  const validated = CreateBoardInputSchema.parse(input);

  // 2. Create board in local Dexie database
  const board = await db.boards.create(validated);

  // 3. Queue sync operation (background)
  await syncQueue.enqueue({
    entityType: 'board',
    entityId: board.id,
    operationType: SyncOperationType.CREATE,
    payload: board
  });

  return board;
}

// ❌ WRONG: Don't query Firestore for reads
async function getBoard(id: string): Promise<Board> {
  // DON'T DO THIS - always read from local DB
  const board = await firestore.collection('boards').doc(id).get();
  return board;
}

// ✅ CORRECT: Read from local DB
async function getBoard(id: string): Promise<Board> {
  const board = await db.boards.get(id);
  return board;
}
```

## Working on Shared (packages/shared/)

### What Goes Here
- ✅ TypeScript types and interfaces
- ✅ Algorithms (bingo detection, randomization, calendar)
- ✅ Validation schemas (Zod)
- ✅ Constants and enums
- ✅ Pure utility functions

### What Does NOT Go Here
- ❌ Database code (GRDB, Dexie, Room)
- ❌ Firebase code (Auth, Firestore)
- ❌ React components
- ❌ SwiftUI views
- ❌ Platform-specific code

### Guidelines
1. **Pure TypeScript only** (no side effects, no I/O)
2. **Platform-agnostic** (works in browser, Node.js, and as reference for Swift)
3. **All algorithms MUST have Jest tests** (80%+ coverage)
4. **Minimal dependencies** (only zod for validation)

### Example: Adding an Algorithm

```typescript
// ✅ CORRECT: Pure function with tests
// src/algorithms/bingoDetection.ts
export function detectBingos(
  grid: BoardTask[][],
  boardSize: number
): BingoLine[] {
  // Pure logic, no database calls, no Firebase
  const lines: BingoLine[] = [];

  // Check rows, columns, diagonals
  // ...

  return lines;
}

// tests/bingoDetection.test.ts
describe('detectBingos', () => {
  it('detects horizontal bingo', () => {
    // Test cases
  });
});
```

## Key Principles

### 1. Offline-First Operations

**All operations work offline**:
- Create board → local DB → UI updates instantly
- Complete task → local DB → UI updates instantly
- Sync queue → processes in background when online

```typescript
// Pattern: Optimistic update
async function completeTask(boardTaskId: string) {
  // 1. Update local DB immediately
  await db.boardTasks.update(boardTaskId, {
    isCompleted: true,
    completedAt: new Date().toISOString()
  });

  // 2. UI reflects change instantly (< 10ms)

  // 3. Queue sync (background)
  await syncQueue.enqueue({ /* ... */ });
}
```

### 2. Read Performance

**Target: < 10ms for all local reads**

- Use indexed queries
- Denormalize stats (avoid joins)
- Cache frequently accessed data

```swift
// iOS: Use GRDB indexes
// Schema.sql
CREATE INDEX idx_boards_user_status ON boards(user_id, status);

// Fast query (indexed)
let boards = try await db.boards
  .filter(userId: currentUserId)
  .filter(status: .active)
  .fetchAll()
```

```typescript
// Web: Use Dexie compound indexes
// schema.ts
boards: '++id, userId, [userId+status], updatedAt'

// Fast query (indexed)
const boards = await db.boards
  .where('[userId+status]')
  .equals([currentUserId, BoardStatus.ACTIVE])
  .toArray();
```

### 3. Sync Strategy

**Background sync pattern**:

1. User action → update local DB
2. Insert into `sync_queue` table
3. Background worker processes queue:
   - Batch operations (up to 50)
   - Send to Firestore
   - Remove from queue on success
   - Retry with exponential backoff on failure

```typescript
// Sync service (runs in background)
async function processSyncQueue() {
  const pending = await db.syncQueue
    .where('status')
    .equals(SyncStatus.PENDING)
    .limit(SYNC_BATCH_SIZE)
    .toArray();

  for (const item of pending) {
    try {
      await syncToFirestore(item);
      await db.syncQueue.update(item.id, { status: SyncStatus.COMPLETED });
    } catch (error) {
      await handleSyncError(item, error);
    }
  }
}
```

### 4. Conflict Resolution

**Last-write-wins** with version fields:

```typescript
function resolveConflict(local: Board, remote: Board): Board {
  // Higher version wins
  if (remote.version > local.version) return remote;

  // Same version, newer timestamp wins
  if (remote.updatedAt > local.updatedAt) return remote;

  // Keep local
  return local;
}
```

## Common Pitfalls

### ❌ DON'T

1. **Read from Firestore for normal operations**
   ```typescript
   // WRONG
   const board = await firestore.collection('boards').doc(id).get();
   ```

2. **Block UI on network calls**
   ```swift
   // WRONG
   showLoadingSpinner()
   let board = try await firestore.getBoard(id)
   hideLoadingSpinner()
   ```

3. **Copy code from MVP**
   ```typescript
   // WRONG - design fresh, don't copy
   // (copying old Firebase service code)
   ```

4. **Add complex features prematurely**
   ```typescript
   // WRONG - keep it simple for MVP
   // (adding task linking with circular reference detection)
   ```

5. **Skip offline testing**
   ```bash
   # WRONG - always test offline
   # Enable airplane mode and test all operations
   ```

### ✅ DO

1. **Read from local DB**
   ```typescript
   // CORRECT
   const board = await db.boards.get(id);
   ```

2. **Update UI immediately**
   ```swift
   // CORRECT
   try await db.completeTask(taskId)
   // UI updates instantly, no spinner
   await syncQueue.enqueue(.update, entity: task)
   ```

3. **Design fresh**
   ```typescript
   // CORRECT - implement from scratch with offline-first in mind
   async function createBoard(input: CreateBoardInput) {
     // Fresh implementation
   }
   ```

4. **Keep MVP simple**
   ```typescript
   // CORRECT - minimal, focused features
   // Defer complex linking to v1.1
   ```

5. **Test offline extensively**
   ```bash
   # CORRECT - airplane mode testing
   # Create board, complete tasks, verify sync when online
   ```

## Testing Strategy

### iOS (XCTest)
```swift
func testCreateBoardOffline() async throws {
    // 1. Disable network
    NetworkMonitor.shared.forceOffline()

    // 2. Create board
    let board = try await service.createBoard(input)

    // 3. Verify saved to local DB
    let saved = try await db.boards.get(board.id)
    XCTAssertEqual(saved.name, input.name)

    // 4. Verify queued for sync
    let queued = try await db.syncQueue.filter(entityId: board.id).first()
    XCTAssertNotNil(queued)
}
```

### Web (Vitest)
```typescript
describe('createBoard', () => {
  it('works offline', async () => {
    // 1. Mock offline
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);

    // 2. Create board
    const board = await createBoard(input);

    // 3. Verify saved to Dexie
    const saved = await db.boards.get(board.id);
    expect(saved.name).toBe(input.name);

    // 4. Verify queued for sync
    const queued = await db.syncQueue.where('entityId').equals(board.id).first();
    expect(queued).toBeDefined();
  });
});
```

### Shared (Jest)
```typescript
describe('detectBingos', () => {
  it('detects horizontal bingo on 3x3 board', () => {
    const grid = createCompletedRow(0); // Helper
    const bingos = detectBingos(grid, 3);

    expect(bingos).toHaveLength(1);
    expect(bingos[0].lineType).toBe(BingoLineType.ROW);
    expect(bingos[0].lineIndex).toBe(0);
  });
});
```

## File Organization

### iOS Feature Structure
```
Features/
  Boards/
    Views/
      BoardGridView.swift
      BoardListView.swift
      CreateBoardView.swift
    ViewModels/
      BoardGridViewModel.swift
    Models/
      BoardGridItem.swift
```

### Web Feature Structure
```
src/
  app/
    boards/
      page.tsx              # List view
      create/
        page.tsx            # Create form
      [id]/
        page.tsx            # Board detail
  components/
    boards/
      BoardGrid.tsx
      BoardSquare.tsx
  db/
    services/
      boardService.ts       # Dexie operations
```

## Naming Conventions

### TypeScript
- **Files**: camelCase (`boardService.ts`, `bingoDetection.ts`)
- **Components**: PascalCase (`BoardGrid.tsx`)
- **Interfaces**: PascalCase (`Board`, `CreateBoardInput`)
- **Functions**: camelCase (`createBoard`, `detectBingos`)
- **Constants**: UPPER_SNAKE_CASE (`MAX_SYNC_RETRIES`)

### Swift
- **Files**: PascalCase (`BoardGridView.swift`)
- **Structs/Classes**: PascalCase (`Board`, `DatabaseService`)
- **Functions**: camelCase (`createBoard`, `detectBingos`)
- **Constants**: camelCase (`maxSyncRetries`)

## Git Workflow

### Branch Naming
- `feature/board-creation-ui` - New features
- `fix/sync-queue-retry` - Bug fixes
- `refactor/database-service` - Refactoring
- `test/bingo-detection` - Test improvements

### Commit Messages
```
feat: add board creation UI for iOS

- CreateBoardView with form inputs
- Board size and timeframe pickers
- Save to GRDB and queue sync
- Tests for offline creation

Implements Phase 2 Week 3 milestone
```

## Performance Targets

- **Local DB reads**: < 10ms
- **Local DB writes**: < 10ms
- **UI updates**: Instant (no loading spinners)
- **Sync batch**: 50 operations per batch
- **Sync interval**: 5 minutes (when online)
- **Initial load**: < 100ms (from local cache)

## Security

### Firestore Rules
```javascript
// Users can only access their own data
match /boards/{boardId} {
  allow read, write: if request.auth != null &&
                        resource.data.userId == request.auth.uid;
}
```

### Local DB
- iOS: App Sandbox (automatic encryption at rest)
- Web: IndexedDB (origin-isolated, no cross-origin access)

## Resources

- [GRDB Documentation](https://github.com/groue/GRDB.swift)
- [Dexie Documentation](https://dexie.org/)
- [Firebase iOS SDK](https://firebase.google.com/docs/ios/setup)
- [Firebase JS SDK](https://firebase.google.com/docs/web/setup)
- [Next.js App Router](https://nextjs.org/docs/app)

## Questions?

When in doubt:
1. **Offline-first**: Does it work without internet?
2. **Local DB first**: Are we reading from local DB?
3. **Background sync**: Is sync non-blocking?
4. **Instant UX**: Is the UI updating immediately?

If the answer is "yes" to all four, you're on the right track!
