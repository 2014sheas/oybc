# OYBC Sync Strategy Documentation

> **Note (2026-04-30):** Sections #4 (Progress Task Step Sync) and #6 (Composite Task Sync) describe the **pre-unification** sync model. After the Compound Tasks Unification (PR #43, 2026-04-29) those two patterns collapsed into one: parent-child relationships live in a single `compound_children` table (with `compoundTaskId` for the parent and `childTaskId` for the child), and the parent's completion derives from its children via the operator/threshold stored on the parent `Task`. The `task_steps` and `composite_tasks`/`composite_nodes` tables were **removed in the progress-tasks teardown (Wave 2, 2026-08; PRs #411–#414)** — the iOS GRDB tables were dropped in migration v28, the Dexie stores were already dropped, and the legacy collections were removed from the sync contract. The LWW + version + Achievement Square + Bingo Line + User Preferences + Real-Time + Performance sections (everything else in this doc) remain accurate. For the current task model see [`TASK_SYSTEM.md`](TASK_SYSTEM.md).
>
> **Note (2026-07-08, amended by Windowed Completion):** Section #1 (**ProgressCounter Conflict Resolution**) is **superseded** — `ProgressCounter` was never revived; Shared Counters (Issue #84) shipped the per-Task `sharedCounterId`/`baseline` model instead. Its additive-merge sync design was itself later **retired by Windowed Completion** — counting conflicts now resolve by union-of-events on `task_events` (see [§Shared Counter Sync — current state (shipped)](#shared-counter-sync--current-state-shipped) and [`WINDOWED_COMPLETION.md`](./WINDOWED_COMPLETION.md)). `ProgressCounter` itself (types, tables, and `calculateCountingRollup`) was **removed in Wave 2 (PR #414, 2026-08)**. Section #1 is kept below as historical reference for the LWW-vs-additive reasoning (the "Strategy A vs Strategy B" framing). The D1/D3 sync-hardening work (dead-letter surfacing, per-entity queue coalescing) is still live; D2's `lastSyncedCount` advancement was removed with the merge.

## Overview

This document details the synchronization strategies for complex features in OYBC, including conflict resolution, cross-board tracking, and performance optimization for offline-first architecture.

---

## Table of Contents

