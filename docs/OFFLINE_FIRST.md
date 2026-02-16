# Offline-First Architecture

This document explains the offline-first architecture of OYBC and why it's essential for the user experience.

## What is Offline-First?

**Offline-first** means the app is designed to work **completely offline** by default, with network sync as an enhancement rather than a requirement.

### Traditional Cloud-First Approach ❌

```
User action → Network request → Server processes → Response → Update UI
                    ↓
         (Network required, slow, fragile)
```

**Problems**:
- ❌ Requires internet connection
- ❌ Slow (network latency 100-500ms minimum)
- ❌ Loading spinners everywhere
- ❌ Breaks on poor connections
- ❌ Frustrating UX

### OYBC Offline-First Approach ✅

```
User action → Update local DB → Update UI instantly
                    ↓
         (Background: Queue sync when online)
```

**Benefits**:
- ✅ Works perfectly offline
- ✅ Fast (< 10ms operations)
- ✅ No loading spinners
- ✅ Reliable (no network errors)
- ✅ Delightful UX

## How It Works

### 1. Local Database as Source of Truth

**iOS**: GRDB (SQLite)
**Web**: Dexie (IndexedDB)

All data is stored locally first. The local database is the **primary storage**, not a cache.

```typescript
// Local database IS the source of truth
const board = await db.boards.get(id);  // ✅ FAST: < 10ms
```

```typescript
// Firestore is NOT the source of truth
const board = await firestore.collection('boards').doc(id).get();  // ❌ SLOW: 100-500ms
```

### 2. Optimistic Updates

Update the local database **immediately**, before syncing to the server.

```typescript
async function completeTask(taskId: string) {
  // 1. Update local DB (< 10ms)
  await db.boardTasks.update(taskId, {
    isCompleted: true,
    completedAt: new Date().toISOString()
  });

  // 2. UI updates instantly ✨

  // 3. Queue sync (background)
  await syncQueue.enqueue({
    entityType: 'boardTask',
    entityId: taskId,
    operationType: SyncOperationType.UPDATE,
    payload: updatedTask
  });

  // User sees completion immediately, sync happens later
}
```

### 3. Background Sync

Sync operations run in the background, never blocking the UI.

```typescript
// Sync worker (runs periodically)
async function processSyncQueue() {
  // Only run when online
  if (!navigator.onLine) return;

  // Get pending operations
  const pending = await db.syncQueue
    .where('status')
    .equals(SyncStatus.PENDING)
    .limit(50)  // Batch for efficiency
    .toArray();

  // Process each operation
  for (const item of pending) {
    try {
      await syncToFirestore(item);
      await db.syncQueue.update(item.id, {
        status: SyncStatus.COMPLETED,
        completedAt: new Date().toISOString()
      });
    } catch (error) {
      // Retry with exponential backoff
      await handleSyncError(item, error);
    }
  }
}

// Trigger sync on:
// - App launch
// - Network reconnection
// - Periodic interval (every 5 minutes)
setInterval(processSyncQueue, 5 * 60 * 1000);
```

### 4. Conflict Resolution

When two devices modify the same data offline, conflicts must be resolved.

**Strategy: Last-Write-Wins with Version Fields**

```typescript
interface Board {
  version: number;      // Incremented on each update
  updatedAt: string;    // ISO8601 timestamp
  // ...
}

function resolveConflict(local: Board, remote: Board): Board {
  // Higher version number wins
  if (remote.version > local.version) {
    return remote;
  }

  // Same version, newer timestamp wins
  if (remote.version === local.version) {
    return new Date(remote.updatedAt) > new Date(local.updatedAt)
      ? remote
      : local;
  }

  // Keep local (local version is higher)
  return local;
}
```

**Example Conflict Scenario**:

1. User has iPhone and iPad
2. Both devices offline
3. iPhone: Edit board name to "Weekly Goals" (version 2)
4. iPad: Edit board name to "Work Tasks" (version 2)
5. Both devices come online
6. Conflict detected (both version 2)
7. Compare timestamps → newer wins
8. Loser device updates to winner's version (version 3)

## Data Flow Examples

### Creating a Board (Offline)

```
User fills form → Validate input → Generate UUID
                                       ↓
                                 Save to local DB
                                       ↓
                                 Update UI (instant)
                                       ↓
                                 Queue sync operation
                                       ↓
                          (User sees board immediately)
                                       ↓
                          (Background: Sync when online)
```

**Timeline**:
- 0ms: User taps "Create Board"
- 5ms: Validation complete
- 10ms: Saved to local DB
- 10ms: UI shows new board ✨
- Later: Syncs to Firestore (when online)

