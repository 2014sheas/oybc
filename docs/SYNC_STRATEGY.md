# OYBC Sync Strategy Documentation

> **Note (2026-04-30):** Sections #4 (Progress Task Step Sync) and #6 (Composite Task Sync) describe the **pre-unification** sync model. After the Compound Tasks Unification (PR #43, 2026-04-29) those two patterns collapsed into one: parent-child relationships live in a single `compound_children` table (with `compoundTaskId` for the parent and `childTaskId` for the child), and the parent's completion derives from its children via the operator/threshold stored on the parent `Task`. The `task_steps` and `composite_tasks`/`composite_nodes` tables still appear in old schema migrations so first-launch backfill works on dev/test devices, but receive no live writes and are not read by any UI. The LWW + version + ProgressCounter + Achievement Square + Bingo Line + User Preferences + Real-Time + Performance sections (everything else in this doc) remain accurate. For the current task model see [`TASK_SYSTEM.md`](TASK_SYSTEM.md).

## Overview

This document details the synchronization strategies for complex features in OYBC, including conflict resolution, cross-board tracking, and performance optimization for offline-first architecture.

---

## Table of Contents

1. [ProgressCounter Conflict Resolution](#progresscounter-conflict-resolution)
2. [Achievement Square Auto-Completion](#achievement-square-auto-completion)
3. [Cross-Board Queries](#cross-board-queries)
4. [Progress Task Step Sync](#progress-task-step-sync)
5. [Bingo Line Detection Sync](#bingo-line-detection-sync)
6. [Composite Task Sync](#composite-task-sync)
7. [User Preferences Sync](#user-preferences-sync)
8. [Real-Time Sync](#real-time-sync)
9. [Performance Considerations](#performance-considerations)

---

## ProgressCounter Conflict Resolution

### Problem Statement

When users work offline on multiple devices and increment the same ProgressCounter (e.g., "Pages Read"), conflicts arise during sync. Two strategies are available:

### Strategy A: Last-Write-Wins (LWW) - **RECOMMENDED FOR MVP**

**How It Works:**
- Each update increments the `version` field
- During sync, compare versions: highest version wins
- Simpler implementation, already supported by schema

**Implementation:**

```typescript
// Local update
async function incrementCounter(counterId: string, increment: number) {
  const counter = await db.progressCounters.get(counterId);

  await db.progressCounters.update(counterId, {
    currentValue: counter.currentValue + increment,
    version: counter.version + 1,
    updatedAt: new Date().toISOString()
  });

  // Queue for sync
  await syncQueue.add({
    entityType: 'progress_counter',
    entityId: counterId,
    operationType: 'UPDATE'
  });
}

// Sync conflict resolution (LWW)
async function resolveCounterConflict(local: ProgressCounter, remote: ProgressCounter) {
  if (remote.version > local.version) {
    // Remote wins - accept remote value
    await db.progressCounters.put(remote);
    return remote;
  } else if (local.version > remote.version) {
    // Local wins - push to server
    await pushToFirestore(local);
    return local;
  } else {
    // Same version (rare) - use latest timestamp
    const winner = new Date(remote.updatedAt) > new Date(local.updatedAt)
      ? remote
      : local;
    await db.progressCounters.put(winner);
    await pushToFirestore(winner);
    return winner;
  }
}
```

**Pros:**
- Simple to implement
- Works with existing version field
- Fast conflict resolution
- Predictable behavior

**Cons:**
- May lose progress if devices sync out of order
- Example: Device A adds 10, Device B adds 5. If B syncs first, then A syncs, final value is 10 (should be 15)

---

### Strategy B: Additive Conflict Resolution - **FUTURE (v1.1)**

**How It Works:**
- Track deltas (changes) instead of absolute values
- During sync, sum all deltas from both devices
- Requires additional tracking table

**Schema Extension (Future):**

```typescript
interface ProgressCounterDelta {
  id: string;                    // UUID
  counterId: string;             // FK to progress_counters
  deviceId: string;              // Device identifier
  delta: number;                 // Amount added/subtracted
  createdAt: string;             // When delta was created
  syncedAt?: string;             // When synced to server
}
```

**Implementation:**

```typescript
// Local update (tracking deltas)
async function incrementCounter(counterId: string, increment: number) {
  const counter = await db.progressCounters.get(counterId);

  // Create delta record
  await db.progressCounterDeltas.add({
    id: generateUUID(),
    counterId,
    deviceId: getDeviceId(),
    delta: increment,
    createdAt: new Date().toISOString()
  });

  // Update local counter
  await db.progressCounters.update(counterId, {
    currentValue: counter.currentValue + increment,
    updatedAt: new Date().toISOString()
  });

  // Queue for sync
  await syncQueue.add({
    entityType: 'progress_counter_delta',
    entityId: counterId,
    operationType: 'CREATE'
  });
}

// Sync conflict resolution (Additive)
async function resolveCounterConflict(local: ProgressCounter, remote: ProgressCounter) {
  // Fetch all unsynced deltas from both sides
  const localDeltas = await db.progressCounterDeltas
    .where('counterId').equals(local.id)
    .and(delta => !delta.syncedAt)
    .toArray();

  const remoteDeltas = await fetchRemoteDeltas(remote.id);

  // Merge deltas
  const allDeltas = [...localDeltas, ...remoteDeltas];
  const uniqueDeltas = deduplicateById(allDeltas);

  // Compute correct value from base + all deltas
  const baseValue = Math.min(local.currentValue, remote.currentValue);
  const totalDelta = uniqueDeltas.reduce((sum, d) => sum + d.delta, 0);
  const correctValue = baseValue + totalDelta;

  // Update both local and remote
  await db.progressCounters.update(local.id, {
    currentValue: correctValue,
    updatedAt: new Date().toISOString()
  });

  await pushToFirestore({
    ...local,
    currentValue: correctValue,
    updatedAt: new Date().toISOString()
  });

  // Mark deltas as synced
  await markDeltasSynced(uniqueDeltas);
}
```

**Pros:**
- No progress is ever lost
- Mathematically correct cumulative tracking
- Handles complex multi-device scenarios

**Cons:**
- More complex implementation
- Requires additional storage (delta table)
- Slower conflict resolution (must fetch/compute deltas)
- Requires periodic cleanup of old deltas

---

### Recommendation

**MVP:** Use **Strategy A (Last-Write-Wins)**
- Simpler to implement and test
- Good enough for single-device or infrequent multi-device usage
- Can upgrade to Strategy B in v1.1 if users report sync issues

**v1.1:** Consider **Strategy B (Additive)** if:
- Users frequently work offline on multiple devices
- Progress tracking is critical (fitness apps, reading logs)
- Data loss complaints arise

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

```typescript
// Dexie schema
const db = new Dexie('oybc');
db.version(1).stores({
  boards: 'id, [userId+isDeleted], [userId+timeframe+status], [userId+timeframe+linesCompleted], updatedAt',
  boardTasks: 'id, boardId, taskId, [boardId+isCompleted], isAchievementSquare, [isAchievementSquare+achievementTimeframe]',
  tasks: 'id, [userId+isDeleted], updatedAt, parentStepId',
  taskSteps: 'id, [taskId+stepIndex], linkedTaskId, [isDeleted+taskId]',
  progressCounters: 'id, [userId+isDeleted], updatedAt'
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
CREATE INDEX idx_tasks_parent_step ON tasks(parentStepId);

-- TaskSteps
CREATE INDEX idx_task_steps_task_index ON task_steps(taskId, stepIndex);
CREATE INDEX idx_task_steps_linked ON task_steps(linkedTaskId);
CREATE INDEX idx_task_steps_deleted ON task_steps(isDeleted, taskId);
```

---

## Progress Task Step Sync

> **Pre-unification (2026-04-30):** This entire section describes the legacy `task_steps` table and the per-`BoardTask` completion model. Both have been retired. In the current model, parent-child links live in `compound_children`; completion is global on the parent `Task`. The "all steps are tasks" principle below still holds — children of a compound parent are themselves rows in the `tasks` table — but the linking happens via `compound_children.compoundTaskId` + `childTaskId`, not via `task_steps.progressTaskId` + `stepTaskId`. Sync is unchanged: child Tasks and parent Tasks both go through the standard LWW path on `tasks`; `compound_children` rows sync independently. See [`TASK_SYSTEM.md`](TASK_SYSTEM.md) for the current schema.

### Key Design: All Steps Are Tasks

**Critical**: Progress task steps are NOT embedded data - they are **always tasks** in the `tasks` table. The `task_steps` table only stores structure (order and relationships).

### Data Relationships

```typescript
// Progress task (parent)
Task {
  id: 'prog-1',
  type: 'progress',
  title: 'Clean House'
}

// Step structure (references tasks, NO data)
TaskStep {
  id: 'step-1',
  progressTaskId: 'prog-1',     // Parent progress task
  stepIndex: 0,                  // Order
  stepTaskId: 'task-456'         // The step's task (ALWAYS set)
  // NO title, type, action, unit, maxCount - data comes from task
}

// Step task (standalone task)
Task {
  id: 'task-456',
  type: 'normal',
  title: 'Vacuum living room'
  // No back-reference needed
}

// Completion state (per-board)
BoardTask {
  boardId: 'board-a',
  taskId: 'prog-1',              // Progress task on board
  isCompleted: false
}

BoardTask {
  boardId: 'board-a',
  taskId: 'task-456',            // Step task on board
  isCompleted: true              // Completing this triggers progress check
}
```

### Sync Strategy: Independent Entity Sync

**Key Principle**: Sync `tasks`, `task_steps`, and `board_tasks` independently. No special linking logic needed.

**Sync Order**:
1. **tasks** table first (both progress tasks and step tasks)
2. **task_steps** table next (structure only)
3. **board_tasks** table last (completion state per board)

```typescript
// Pull sync order
async function pullAllUpdates() {
  // 1. Pull tasks (includes progress tasks and step tasks)
  await pullTasks();

  // 2. Pull task steps (structure)
  await pullTaskSteps();

  // 3. Pull board tasks (completion state)
  await pullBoardTasks();

  // 4. After all data pulled, check progress task completion
  await recheckAllProgressTasks();
}

async function pullTasks() {
  const remoteTasks = await firestore
    .collection('tasks')
    .where('userId', '==', getCurrentUserId())
    .where('updatedAt', '>', lastSyncTimestamp)
    .get();

  for (const doc of remoteTasks.docs) {
    const remoteTask = doc.data();
    const localTask = await db.tasks.get(remoteTask.id);

    if (!localTask || remoteTask.version > localTask.version) {
      await db.tasks.put(remoteTask);
    }
  }
}

async function pullTaskSteps() {
  const remoteSteps = await firestore
    .collection('task_steps')
    .where('updatedAt', '>', lastSyncTimestamp)
    .get();

  for (const doc of remoteSteps.docs) {
    const remoteStep = doc.data();
    const localStep = await db.taskSteps.get(remoteStep.id);

    if (!localStep || remoteStep.version > localStep.version) {
      await db.taskSteps.put(remoteStep);
    }
  }
}

async function pullBoardTasks() {
  const remoteBoardTasks = await firestore
    .collection('board_tasks')
    .where('updatedAt', '>', lastSyncTimestamp)
    .get();

  for (const doc of remoteBoardTasks.docs) {
    const remote = doc.data();
    const local = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([remote.boardId, remote.taskId])
      .first();

    if (!local || remote.version > local.version) {
      await db.boardTasks.put(remote);
    }
  }
}
```

### Progress Task Completion Check

**When to check**: After any step task completes on a board.

```typescript
async function completeStepTask(boardId: string, stepTaskId: string) {
  // 1. Mark step task complete
  const boardTask = await db.boardTasks
    .where(['boardId', 'taskId'])
    .equals([boardId, stepTaskId])
    .first();

  await db.boardTasks.update(boardTask.id, {
    isCompleted: true,
    completedAt: currentTimestamp(),
    version: boardTask.version + 1
  });

  // 2. Find progress tasks that include this step
  const progressSteps = await db.taskSteps
    .where('stepTaskId')
    .equals(stepTaskId)
    .toArray();

  // 3. Check completion for each progress task
  for (const step of progressSteps) {
    await checkProgressTaskCompletion(boardId, step.progressTaskId);
  }
}

async function checkProgressTaskCompletion(boardId: string, progressTaskId: string) {
  // Get all steps for this progress task
  const steps = await db.taskSteps
    .where('progressTaskId')
    .equals(progressTaskId)
    .and(s => !s.isDeleted)
    .toArray();

  // Check if each step task is complete on this board
  let allComplete = true;
  for (const step of steps) {
    const stepBoardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, step.stepTaskId])
      .first();

    if (!stepBoardTask?.isCompleted) {
      allComplete = false;
      break;
    }
  }

  // If all steps complete, mark progress task complete
  if (allComplete) {
    const progressBoardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, progressTaskId])
      .first();

    if (progressBoardTask && !progressBoardTask.isCompleted) {
      await db.boardTasks.update(progressBoardTask.id, {
        isCompleted: true,
        completedAt: currentTimestamp(),
        version: progressBoardTask.version + 1
      });

      await updateBoardStats(boardId);
    }
  }
}
```

### Conflict Resolution

**No special conflict resolution needed** - each table syncs independently with last-write-wins:

1. **tasks table**: Standard LWW based on version field
2. **task_steps table**: Standard LWW based on version field (structure rarely changes)
3. **board_tasks table**: Standard LWW based on version field

**Example Conflict**:

```typescript
// Device A: Completes step task on Board 1
Device A: board_tasks { boardId: 'board-1', taskId: 'step-task-1', isCompleted: true, version: 2 }

// Device B: Also completes same step task on Board 1
Device B: board_tasks { boardId: 'board-1', taskId: 'step-task-1', isCompleted: true, version: 2 }

// Resolution: Both have same result, higher version or newer timestamp wins (doesn't matter)
// No data loss because completion state is the same
```

**Cross-Board Independence**: Each board has independent completion state, so no conflicts across boards:

```typescript
// Device A: Completes step task on Board 1
board_tasks { boardId: 'board-1', taskId: 'step-task-1', isCompleted: true }

// Device B: Completes same step task on Board 2
board_tasks { boardId: 'board-2', taskId: 'step-task-1', isCompleted: true }

// No conflict - different boards, independent state
```

### Benefits of This Sync Strategy

1. **Simpler**: No special linking logic, just standard entity sync
2. **Consistent**: Same pattern as other entities (boards, tasks, board_tasks)
3. **Atomic**: Each entity syncs independently, no partial states
4. **Scalable**: No complex merge logic, just LWW per entity
5. **Clear**: Completion state always in board_tasks, never duplicated

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

> **Pre-unification (2026-04-30):** This entire section describes the legacy `composite_tasks` + `composite_nodes` + `board_composite_tasks` model. After the Compound Tasks Unification (PR #43, 2026-04-29) compounds live as ordinary `tasks` rows (`type='compound'`, with `operator` + `threshold` + `isOrdered` columns) and parent-child links live in `compound_children`. The "tree integrity" concern below largely dissolves: there is no separate root vs. node distinction, no separate junction table for board-level placement, and completion is global per `Task` rather than per-board. Sync is the standard LWW path on `tasks` plus independent LWW on `compound_children`. The conflict-resolution patterns below are preserved as historical reference for how the legacy tree-based sync worked. See [`TASK_SYSTEM.md`](TASK_SYSTEM.md) for the current schema.

### Problem Statement

Composite tasks represent tree structures with operators (AND/OR/M_OF_N) and leaf nodes (task references). Syncing these trees across devices requires special handling to maintain tree integrity and prevent partial updates.

### Data Structure

```typescript
// Root composite task
CompositeTask {
  id: string;
  userId: string;
  title: string;
  rootNodeId: string;  // FK to composite_nodes (root of tree)
  version: number;
}

// Tree nodes (operators and leaf references)
CompositeNode {
  id: string;
  compositeTaskId: string;
  parentNodeId?: string;
  nodeIndex: number;
  nodeType: 'operator' | 'leaf';

  // Operator node fields
  operatorType?: 'AND' | 'OR' | 'M_OF_N';
  threshold?: number;

  // Leaf node field (always task reference after auto-conversion)
  taskId?: string;  // FK to tasks table

  version: number;
}

// Board-level completion state
BoardCompositeTask {
  id: string;
  boardId: string;
  compositeTaskId: string;
  isCompleted: boolean;
  completedAt?: string;
  version: number;
}
```

### Sync Strategy: Atomic Tree Operations

**Key Principle**: Sync entire composite task trees atomically (all nodes or none) to prevent partial tree corruption.

#### Pull Sync (Fetch from Firestore)

```typescript
async function pullCompositeTaskTree(compositeTaskId: string) {
  // 1. Fetch composite task
  const remoteTask = await firestore
    .collection('compositeTasks')
    .doc(compositeTaskId)
    .get();

  // 2. Fetch all nodes for this composite task
  const remoteNodes = await firestore
    .collection('compositeNodes')
    .where('compositeTaskId', '==', compositeTaskId)
    .where('isDeleted', '==', false)
    .get();

  // 3. Replace local tree atomically (transaction)
  await db.transaction('rw', [db.compositeTasks, db.compositeNodes], async () => {
    // Delete old nodes
    await db.compositeNodes
      .where('compositeTaskId')
      .equals(compositeTaskId)
      .delete();

    // Insert remote task and nodes
    await db.compositeTasks.put(remoteTask.data());
    await db.compositeNodes.bulkPut(remoteNodes.docs.map(d => d.data()));
  });
}
```

#### Push Sync (Send to Firestore)

```typescript
async function pushCompositeTaskTree(compositeTaskId: string) {
  // 1. Fetch local task and nodes
  const localTask = await db.compositeTasks.get(compositeTaskId);
  const localNodes = await db.compositeNodes
    .where('compositeTaskId')
    .equals(compositeTaskId)
    .toArray();

  // 2. Push to Firestore atomically (batch)
  const batch = firestore.batch();

  batch.set(
    firestore.collection('compositeTasks').doc(localTask.id),
    localTask
  );

  localNodes.forEach(node => {
    batch.set(
      firestore.collection('compositeNodes').doc(node.id),
      node
    );
  });

  await batch.commit();
}
```

### Conflict Resolution

**Strategy**: Last-write-wins at composite task level (not individual nodes).

```typescript
async function resolveCompositeTaskConflict(
  local: CompositeTask,
  remote: CompositeTask
) {
  // Compare versions
  if (remote.version > local.version) {
    // Remote wins - pull entire tree
    await pullCompositeTaskTree(remote.id);
    return remote;

  } else if (local.version > remote.version) {
    // Local wins - push entire tree
    await pushCompositeTaskTree(local.id);
    return local;

  } else {
    // Same version - use timestamp tiebreaker
    const winner = new Date(remote.updatedAt) > new Date(local.updatedAt)
      ? remote
      : local;

    if (winner === remote) {
      await pullCompositeTaskTree(remote.id);
    } else {
      await pushCompositeTaskTree(local.id);
    }

    return winner;
  }
}
```

**Why Not Node-Level Merging?**

Node-level conflict resolution (merging individual node changes) is too complex and error-prone:
- Tree structure dependencies make partial merges dangerous
- Operator changes can invalidate child nodes
- Parent-child relationships can break during partial sync
- MVP uses simpler atomic tree sync (entire tree wins)

**Future Enhancement (v1.1)**: Operational transformation for concurrent tree edits.

### Board Composite Task Completion Sync

Completion state for composite tasks on boards follows standard BoardTask pattern:

```typescript
async function syncBoardCompositeTask(boardCompositeTaskId: string) {
  const local = await db.boardCompositeTasks.get(boardCompositeTaskId);
  const remote = await firestoreGet(`boardCompositeTasks/${boardCompositeTaskId}`);

  // Last-write-wins
  if (remote.version > local.version) {
    await db.boardCompositeTasks.put(remote);
  } else if (local.version > remote.version) {
    await firestorePut(`boardCompositeTasks/${boardCompositeTaskId}`, local);
  } else {
    // Timestamp tiebreaker
    const winner = new Date(remote.updatedAt) > new Date(local.updatedAt)
      ? remote
      : local;
    await db.boardCompositeTasks.put(winner);
    await firestorePut(`boardCompositeTasks/${boardCompositeTaskId}`, winner);
  }
}
```

### Auto-Created Task Sync

When users create "inline" tasks in composite tree builder, they're automatically converted to real tasks:

```typescript
async function createCompositeNodeWithAutoTask(
  input: CreateCompositeNodeInput
) {
  if (input.nodeType === 'leaf' && input.autoCreateTask) {
    // 1. Create real task first
    const newTask = await db.tasks.add({
      id: generateUUID(),
      userId: getCurrentUserId(),
      title: input.autoCreateTask.title,
      type: input.autoCreateTask.type,
      // ... other fields
    });

    // 2. Queue task for sync
    await syncQueue.enqueue({
      entityType: 'task',
      entityId: newTask.id,
      operationType: 'CREATE',
      payload: newTask
    });

    // 3. Create composite node referencing the task
    return {
      id: generateUUID(),
      nodeType: 'leaf',
      taskId: newTask.id,  // Reference to auto-created task
      // ... other fields
    };
  }
}
```

Auto-created tasks sync like any other task (standard task sync strategy).

### Performance Considerations

**Tree Size Limits**:
- Recommend max 20 nodes per composite task (soft limit)
- Recommend max 5 nesting levels (soft limit)
- Validation can enforce limits to prevent performance issues

**Sync Batch Size**:
- Single composite task tree = 1 root + N nodes
- Firestore batch limit = 500 operations
- Max ~400 nodes per composite task (leaves room for metadata)

**Evaluation Performance**:
- Target: < 50ms for 20-node tree
- Cache evaluation results per board
- Invalidate cache when sub-tasks complete

### Edge Cases

#### Deleted Task References

When a task referenced by a composite node is deleted:

```typescript
async function evaluateLeafNode(
  node: CompositeNode,
  boardId: string
) {
  if (node.taskId) {
    const task = await db.tasks.get(node.taskId);

    // Deleted task → always incomplete
    if (task?.isDeleted) {
      return false;
    }

    // Check completion on board
    const boardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, node.taskId])
      .first();

    return boardTask?.isCompleted ?? false;
  }

  return false;
}
```

UI shows warning: "⚠️ Referenced task deleted" with option to replace.

#### Circular References

Prevented at creation time:

```typescript
async function validateNoCircularReferences(
  input: CreateCompositeTaskInput
) {
  const visited = new Set<string>();
  await checkNodeForCircularReferences(input.rootNode, visited, db);
}

async function checkNodeForCircularReferences(
  nodeInput: CreateCompositeNodeInput,
  visited: Set<string>,
  db: DatabaseInstance
) {
  if (nodeInput.nodeType === 'leaf' && nodeInput.taskId) {
    // Check if already visited (circular reference)
    if (visited.has(nodeInput.taskId)) {
      throw new Error(`Circular reference detected: task ${nodeInput.taskId}`);
    }

    visited.add(nodeInput.taskId);

    // Check if referenced task is itself a composite task
    const compositeTask = await db.compositeTasks
      .where('id')
      .equals(nodeInput.taskId)
      .first();

    if (compositeTask) {
      // Recursively check composite task tree
      // ... validation logic
    }
  }

  // Recursively check children
  if (nodeInput.children) {
    for (const child of nodeInput.children) {
      await checkNodeForCircularReferences(child, new Set(visited), db);
    }
  }
}
```

### Testing Checklist

- [ ] Create composite task offline → syncs to Firestore when online
- [ ] Modify composite task on Device A → Device B pulls changes → tree updates correctly
- [ ] Delete composite task → soft delete syncs → removed from other devices
- [ ] Conflict scenario: Edit tree on two devices offline → LWW resolves correctly
- [ ] Large tree (20 nodes) syncs in < 500ms
- [ ] Auto-created tasks sync independently of composite task
- [ ] Deleted task reference → evaluation handles gracefully
- [ ] Circular reference → validation prevents creation

---

## User Preferences Sync

### Overview

Synced user preferences live on the `User` record itself as a nested `preferences` object, so they replicate under the same last-write-wins resolver as every other synced entity — the last device to update a preference wins. The fields:

Core / board-creation defaults:

- `weekStartDay` — `'monday' | 'sunday'`
- `defaultBoardSize` — `3 | 4 | 5`
- `defaultCenterType` — `FREE | NONE` (narrowed from `CenterSquareType`; CHOSEN / CUSTOM_FREE require per-board context)
- `defaultTimeframe` — `daily | weekly | monthly | yearly | custom`
- `defaultRandomize` — `boolean`
- `defaultCenterCustomName` — `string` (≤ 100 chars)
- `theme` — `'light' | 'dark' | 'system'`

Recurring boards (Phase 6.1): `recurringDailyEnabled` / `recurringWeeklyEnabled` / `recurringMonthlyEnabled` / `recurringYearlyEnabled` — `boolean` (default true).

Board Preferences (Riso 5a): `celebrationIntensity` — `number` 1–10 (default 7); `haptics` — `boolean`; `expiringReminders` — `boolean` (default true); `autoArchiveCompleted` — `boolean`. (`expiringReminders` originated here in 5a as a dead toggle and became live in Phase 7 as the expiry-notification gate — it's a 5a field, not a Phase 7 one.)

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
| **ProgressCounter** | Last-write-wins (MVP) | Version field comparison | Fast |
| **Achievement Squares** | Recompute from source | Always recompute | Medium (200ms) |
| **Task Step Linking** | Additive merge | Union of completedStepIds | Fast |
| **Bingo Lines** | Recompute from grid | Detect from task states | Fast |

### Implementation Priority

**MVP (Must Have):**
1. ✅ Last-write-wins for ProgressCounter
2. ✅ On-demand achievement updates (when viewing board)
3. ✅ Step completion propagation
4. ✅ Bingo line recomputation

**v1.1 (Nice to Have):**
- Additive conflict resolution for ProgressCounter
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

## Recurring Boards sync (Phase 6 — planned)

Recurring Boards Phase 1 introduces **no new sync collections**. The 4 new boolean fields on `UserPreferences` (`recurringDailyEnabled`, `recurringWeeklyEnabled`, `recurringMonthlyEnabled`, `recurringYearlyEnabled`) ride the existing user-prefs sync — same LWW resolution, same conflict-resolution code path, same forward-compatible decoder pattern. Detection of pending recurring boards is computed at read time from existing `boards` data; no persistence required, no sync footprint.

A peer running an older client decodes the user doc successfully (the new fields fall through to `false` defaults via `mergeUserPreferences()` and the Swift `UserPreferences.init(from:)` mirror). A write from the older client drops the new fields — no data loss, since absence implies the default value.

**Phase 2 (preset-pool boards)** will add a new Firestore subcollection `users/{uid}/recurringBoardTemplates` (camelCase, matching the convention used by `boardTasks` / `compoundChildren`). The local SQLite table is `recurring_board_templates` (snake_case). Versioning, LWW resolution, and soft-delete tombstone semantics mirror `boards` exactly. The collection name is added to the sync service's known-collections list; no new conflict-resolution logic is required.

**Phase 3 (board-completion-as-a-square)** extends achievement squares with one new optional field — `referencedBoardId` — on the existing `boardTasks` Firestore subcollection (local SQLite table: `board_tasks`). No new collection, no schema migration to a different table. Cross-board cascade fires inside the existing `runBoardCascadeForTask()` pipeline by adding a parallel fan-out for board_tasks rows with `referencedBoardId = this.id`; no new sync paths are added.

For the canonical design, see [`docs/ARCHITECTURE.md` §Phase 6](./ARCHITECTURE.md#phase-6-recurring-boards-in-design).