1. [ProgressCounter Conflict Resolution](#progresscounter-conflict-resolution) — **superseded**, see #10
2. [Achievement Square Auto-Completion](#achievement-square-auto-completion)
3. [Cross-Board Queries](#cross-board-queries)
4. [Progress Task Step Sync](#progress-task-step-sync)
5. [Bingo Line Detection Sync](#bingo-line-detection-sync)
6. [Composite Task Sync](#composite-task-sync)
7. [User Preferences Sync](#user-preferences-sync)
8. [Real-Time Sync](#real-time-sync)
9. [Performance Considerations](#performance-considerations)
10. [Shared Counter Sync — current state (shipped)](#shared-counter-sync--current-state-shipped)

---

## ProgressCounter Conflict Resolution

> **Removed (Wave 2, 2026-08; PRs #411–#414).** `ProgressCounter` (its types, tables, and `calculateCountingRollup`) was never revived as a first-class entity and has now been removed entirely — the Dexie store was already dropped and the iOS GRDB table was dropped in migration v28. Counter-sharing shipped instead as the per-Task `sharedCounterId` model, and counting conflicts now resolve by union-of-events on `task_events` — see [§Shared Counter Sync — current state (shipped)](#shared-counter-sync--current-state-shipped) and [`WINDOWED_COMPLETION.md`](./WINDOWED_COMPLETION.md). The original LWW-vs-additive design is preserved in git history.

---

## Achievement Square Auto-Completion

### Problem Statement

Achievement squares track cross-board goals (e.g., "Complete 3 monthly bingos" on a yearly board). They must auto-complete when the goal is reached, requiring queries across multiple boards.

### Achievement Types

```typescript
type AchievementType = 'bingo' | 'full_completion';

interface AchievementSquare extends BoardTask {
  isAchievementSquare: true;
  achievementType: 'bingo' | 'full_completion';
  achievementCount: number;           // How many required (e.g., 3)
  achievementTimeframe: Timeframe;    // What to count (e.g., 'monthly')
  achievementProgress: number;        // Current count (denormalized)
}
```

**Example:**
- Yearly board with achievement square: "Complete 3 monthly bingos"
- `achievementType: 'bingo'`
- `achievementCount: 3`
- `achievementTimeframe: 'monthly'`
- `achievementProgress: 1` (updated as monthly boards complete)

---

### Implementation Strategy

#### Option 1: On-Demand Computation (Simpler)

**When to Update:**
- When viewing a board with achievement squares
- When completing a board (check if any achievements reference it)
- Manual sync button

**Implementation:**

```typescript
async function updateAchievementSquares(boardId: string) {
  const board = await db.boards.get(boardId);

  // Find all achievement squares on this board
  const achievementSquares = await db.boardTasks
    .where('boardId').equals(boardId)
    .and(bt => bt.isAchievementSquare === true)
    .toArray();

  for (const square of achievementSquares) {
    const progress = await computeAchievementProgress(square);

    // Update progress
    await db.boardTasks.update(square.id, {
      achievementProgress: progress,
      isCompleted: progress >= square.achievementCount,
      completedAt: progress >= square.achievementCount
        ? new Date().toISOString()
        : null,
      updatedAt: new Date().toISOString(),
      version: square.version + 1
    });
  }
}

async function computeAchievementProgress(square: AchievementSquare): Promise<number> {
  const userId = getCurrentUserId();

  if (square.achievementType === 'bingo') {
    // Count boards with at least one bingo
    const boards = await db.boards
      .where('[userId+isDeleted]').equals([userId, false])
      .and(b => b.timeframe === square.achievementTimeframe)
      .and(b => b.linesCompleted > 0)
      .toArray();

    return boards.length;

  } else if (square.achievementType === 'full_completion') {
    // Count fully completed boards
    const boards = await db.boards
      .where('[userId+isDeleted]').equals([userId, false])
      .and(b => b.timeframe === square.achievementTimeframe)
      .and(b => b.status === 'completed')
      .toArray();

    return boards.length;
  }

  return 0;
}
```

**Trigger Points:**

```typescript
// 1. After board completion
async function completeBoard(boardId: string) {
  // ... mark board as completed ...

  // Update any achievement squares that might reference this board
  await updateAllAchievementSquares();
}

// 2. After bingo line completion
async function onBingoLineComplete(boardId: string) {
  // ... update board.completedLineIds ...

  // Update achievements
  await updateAllAchievementSquares();
}

// 3. On board view
async function loadBoard(boardId: string) {
  const board = await db.boards.get(boardId);

  // Refresh achievement squares
  await updateAchievementSquares(boardId);

  return board;
}

// Update all boards with achievement squares
async function updateAllAchievementSquares() {
  const boardsWithAchievements = await db.boardTasks
    .where('isAchievementSquare').equals(true)
    .toArray();

  const uniqueBoardIds = [...new Set(boardsWithAchievements.map(bt => bt.boardId))];

  for (const boardId of uniqueBoardIds) {
    await updateAchievementSquares(boardId);
  }
}
```

**Pros:**
- Accurate (always recomputes from source)
- Simple logic
- No risk of drift

**Cons:**
- Slower (requires cross-board queries)
- May cause UI lag if many achievements

---

#### Option 2: Background Job (Faster, More Complex)

**When to Update:**
- Background sync process runs periodically
- After sync completes (all boards up-to-date)

**Implementation:**

```typescript
// Background sync job (runs every 30 seconds or on sync complete)
async function achievementSyncJob() {
  const now = Date.now();
  const lastRun = await getLastAchievementSyncTime();

  // Throttle: don't run more than once per 30 seconds
  if (now - lastRun < 30000) {
    return;
  }

  await updateAllAchievementSquares();
  await setLastAchievementSyncTime(now);
}

// Register job
setInterval(achievementSyncJob, 30000); // Every 30 seconds
```

**Pros:**
- Faster UI (achievements pre-computed)
- Doesn't block user interactions

**Cons:**
- More complex (requires background job infrastructure)
- Slight delay before achievements update
- Battery/performance impact on mobile

---

### Recommendation

**MVP:** Use **Option 1 (On-Demand Computation)**
- Update achievements when viewing board
- Update after board/bingo completion
- Fire-and-forget async (don't block UI)

**v1.1:** Consider **Option 2 (Background Job)** if:
- Achievement queries cause noticeable lag (>500ms)
- Users have many boards (>50)
- Battery impact is acceptable

---

### Sync Considerations

**Achievement Square Conflicts:**

Achievement squares should use **last-write-wins** since they're computed from source data:

```typescript
async function resolveAchievementConflict(local: BoardTask, remote: BoardTask) {
  // Always recompute from source rather than trusting stored value
  const correctProgress = await computeAchievementProgress(local as AchievementSquare);

  const resolved = {
    ...local,
    achievementProgress: correctProgress,
    isCompleted: correctProgress >= local.achievementCount,
    version: Math.max(local.version, remote.version) + 1,
    updatedAt: new Date().toISOString()
  };

  await db.boardTasks.put(resolved);
  await pushToFirestore(resolved);

  return resolved;
}
```

**Key Principle:** Achievement progress is **derived data**, not source data. Always recompute from board statuses rather than trusting synced values.

---

## Cross-Board Queries

### Required Query Patterns

#### 1. Count Bingos by Timeframe

```typescript
// Count monthly boards with at least one bingo
async function countBingos(timeframe: Timeframe): Promise<number> {
  const userId = getCurrentUserId();

  const boards = await db.boards
    .where('[userId+isDeleted]').equals([userId, false])
    .and(b => b.timeframe === timeframe)
    .and(b => b.linesCompleted > 0)
    .toArray();

  return boards.length;
}
```

**Required Index:** `[userId+isDeleted+timeframe+linesCompleted]` or compound index

---

#### 2. Count Completed Boards by Timeframe

```typescript
// Count monthly boards that are fully completed
async function countCompletedBoards(timeframe: Timeframe): Promise<number> {
  const userId = getCurrentUserId();

  const boards = await db.boards
    .where('[userId+isDeleted]').equals([userId, false])
    .and(b => b.timeframe === timeframe)
    .and(b => b.status === 'completed')
    .toArray();

  return boards.length;
}
```

**Required Index:** `[userId+isDeleted+timeframe+status]` or compound index

---

#### 3. Find All Achievement Squares

```typescript
// Find all boards with achievement squares (for bulk updates)
async function findBoardsWithAchievements(): Promise<string[]> {
  const achievementSquares = await db.boardTasks
    .where('isAchievementSquare').equals(true)
    .toArray();

  const boardIds = [...new Set(achievementSquares.map(bt => bt.boardId))];
  return boardIds;
}
```

**Required Index:** `isAchievementSquare`

---

#### 4. Get Progress for Specific Counter

```typescript
// Find all tasks linked to a progress counter (for recalculation)
async function findTasksUsingCounter(counterId: string): Promise<Task[]> {
  const tasks = await db.tasks
    .where('userId').equals(getCurrentUserId())
    .and(t => t.progressCounters?.some(pc => pc.counterId === counterId))
    .toArray();

  return tasks;
}
```

**Note:** This requires array search - may be slow without specialized index. Consider denormalizing to separate junction table if performance is poor.

---

### Index Strategy

**Required Indexes for Cross-Board Queries:**

> **Removed (Wave 2, 2026-08; PRs #411–#414):** the `taskSteps` / `progressCounters` Dexie stores, the `parentStepId` Task index, and the `task_steps` GRDB indexes below no longer exist — the progress/step model was torn down (Dexie stores already dropped; iOS GRDB tables dropped in migration v28). The snippets are kept as historical illustration of the pre-unification index strategy.

```typescript
// Dexie schema (pre-unification — retired stores/indexes shown for history)
const db = new Dexie('oybc');
db.version(1).stores({
  boards: 'id, [userId+isDeleted], [userId+timeframe+status], [userId+timeframe+linesCompleted], updatedAt',
  boardTasks: 'id, boardId, taskId, [boardId+isCompleted], isAchievementSquare, [isAchievementSquare+achievementTimeframe]',
  tasks: 'id, [userId+isDeleted], updatedAt, parentStepId', // parentStepId removed in Wave 2
  taskSteps: 'id, [taskId+stepIndex], linkedTaskId, [isDeleted+taskId]', // store removed in Wave 2
  progressCounters: 'id, [userId+isDeleted], updatedAt' // store removed in Wave 2
});
```

**iOS GRDB Indexes:**

```sql
-- Boards
CREATE INDEX idx_boards_user_deleted ON boards(userId, isDeleted);
CREATE INDEX idx_boards_user_timeframe_status ON boards(userId, timeframe, status);
CREATE INDEX idx_boards_user_timeframe_lines ON boards(userId, timeframe, linesCompleted);
CREATE INDEX idx_boards_updated ON boards(updatedAt);

-- BoardTasks
CREATE INDEX idx_board_tasks_board ON board_tasks(boardId);
CREATE INDEX idx_board_tasks_task ON board_tasks(taskId);
CREATE INDEX idx_board_tasks_achievement ON board_tasks(isAchievementSquare);
CREATE INDEX idx_board_tasks_achievement_timeframe ON board_tasks(isAchievementSquare, achievementTimeframe);

-- Tasks
CREATE INDEX idx_tasks_user_deleted ON tasks(userId, isDeleted);
-- idx_tasks_parent_step + the idx_task_steps_* indexes were removed in Wave 2
-- (progress/step model torn down; task_steps table dropped in GRDB migration v28)
```

---

## Progress Task Step Sync

> **Removed (Wave 2, 2026-08; PRs #411–#414).** The progress/step model (`task_steps` table, `TaskStep` type, `parentStepId`) was removed in the progress-tasks teardown — parent-child links now live in `compound_children`, synced by the standard per-row LWW path on `tasks` + `compound_children`. See [`TASK_SYSTEM.md`](TASK_SYSTEM.md) for the current model, and git history for the original step-sync design.

---

## Bingo Line Detection Sync

### Data Structure

Bingo lines are now denormalized into `Board.completedLineIds`:

```typescript
Board {
  completedLineIds: ['row_0', 'col_2', 'diag_0']
}
```

### Sync Strategy: Recompute on Conflict

Bingo lines are **derived data** - always recompute from task completion state:

```typescript
async function resolveBoardConflict(local: Board, remote: Board) {
  // Fetch all tasks for this board
  const boardTasks = await db.boardTasks
    .where('boardId').equals(local.id)
    .toArray();

  // Recompute bingo lines
  const completedLineIds = detectBingoLines(local.boardSize, boardTasks);

  const resolved = {
    ...local,
    completedLineIds,
    linesCompleted: completedLineIds.length,
    version: Math.max(local.version, remote.version) + 1,
    updatedAt: new Date().toISOString()
  };

  await db.boards.put(resolved);
  await pushToFirestore(resolved);

  return resolved;
}

function detectBingoLines(boardSize: number, boardTasks: BoardTask[]): string[] {
  const lines: string[] = [];
  const grid = createGrid(boardSize, boardTasks);

  // Check rows
  for (let row = 0; row < boardSize; row++) {
    if (isRowComplete(grid, row)) {
      lines.push(`row_${row}`);
    }
  }

  // Check columns
  for (let col = 0; col < boardSize; col++) {
    if (isColumnComplete(grid, col)) {
      lines.push(`col_${col}`);
    }
  }

  // Check diagonals
  if (isDiagonal1Complete(grid)) {
    lines.push('diag_0');
  }
  if (isDiagonal2Complete(grid)) {
    lines.push('diag_1');
  }

  return lines;
}
```

**Key Principle:** Never trust stored `completedLineIds` during conflict - always recompute from task completion grid.

---

## Composite Task Sync

> **Removed (Wave 2, 2026-08; PRs #411–#414).** The composite model (`composite_tasks` / `composite_nodes` / `board_composite_tasks` tables and the `CompositeTask` / `CompositeNode` types) was removed in the progress-tasks teardown — compounds live as ordinary `tasks` rows (`type='compound'`, with `operator` + `threshold`) and their parent-child links in `compound_children`, synced by the standard per-row LWW path. See [`TASK_SYSTEM.md`](TASK_SYSTEM.md) for the current model, and git history for the original tree-sync design.

---

## User Preferences Sync

### Overview

Synced user preferences live on the `User` record itself as a nested `preferences` object, so they replicate under the same last-write-wins resolver as every other synced entity — the last device to update a preference wins. The fields:

Core / board-creation defaults:

- `weekStartDay` — `'monday' | 'sunday'`
- `defaultBoardSize` — `3 | 4 | 5`
- `defaultCenterType` — `FREE | NONE` (narrowed from `CenterSquareType`; CHOSEN requires per-board context)
- `defaultTimeframe` — `daily | weekly | monthly | yearly | custom`
- `defaultRandomize` — `boolean`
- `theme` — `'light' | 'dark' | 'system'`

Recurring boards (Phase 6.1): `recurringDailyEnabled` / `recurringWeeklyEnabled` / `recurringMonthlyEnabled` / `recurringYearlyEnabled` — `boolean` (default true).

Board Preferences (Riso 5a): `expiringReminders` — `boolean` (default true). (This field originated here in 5a as a dead toggle and became live in Phase 7 as the expiry-notification gate — it's a 5a field, not a Phase 7 one. The other three original 5a fields are gone: `autoArchiveCompleted` was removed as a never-consumed dead pref — see the obsolete-controls removal — and `celebrationIntensity` / `haptics` were removed for the same reason, since neither was ever meant to be user-configurable. `UserPreferencesSchema` still accepts (and silently strips) those two keys on an old cached/synced record — Zod's default `z.object()` behavior — rather than rejecting the whole payload.)

Notifications (Phase 7): `notificationsEnabled` — `boolean` (default false); `recurringWindowReminders` — `boolean` (default true); `dailyPlayReminderEnabled` — `boolean` (default false); `dailyPlayReminderTime` — `string` `"HH:mm"` (default `"20:00"`).

These all ride the existing user-prefs LWW path — **no new collection**. Notifications are scheduled per-device from the synced prefs; there is no cross-device de-duplication problem because delivery is **local** to each device and the scheduled identifiers are deterministic (`expiry-<boardId>` etc.), so each device independently converges on the same desired set. A prefs change on one device replicates and the other device's next reconcile (on app-open) picks it up. (Phase 7 is iOS-only at the feature level; web round-trips the fields but does not act on them yet — see CLAUDE.md §Notifications.)

All newer fields are `.optional()` in `UserPreferencesSchema` and filled by `mergeUserPreferences()` on the pull path, so an older peer's prefs doc never fails validation.

### Firestore Layout

Unlike other syncable entities which live in `users/{userId}/<collection>/{id}` subcollections, the `User` document is the scope root at `users/{userId}` and holds the synced preferences directly:

```
users/{userId}                              ← User doc (profile + preferences)
users/{userId}/boards/{boardId}             ← subcollection entities
users/{userId}/tasks/{taskId}
…
```

### Sync Path

1. **Write**: `updateUserPreferences(...)` (web: `db/operations/users.ts`, iOS: `AppDatabase.updateUserPreferences`) merges the partial update, bumps `version` + `updatedAt`, and enqueues a `users` sync-queue UPDATE inside a single transaction.
2. **Push**: `pushSync` special-cases `entityType === 'users'` to write to `users/{userId}` directly (not a subcollection child). `DELETE` ops for `users` are a no-op — the scope root must never be removed.
3. **Pull**: `pullSync` fetches `users/{userId}` first, LWW-merges against the local row, then iterates the subcollections as before. The local `lastSyncedAt` watermark is preserved through a remote-wins pull.
4. **Conflict resolution**: identical to every other entity — higher `version` wins, ties break on `updatedAt`.

### Checklist

- [ ] Preference change on Device A reaches Device B after a sync loop round-trip.
- [ ] Concurrent change on both devices within one window → higher-version side wins on both devices.
- [ ] Records predating the `preferences` field decode cleanly (defaults fill missing keys on read).
- [ ] `users` entity is never DELETE-synced (scope root safety).

---

## Real-Time Sync

### Overview

The sync layer used to be polling-only: a 30-second `setInterval` drove a `fullSync` cycle (push every pending queue item, then pull every collection). That meant local writes sat for up to 30 s before reaching Firestore, and remote changes from another device sat for up to 30 s before pull.

The current design is event-driven on both sides, with the polling loop kept as a slow safety net.

> **The safety-net loop is load-bearing — never remove it as an "optimization."** The pull watermark is a *local-clock* ISO string compared against server `_syncedAt`, so a clock-skew window exists by design: a doc written during the skew can slip past the watermark, and the periodic re-pull (5 min; `SYNC_SAFETY_NET_MS` on web, `safetyNetInterval` on iOS — both sites carry matching DO-NOT-REMOVE comments) is the only mechanism that recovers it, in addition to its FAILED-retry and stale-IN_PROGRESS duties.

### Push side — push-on-enqueue

- `addToSyncQueue` (web: `apps/web/src/db/operations/syncQueue.ts`; iOS: `AppDatabase.saveSyncItem`) is unchanged and remains fire-and-forget.
- The sync orchestrator subscribes to a local-DB observation of the PENDING queue count:
  - **Web**: Dexie `liveQuery(() => db.syncQueue.where('status').equals(SyncStatus.PENDING).count())` inside `startSyncLoop`.
  - **iOS**: GRDB `ValueObservation.tracking { db in try SyncQueueItem.filter(...).fetchCount(db) }` started in `SyncService.start(userId:)`.
- On any non-zero emission the orchestrator schedules a debounced `pushSync` (500 ms window). Repeated enqueues coalesce.
- The existing `isSyncing` guard is the concurrency lock; the queue observation re-fires as items drain, so nothing is lost if a push is mid-flight when debounce fires.

### Pull side — Firestore `onSnapshot` listeners

- One listener on the parent `users/{userId}` doc (no filter, single document).
- One listener per syncable subcollection at `users/{userId}/<collection>`, filtered by `where('_syncedAt', '>', lastSyncedAt)` so initial attach only delivers deltas since the last safety-net watermark advance.
- Each handler routes incoming docs through the same `applyRemoteUserDoc` / `applyRemoteSubdoc` helpers that the safety-net `pullSync` uses — all incoming-write logic is unified.
- Echo behaviour: the device that pushed a write also receives the snapshot back. The LWW resolver picks "remote" by `updatedAt` tiebreaker but the local upsert is idempotent (same data, no real change). Listener handlers skip the log line when local-wins so the event log doesn't fill with echoes.

### Safety-net interval

- 5-minute `setInterval` on web (exported as `SYNC_SAFETY_NET_MS`); equivalent `_Concurrency.Task` sleep loop on iOS.
- Three jobs:
  1. Reset stale IN_PROGRESS rows from a crashed tab / force-quit.
  2. Retry items left in FAILED that no fresh enqueue has bumped.
  3. Back-stop the rare missed snapshot delivery (network flap, listener detach race).

### Lifecycle

- **Web**: `useSyncLoop` mounts `startSyncLoop(userId)` on sign-in; cleanup detaches all listeners + cancels the interval + unsubscribes the queue observation.
- **iOS**: `AuthService` owns a `SyncService` instance and calls `.start(userId:)` / `.stop()` from the Firebase auth state handler. `AuthGateView` injects the same instance via `@EnvironmentObject` so the playground dashboard observes its `@Published` state.

### Watermark normalization

Both platforms now query Firestore by `_syncedAt` (server-assigned timestamp) instead of `updatedAt`. iOS previously used `updatedAt` which races on clock skew; the unification matches web.

### Checklist

- [ ] Local write reaches Firestore within ~1 s on both platforms.
- [ ] Cross-device pull lands within ~1 s of the originating push.
- [ ] Force-quit during push leaves IN_PROGRESS rows that the next safety-net tick (or app relaunch) recovers.
- [ ] Sign-out detaches every listener + cancels every timer (no orphaned reads in DevTools / Xcode network panel).
- [ ] Two devices editing the same record concurrently still resolve via the standard LWW path (no new conflict surface from the listener handlers).

---

## Performance Considerations

### Query Performance Targets

- **Single board load:** < 50ms
- **Cross-board achievement query:** < 200ms
- **Sync conflict resolution:** < 100ms per entity
- **Background achievement update:** < 500ms total

### Optimization Strategies

#### 1. Batch Updates

```typescript
// Good: Batch updates
async function updateMultipleBoards(updates: Array<{id: string, data: Partial<Board>}>) {
  await db.transaction('rw', db.boards, async () => {
    for (const {id, data} of updates) {
      await db.boards.update(id, data);
    }
  });
}

// Bad: Individual updates
for (const update of updates) {
  await db.boards.update(update.id, update.data); // Separate transaction each time
}
```

#### 2. Denormalize Hot Paths

Already denormalized:
- ✅ `Board.completedLineIds` (avoid join with BingoLine table)
- ✅ `Board.totalTasks`, `completedTasks`, `linesCompleted` (instant stats)
- ✅ `BoardTask.achievementProgress` (avoid recalculation on every load)

#### 3. Lazy Load Achievement Updates

```typescript
// Don't block UI - update in background
async function onBoardComplete(boardId: string) {
  // Mark complete immediately
  await db.boards.update(boardId, {
    status: 'completed',
    completedAt: new Date().toISOString()
  });

  // Update achievements asynchronously (fire-and-forget)
  setTimeout(() => updateAllAchievementSquares(), 0);
}
```

#### 4. Index Wisely

**Over-indexing hurts write performance.** Only index fields used in `where()` clauses:

```typescript
// Good: Indexed query
db.boards.where('[userId+isDeleted]').equals([userId, false])

// Bad: Sequential scan (if not indexed)
db.boards.filter(b => b.userId === userId && !b.isDeleted)
```

---

## Summary

### Key Sync Strategies

| Feature | Strategy | Conflict Resolution | Performance |
|---------|----------|---------------------|-------------|
| **Shared Counters** (shipped; supersedes the ProgressCounter row this table used to have) | Additive three-way merge via `lastSyncedCount` | `sharedCounterMerge` — see [§Shared Counter Sync](#shared-counter-sync--current-state-shipped) | Fast |
| **Achievement Squares** | Recompute from source | Always recompute | Medium (200ms) |
| **Task Step Linking** (removed Wave 2, PRs #411–#414 — see [`TASK_SYSTEM.md`](./TASK_SYSTEM.md) for the current `compound_children` model) | — (entity removed) | — | — |
| **Bingo Lines** | Recompute from grid | Detect from task states | Fast |

### Implementation Priority

> **Note:** the `ProgressCounter` and step-completion items below are historical — `ProgressCounter` and the progress/step model were removed in Wave 2 (PRs #411–#414); counter-sharing shipped as the per-Task `sharedCounterId` model.

**MVP (Must Have):**
1. ✅ Last-write-wins for ProgressCounter *(entity removed Wave 2)*
2. ✅ On-demand achievement updates (when viewing board)
3. ✅ Step completion propagation *(step model removed Wave 2)*
4. ✅ Bingo line recomputation

**v1.1 (Nice to Have):**
- Additive conflict resolution for ProgressCounter *(entity removed Wave 2)*
- Background job for achievement updates
- Advanced indexing optimizations
- Conflict resolution telemetry

### Testing Checklist

- [ ] Two devices complete different steps of same progress task → merge correctly
- [ ] Two devices increment same counter offline → last-write-wins (accept potential loss)
- [ ] Complete monthly bingo → yearly achievement updates correctly
- [ ] Complete task linked to step → all parent progress tasks update
- [ ] Two devices complete same board offline → bingo lines recompute correctly
- [ ] Sync with 50+ boards → achievement queries complete in <200ms
- [ ] Rapid task completions → no UI lag or race conditions

---

## Next Steps

1. ~~Implement sync strategies in iOS GRDB layer~~ DONE
2. ~~Implement sync strategies in web Dexie layer~~ DONE
3. Add unit tests for conflict resolution logic
4. Add integration tests for cross-board queries
5. Performance benchmarking with realistic data volumes
6. Add telemetry for sync conflict frequency (inform v1.1 priorities)

---

## Implementation Notes

This section documents what was actually implemented for the sync layer (Phase 3).

### Conflict Resolver

- **Web**: `conflictResolver.ts` implements the LWW conflict resolution logic
- **iOS**: Conflict resolution is inline in `SyncService.swift`

### Resolution Rules

1. Higher `version` wins
2. Same `version`: newer `updatedAt` wins
3. Tie on both: remote wins
4. Same `version` with an empty/unparseable `updatedAt` on either side: remote wins (canon pinned in `lwwVectors.json`, issue #263 — production never emits such timestamps; defensive)

### Push Sync

- Read the remote Firestore document
- Compare local vs remote using the resolution rules above
- Write to Firestore only if local wins
- Sync queue items are processed sequentially (not batched yet)

### Pull Sync

- Query Firestore by `_syncedAt > lastSyncedAt` watermark
- For each remote document, compare against local using the resolution rules
- Upsert into local DB if remote wins
- `lastSyncedAt` watermark is only advanced after an error-free pull cycle

### Known Limitations

- **TOCTOU race in push**: The read-then-write pattern during push is not atomic. Another device could write between the read and write. Production should use Firestore transactions to close this window.
- **No schema validation on pulled data**: Remote documents are trusted as-is during pull. Malformed or unexpected fields are not validated before upserting into the local DB.
- **`merge: true` can leave stale fields**: Using Firestore's `merge: true` option means deleted or renamed fields on the local side may persist in the remote document as stale data.

---

## Shared Counter Sync — current state (shipped)

This section is the current-state supersession of §1 (ProgressCounter Conflict Resolution). Shared Counters (Issue #84, both platforms) shipped a per-Task model instead of reviving `ProgressCounter` — see [`TASK_SYSTEM.md` §Shared counters](./TASK_SYSTEM.md#shared-counters-linked-counting-tasks) for the data model (`sharedCounterId` / `baseline` on `Task`) and [`SHARED_COUNTERS.md`](./SHARED_COUNTERS.md) for the UX. This section covers only the sync-conflict machinery, including the D-track (Track D, `docs/ROADMAP.md`) hardening that shipped after the initial engine.

> **RETIRED by Windowed Completion (SHIPPED — [`docs/WINDOWED_COMPLETION.md`](./WINDOWED_COMPLETION.md)).** The additive-merge machinery below (`sharedCounterMerge` / `additiveMergeCount` / `needsAdditiveMerge` + the `lastSyncedCount` ancestor-advance stamping) **no longer exists** — its code, tests, and cross-platform fixture (`sharedCounterMergeVectors.json`) were deleted in WC PR B (neutered) + D (removed). Counting-task conflicts now resolve by **union-of-events** on the `task_events` collection (see [§Task Events sync](#task-events-sync-windowed-completion--shipped) below): every offline increment is its own soft-deletable row, so per-row LWW + union loses nothing without a three-way merge. The `lastSyncedCount` column/field is kept **inert** on both platforms for decode compatibility with old synced rows. The three subsections that follow are **historical** — read them for the LWW-vs-additive reasoning only; the D1/D3 hardening (dead-letter surfacing, queue coalescing) is still live, but D2's `lastSyncedCount` advance is gone (pushes just mark the queue item completed).

### Task Events sync (Windowed Completion — shipped)

`task_events` (Dexie `taskEvents`, GRDB `task_events`, Firestore `users/{uid}/taskEvents`) is the collection that replaced additive merge. It joins the known-collections list on both platforms (`SYNC_COLLECTIONS` in `@oybc/shared`, enforced by the C4 sync-contract fixture) with matching owner-only `firestore.rules`. Conflict model: **per-row LWW + soft-delete tombstones, union by id** — exactly like `compoundChildren`. There is no cross-row merge; the only mutable bit worth racing is `isDeleted` (an undo racing a no-op), and LWW on it is acceptable. On pull, event-owning tasks' lifetime caches (`isCompleted` / `currentCount` / `completedAt`) are **recomputed from the converged event union** (batched once per task per pull cycle, no `version` bump), and sealed boards' frozen snapshots **re-derive locally** from the same union whenever an in-window event lands — so seal snapshots never LWW-race between devices. See [`WINDOWED_COMPLETION.md` §Sync](./WINDOWED_COMPLETION.md#sync) for the batched-recompute + pull-ordering details.

### Additive merge via `lastSyncedCount` (three-way merge) — HISTORICAL / retired

Plain LWW on `Task.currentCount` would lose increments: if device A pushes `count=6` and device B (offline, started from the same base) later pushes `count=7`, LWW picks one and silently drops the other device's log. Shared counters instead run a three-way merge keyed on `lastSyncedCount` — the counter's value as of the last successful push (the common ancestor both devices last agreed on):

```
needsAdditiveMerge = local.currentCount ≠ lastSyncedCount AND remote.currentCount ≠ lastSyncedCount
mergedCount = remote.currentCount + (local.currentCount - lastSyncedCount)   // when both diverged from the ancestor
```

If only one side diverged from `lastSyncedCount`, that side's value is simply authoritative (no real conflict — the "conflict" is just one device catching up). The merge function *was* `sharedCounterMerge` (`sharedCounterMerge.ts`, Swift twin `SharedCounterMerge.swift`), fixture-tested against both platforms (Track C1, 21 vectors). **All three files, plus the `sharedCounterMergeVectors.json` fixture and their tests, were deleted in WC PR D** — the paragraph above documents how the retired mechanism worked, not current behavior.

### D2 — reliable `lastSyncedCount` advancement (issue #294) — RETIRED

D2 folded the queue-item completion and the `lastSyncedCount` advance into one transaction so the ancestor couldn't half-advance and silently degrade the next conflict to LWW. **This is gone** (Windowed Completion): with additive merge retired there is no ancestor to advance, so the push path just marks the queue item completed (`markSyncItemCompleted` / `markCompleted`). The `completePushedItem` / `completePushedItemLoud` / `countAdvanceForPush` plumbing was deleted in WC PR D. Kept here only so the issue-#294 history resolves.

### D3 — per-entity PENDING queue coalescing (issue #296, shipped)

Before D3, N edits to one task enqueued N full-snapshot sync-queue rows → N Firestore writes, widening the blast radius of any single-item failure. D3 added `coalesceSyncOperation` (`apps/web/src/db/operations/syncQueue.ts`, Swift twin `SyncQueueBuilder.coalesce`): when a PENDING row already exists for the same `(entityType, entityId)`, a new enqueue **replaces** its payload + operation type in place (keeping the original row's queue position) instead of appending a second row. IN_PROGRESS and FAILED rows are never coalesced into — only a second PENDING enqueue is eligible.

Op-precedence table (rows = existing PENDING op, cols = incoming op):

| existing ↓ / incoming → | CREATE | UPDATE | DELETE |
| --- | --- | --- | --- |
| **CREATE** | CREATE | CREATE | DROP* / DELETE |
| **UPDATE** | CREATE | UPDATE | DELETE |
| **DELETE** | CREATE (resurrection) | UPDATE (resurrection) | DELETE |

\* DROP only when the existing row was never attempted (`lastAttemptAt` unset — proves the server never saw the entity, so a create-then-delete nets to nothing anywhere); otherwise the row becomes a DELETE tombstone (harmless to push even if the doc doesn't exist server-side, whereas dropping it risks orphaning a live remote doc). DELETE+CREATE/UPDATE "resurrection" case: an un-pushed tombstone is stale next to a newer, higher-version live snapshot — pushing the live snapshot under LWW is correct in one write, no ordering dependency.

### D1 — dead-letter surfacing for exhausted retries (issue #292, shipped)

Previously a queue item that exhausted `MAX_SYNC_RETRIES` (5) sat FAILED forever with only a `console.warn` — invisible to the user, and Firestore never learned of the change (slow, silent multi-device divergence). D1 made this observable and recoverable on both platforms:

- Both platforms track an `exhaustedCount` (FAILED items past the retry cap) alongside the existing sync-status state.
- The web `SyncStatusIndicator` and iOS's minimal sync row (`RisoSyncRow.swift` / `SyncSheet.swift`) show a plain-count "N changes couldn't sync" affordance with a **Retry** button when `exhaustedCount > 0` — no raw error text, keeping the #151 three-state-row minimalism.
- Tapping Retry (`retryExhaustedSyncItems()` web, mirrored iOS) resets the exhausted rows' `retryCount` to 0 and re-promotes them to PENDING, then kicks an immediate sync.
- **Network-regain auto-re-promote**: exhausted items also get exactly one free re-promote the moment connectivity returns (`online` event listener), without the user needing to tap Retry manually.

### Interaction summary

| Concern | Mechanism | Where |
| --- | --- | --- |
| Lost increments across concurrent offline edits | **Union-of-events** on `task_events` (per-row LWW + tombstones) — *replaced* the retired additive three-way merge | `taskEvents.ts` / `AppDatabase+TaskEvents.swift`; see [§Task Events sync](#task-events-sync-windowed-completion--shipped) |
| Queue bloat from edit bursts | D3 — per-entity PENDING coalescing | `syncQueue.ts` `coalesceSyncOperation` / `SyncQueueBuilder.coalesce` |
| Permanently-stuck items | D1 — exhausted-count UI + Retry + network-regain re-promote | `SyncStatusIndicator.tsx` / `RisoSyncRow.swift`, `retryExhaustedSyncItems` |

---

## Recurring Boards sync (Phase 6 — shipped)

> **Status (2026-07-08):** all of Phase 6 (6.1 timeframe banners, 6.2 preset-pool templates, 6.3 Achievement) is shipped on both platforms — see CLAUDE.md §Recurring Boards. The "Phase 2 will add…" / "Phase 3 extends…" language below is retained verbatim because the sync design it describes is exactly what shipped (the `recurring_board_templates` table / `referencedBoardId` field), just no longer future tense in practice.

Recurring Boards Phase 1 introduces **no new sync collections**. The 4 new boolean fields on `UserPreferences` (`recurringDailyEnabled`, `recurringWeeklyEnabled`, `recurringMonthlyEnabled`, `recurringYearlyEnabled`) ride the existing user-prefs sync — same LWW resolution, same conflict-resolution code path, same forward-compatible decoder pattern. Detection of pending recurring boards is computed at read time from existing `boards` data; no persistence required, no sync footprint.

A peer running an older client decodes the user doc successfully (the new fields fall through to `false` defaults via `mergeUserPreferences()` and the Swift `UserPreferences.init(from:)` mirror). A write from the older client drops the new fields — no data loss, since absence implies the default value.

**Phase 2 (preset-pool boards)** will add a new Firestore subcollection `users/{uid}/recurringBoardTemplates` (camelCase, matching the convention used by `boardTasks` / `compoundChildren`). The local SQLite table is `recurring_board_templates` (snake_case). Versioning, LWW resolution, and soft-delete tombstone semantics mirror `boards` exactly. The collection name is added to the sync service's known-collections list; no new conflict-resolution logic is required.

**Phase 3 (board-completion-as-a-square)** extends achievement squares with one new optional field — `referencedBoardId` — on the existing `boardTasks` Firestore subcollection (local SQLite table: `board_tasks`). No new collection, no schema migration to a different table. Cross-board cascade fires inside the existing `runBoardCascadeForTask()` pipeline by adding a parallel fan-out for board_tasks rows with `referencedBoardId = this.id`; no new sync paths are added.

For the canonical design, see [`docs/ARCHITECTURE.md` §Phase 6](./ARCHITECTURE.md#phase-6-recurring-boards--shipped).