### Completing a Task (Online)

```
User taps task → Update local DB (isCompleted = true)
                        ↓
                  Update UI (instant)
                        ↓
                  Queue sync operation
                        ↓
                  Detect bingo (local)
                        ↓
                  Show celebration ✨
                        ↓
           (Background: Sync to Firestore)
                        ↓
           (Other devices pull changes)
```

**Timeline**:
- 0ms: User taps task
- 5ms: Local DB updated
- 5ms: UI shows completion ✨
- 8ms: Bingo detected (local algorithm)
- 8ms: Celebration animation starts 🎉
- Later: Syncs to Firestore
- Later: Other devices receive update

### Completing a Composite Task (Offline)

**Scenario**: User completes sub-task in composite task "(Exercise OR Yoga) AND (2 of [Meditate, Journal, Read])"

```
User completes "Exercise" task
  ↓
Update local DB (board_tasks: Exercise isCompleted = true)
  ↓
Detect composite tasks referencing "Exercise"
  ↓
Evaluate composite tree (recursive traversal)
  ├─ Check AND operator (root)
  │  ├─ Check OR operator (left child)
  │  │  ├─ Exercise: ✅ Complete
  │  │  └─ Yoga: ❌ Incomplete
  │  │  → OR result: ✅ True (at least one complete)
  │  └─ Check M_OF_N operator (right child, threshold=2)
  │     ├─ Meditate: ✅ Complete
  │     ├─ Journal: ✅ Complete
  │     └─ Read: ❌ Incomplete
  │     → M_OF_N result: ✅ True (2/3 complete, meets threshold)
  → AND result: ✅ True (both children complete)
  ↓
Auto-complete composite task
  ↓
Update board stats + detect bingo
  ↓
Queue sync operations
  ↓
UI updates (instant) ✨
```

**Timeline**:
- 0ms: User completes "Exercise"
- 5ms: Local DB updated (board_tasks)
- 8ms: Composite tree evaluated (< 50ms target)
- 8ms: Composite task auto-completed
- 10ms: Board stats updated
- 10ms: UI shows composite completion ✨
- Later: Syncs entire composite task tree to Firestore

### Multi-Device Sync

**Scenario**: User completes task on iPhone, views on web

**iPhone**:
```
Complete task → Update local GRDB → Update UI
                       ↓
                Queue sync operation
                       ↓
            (Background worker runs)
                       ↓
                Push to Firestore
```

**Web** (different device):
```
(Periodic pull sync runs every 5 min)
        ↓
Query Firestore for changes since lastSyncedAt
        ↓
Receive updated board_task
        ↓
Compare version (remote > local)
        ↓
Update local Dexie DB
        ↓
Update UI (task shows completed)
```

**Timeline**:
- T+0s: iPhone completes task (instant UI update)
- T+1s: iPhone syncs to Firestore
- T+5min: Web pulls changes from Firestore
- T+5min: Web UI updates (task completed)

## Database Schema Design

### Key Principles

1. **UUID Primary Keys**: Client-generated, enables offline creation
   ```typescript
   id: string;  // UUID (e.g., "550e8400-e29b-41d4-a716-446655440000")
   ```

2. **Version Fields**: Optimistic locking for conflict resolution
   ```typescript
   version: number;  // Incremented on each update
   ```

3. **Timestamps**: ISO8601 for consistency
   ```typescript
   createdAt: string;   // "2024-01-26T12:00:00.000Z"
   updatedAt: string;   // "2024-01-26T12:30:00.000Z"
   ```

4. **Soft Deletes**: Never hard delete (enables sync)
   ```typescript
   isDeleted: boolean;
   deletedAt?: string;
   ```

5. **Denormalized Stats**: Avoid joins for performance
   ```typescript
   completedTasks: number;      // Computed on update, not join
   completionPercentage: number; // Denormalized for instant reads
   ```

### Example: Board Table

```sql
-- SQLite (iOS GRDB)
CREATE TABLE boards (
    id TEXT PRIMARY KEY,              -- UUID
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    board_size INTEGER NOT NULL,

    -- Denormalized stats (instant reads)
    total_tasks INTEGER NOT NULL DEFAULT 0,
    completed_tasks INTEGER NOT NULL DEFAULT 0,
    completion_percentage REAL NOT NULL DEFAULT 0,

    created_at TEXT NOT NULL,         -- ISO8601
    updated_at TEXT NOT NULL,

    -- Sync metadata
    last_synced_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at TEXT
);

-- Indexes for performance
CREATE INDEX idx_boards_user_status ON boards(user_id, is_deleted);
CREATE INDEX idx_boards_updated_at ON boards(updated_at);
```

```typescript
// IndexedDB (Web Dexie)
const db = new Dexie('oybc');
db.version(1).stores({
  boards: '++id, userId, [userId+isDeleted], updatedAt'
  //       ^     ^       ^                   ^
  //       |     |       |                   |
  //       PK    Index   Compound index      Index (for sync queries)
});
```

## Performance Optimizations

### 1. Indexed Queries

```typescript
// ✅ FAST: Indexed query (< 10ms)
const boards = await db.boards
  .where('[userId+isDeleted]')
  .equals([currentUserId, false])
  .toArray();

// ❌ SLOW: Full table scan (50-100ms+)
const boards = await db.boards.toArray();
const filtered = boards.filter(b => b.userId === currentUserId && !b.isDeleted);
```

### 2. Batch Operations

```typescript
// ✅ FAST: Bulk insert (10-20ms for 25 tasks)
await db.boardTasks.bulkAdd(tasks);

// ❌ SLOW: Individual inserts (250ms for 25 tasks)
for (const task of tasks) {
  await db.boardTasks.add(task);
}
```

### 3. Denormalized Stats

```typescript
// ✅ FAST: Read denormalized stat (< 5ms)
const board = await db.boards.get(boardId);
console.log(board.completedTasks);  // Already computed

// ❌ SLOW: Count with join (20-50ms)
const completedTasks = await db.boardTasks
  .where('boardId')
  .equals(boardId)
  .and(bt => bt.isCompleted)
  .count();
```

### 4. Sync Batching

```typescript
// ✅ EFFICIENT: Batch 50 operations in one network call
const batch = await db.syncQueue.limit(50).toArray();
await syncBatchToFirestore(batch);

// ❌ INEFFICIENT: 50 individual network calls
for (const item of syncQueue) {
  await syncToFirestore(item);
}
```

## Offline Scenarios

### Airplane Mode

```
User enables airplane mode
        ↓
App continues working perfectly
        ↓
Create boards, complete tasks, get bingos
        ↓
All operations queue for sync
        ↓
User disables airplane mode
        ↓
Sync worker processes queue
        ↓
All changes sync to Firestore
        ↓
Other devices receive updates
```

### Poor Connection

```
User on slow 2G connection
        ↓
App reads from local DB (fast)
        ↓
Sync operations timeout
        ↓
Automatic retry with exponential backoff
        ↓
Eventually syncs when connection improves
        ↓
No data loss, no user frustration
```

### No Internet (Initial Install)

```
User installs app on subway (no internet)
        ↓
App launches successfully
        ↓
Can create account offline (queued)
        ↓
Can create boards offline
        ↓
Full functionality works
        ↓
Later: User gets internet
        ↓
Account syncs to Firebase Auth
        ↓
All boards sync to Firestore
        ↓
Multi-device sync enabled
```

## Benefits for OYBC

### 1. Instant Feedback

```typescript
// User completes task
await completeTask(taskId);  // < 10ms

// UI updates immediately
// ✨ Task marked complete
// ✨ Board stats update
// ✨ Bingo detection runs
// ✨ Celebration animation plays

// All before sync even starts!
```

### 2. Works on Subway

Many users will use OYBC on commutes (subway, airplane, remote areas). Offline-first ensures the app is always functional.

### 3. Battery Efficient

- No constant network polling
- Sync only when needed
- Batch operations reduce radio wake-ups

### 4. Cost Efficient

- Fewer Firestore reads/writes (batch operations)
- Delta sync (only changed fields)
- No redundant queries

### 5. Reliable

- No network errors blocking user
- Automatic retry with backoff
- Sync queue ensures no data loss

## Trade-offs

### Pros ✅

- Instant UX
- Works offline
- Reliable
- Battery efficient
- Cost efficient

### Cons ⚠️

- More complex architecture
- Conflict resolution needed
- Larger local storage
- Sync logic complexity
- Eventual consistency

**Verdict**: For OYBC, the pros **far outweigh** the cons. Users expect instant feedback when completing tasks, and offline functionality is essential for a productivity app.

## Comparison: Cloud-First vs Offline-First

| Feature | Cloud-First ❌ | Offline-First ✅ |
|---------|---------------|-----------------|
| Complete task | 100-500ms | < 10ms |
| Works offline | ❌ No | ✅ Yes |
| Loading spinners | ✅ Many | ❌ None |
| Network errors | ✅ Frequent | ❌ Rare |
| Battery life | ❌ Poor | ✅ Good |
| Multi-device | ✅ Easy | ⚠️ Requires sync |
| Complexity | ✅ Simple | ⚠️ Complex |
| Data consistency | ✅ Immediate | ⚠️ Eventual |

## Implementation Checklist

### Phase 1: Local-Only (Weeks 1-5)

- [x] Design database schema
- [ ] Implement local DB (GRDB, Dexie)
- [ ] Build UI (boards, tasks, grid)
- [ ] Test offline (airplane mode)
- [ ] Verify performance (< 10ms reads)

### Phase 2: Authentication (Week 6)

- [ ] Firebase Auth setup
- [ ] Associate data with userId
- [ ] Test multi-user isolation

### Phase 3: Sync Layer (Weeks 7-8)

- [ ] Implement sync queue
- [ ] Background sync worker
- [ ] Pull sync (fetch remote changes)
- [ ] Conflict resolution
- [ ] Test multi-device scenarios

### Phase 4: Polish (Weeks 9-12)

- [ ] Optimize sync batching
- [ ] Add retry logic
- [ ] Monitor sync errors
- [ ] Test edge cases (rapid offline/online switching)

## Testing Strategy

### Offline Tests

```typescript
describe('Offline functionality', () => {
  beforeEach(() => {
    // Mock offline
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
  });

  it('creates board offline', async () => {
    const board = await createBoard(input);
    expect(board.id).toBeDefined();

    // Verify saved locally
    const saved = await db.boards.get(board.id);
    expect(saved).toBeDefined();

    // Verify queued for sync
    const queued = await db.syncQueue
      .where('entityId')
      .equals(board.id)
      .first();
    expect(queued).toBeDefined();
  });

  it('completes task offline', async () => {
    await completeTask(taskId);

    // Verify updated locally
    const task = await db.boardTasks.get(taskId);
    expect(task.isCompleted).toBe(true);

    // Verify queued for sync
    const queued = await db.syncQueue
      .where('entityId')
      .equals(taskId)
      .first();
    expect(queued).toBeDefined();
  });
});
```

### Sync Tests

```typescript
describe('Sync functionality', () => {
  it('syncs changes when back online', async () => {
    // Create offline
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false);
    const board = await createBoard(input);

    // Verify queued
    const queued = await db.syncQueue.count();
    expect(queued).toBe(1);

    // Go online
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true);

    // Process sync
    await processSyncQueue();

    // Verify synced
    const remaining = await db.syncQueue
      .where('status')
      .equals(SyncStatus.PENDING)
      .count();
    expect(remaining).toBe(0);

    // Verify in Firestore
    const doc = await firestore.collection('boards').doc(board.id).get();
    expect(doc.exists).toBe(true);
  });
});
```

### Conflict Tests

```typescript
describe('Conflict resolution', () => {
  it('resolves conflicts with last-write-wins', async () => {
    // Device 1 offline: Edit board name
    const local: Board = {
      ...baseBoard,
      name: 'Device 1 Name',
      version: 2,
      updatedAt: '2024-01-26T12:00:00.000Z'
    };

    // Device 2 offline: Edit board name (later timestamp)
    const remote: Board = {
      ...baseBoard,
      name: 'Device 2 Name',
      version: 2,
      updatedAt: '2024-01-26T12:30:00.000Z'
    };

    // Resolve conflict
    const resolved = resolveConflict(local, remote);

    // Remote wins (newer timestamp)
    expect(resolved.name).toBe('Device 2 Name');
  });
});
```

## Resources

- [Offline First Design Principles](https://offlinefirst.org/)
- [Local-First Software](https://www.inkandswitch.com/local-first/)
- [GRDB Documentation](https://github.com/groue/GRDB.swift)
- [Dexie Documentation](https://dexie.org/)
- [Firebase Offline Capabilities](https://firebase.google.com/docs/firestore/manage-data/enable-offline)

## Summary

Offline-first architecture is **essential** for OYBC:

1. **Instant UX**: All operations < 10ms (local DB)
2. **Works offline**: Full functionality without internet
3. **Reliable**: No network errors, no loading spinners
4. **Multi-device**: Background sync for seamless experience
5. **Future-proof**: Scales to recurring boards, templates, etc.

The complexity is **worth it** for the dramatically better user experience.

**Next**: Read [CLAUDE_GUIDE.md](./CLAUDE_GUIDE.md) for implementation guidelines.
