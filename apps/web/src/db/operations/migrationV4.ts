import type { Transaction } from 'dexie';
import { db } from '../database';
import type {
  Task,
  TaskStep,
  BoardTask,
  Board,
  CompositeTask,
  CompositeNode,
  CompoundChild,
  SyncQueueItem,
  LegacyBoardTaskCompletion,
} from '@oybc/shared';
import {
  TaskType,
  SyncOperationType,
  SyncStatus,
  progressTaskToCompound,
  taskStepToCompoundChild,
  compositeTaskToTask,
  compositeNodeToCompoundChild,
  backfillTaskCompletion,
  collectEverCompletedStepIds,
  shouldBackfillStepLinkedTaskAsComplete,
  computeBoardStatsUpdate,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * Dexie v4 data migration. Runs inside the v4 upgrade callback, so all writes
 * here are part of one atomic transaction.
 *
 * Order matters because of foreign-key references:
 *   1. Convert progress Tasks (in place) to compound shape.
 *   2. Convert TaskSteps to compoundChildren rows (uses step.linkedTaskId
 *      which points at existing Task rows that are already in `tasks`).
 *   3. Convert CompositeTasks → new `tasks` rows (preserving id).
 *   4. Convert leaf CompositeNodes → compoundChildren rows.
 *   5. Backfill global completion on every Task using legacy BoardTask data.
 *   6. Backfill step-completion (TaskStep.id appearing in any
 *      BoardTask.completedStepIds → that step's linkedTaskId Task is complete).
 *   7. Enqueue legacy delete sync ops for every legacy doc.
 *   8. Recompute board stats (Phase 4 of the spec migration plan).
 *
 * Caller must pass the upgrade Transaction; uses `db` for table access since
 * Dexie shares the transaction context within the upgrade callback.
 *
 * @param _tx - The Dexie upgrade transaction (unused directly; Dexie binds all
 *              db table operations to the active transaction automatically).
 */
export async function runMigrationV4(_tx: Transaction): Promise<void> {
  const now = currentTimestamp();

  // ── 1. Progress Tasks → Compound ──────────────────────────────────────────
  const allTasks = await db.tasks.toArray();
  const progressTasks = allTasks.filter((t) => t.type === ('progress' as TaskType));
  for (const t of progressTasks) {
    const updates = progressTaskToCompound(t);
    await db.tasks.update(t.id, { ...updates, updatedAt: now });
  }

  // ── 2. TaskSteps → CompoundChildren ───────────────────────────────────────
  // Access the legacy taskSteps table. At runtime it still exists in IndexedDB
  // (v5 drops it); we cast through unknown to satisfy the TypeScript type since
  // the AppDatabase class still declares the property at v4.
  const taskStepsTable = (db as unknown as { taskSteps: { toArray(): Promise<TaskStep[]> } }).taskSteps;
  const allSteps: TaskStep[] = await taskStepsTable.toArray();
  for (const step of allSteps) {
    const row = taskStepToCompoundChild(step, generateUUID());
    if (!row) continue; // step missing linkedTaskId — skip defensively
    await db.compoundChildren.add(row);
  }

  // ── 3. CompositeTasks → Tasks ──────────────────────────────────────────────
  const allComposites: CompositeTask[] = await db.compositeTasks.toArray();
  const allCompositeNodes: CompositeNode[] = await db.compositeNodes.toArray();
  for (const ct of allComposites) {
    const root = allCompositeNodes.find((n) => n.id === ct.rootNodeId);
    const newTask = compositeTaskToTask(ct, root);
    if (!newTask) continue; // missing/malformed root — skip
    await db.tasks.add(newTask);
  }

  // ── 4. Leaf CompositeNodes → CompoundChildren ─────────────────────────────
  for (const node of allCompositeNodes) {
    const row = compositeNodeToCompoundChild(node, generateUUID());
    if (!row) continue; // operator node, or leaf without taskId/childCompositeTaskId
    await db.compoundChildren.add(row);
  }

  // ── 5. Backfill Task global completion from legacy BoardTask data ──────────
  // The legacy BoardTask rows still carry isCompleted/completedAt/currentCount/
  // completedStepIds at the storage level — Dexie doesn't enforce TS types at
  // runtime. Read them as `unknown` and cast to LegacyBoardTaskCompletion.
  const legacyBoardTasks: LegacyBoardTaskCompletion[] = (await db.boardTasks.toArray()).map((bt) => {
    const raw = bt as unknown as Record<string, unknown>;
    return {
      taskId: bt.taskId,
      isCompleted: raw['isCompleted'] === true,
      completedAt: raw['completedAt'] as string | undefined,
      currentCount: raw['currentCount'] as number | undefined,
      completedStepIds: raw['completedStepIds'] as string[] | undefined,
    };
  });

  /**
   * Enqueue a Task UPDATE sync entry so that backfilled completion state
   * propagates to Firestore (and wins over any stale pre-migration remote doc
   * on a second device that pulls later).
   *
   * Uses direct `db.syncQueue.add` — NOT `addToSyncQueue` — because we are
   * inside the Dexie upgrade transaction and that helper isn't tx-aware.
   */
  async function enqueueTaskUpdate(taskId: string): Promise<void> {
    const afterUpdate = await db.tasks.get(taskId);
    if (!afterUpdate) return;
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'tasks',
      entityId: taskId,
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify(afterUpdate),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  }

  // Re-fetch all tasks now that step 3 may have added composite-derived rows.
  // Two passes:
  //   1. Default-backfill `isCompleted: false` on EVERY task (incl. compound +
  //      unplaced primitives) so the post-migration Dexie row always has the
  //      field — pre-unification rows lacked it entirely, which would now
  //      skip pull validation under TaskSchema. Mirrors iOS's defensive
  //      `decodeIfPresent ?? false` decode.
  //   2. Apply legacy BoardTask-derived completion on top (primitives only;
  //      compound is always derived at query time, never stored).
  const tasksAfterStep3 = await db.tasks.toArray();
  for (const task of tasksAfterStep3) {
    // Pass 1 — defensive default for any task missing the field.
    if (task.isCompleted === undefined) {
      await db.tasks.update(task.id, { isCompleted: false, updatedAt: now });
    }

    // Pass 2 — completion backfill from legacy per-board state. Compound
    // tasks skip this pass: their completion is always derived live.
    if (task.type === TaskType.COMPOUND) continue;
    const rowsForTask = legacyBoardTasks.filter((r) => r.taskId === task.id);
    if (rowsForTask.length === 0) continue;
    const backfill = backfillTaskCompletion(rowsForTask);
    const updates: Partial<Task> = {
      isCompleted: backfill.isCompleted,
      completedAt: backfill.completedAt,
      updatedAt: now,
    };
    if (task.type === TaskType.COUNTING && backfill.currentCount !== undefined) {
      updates.currentCount = backfill.currentCount;
    }
    await db.tasks.update(task.id, updates);
    // Enqueue sync entry so the backfilled state reaches Firestore and won't be
    // overwritten by a second device pulling the stale pre-migration remote doc.
    if (backfill.isCompleted === true || backfill.currentCount !== undefined) {
      await enqueueTaskUpdate(task.id);
    }
  }

  // ── 6. Backfill step completion ────────────────────────────────────────────
  // Any TaskStep.id that ever appeared in any BoardTask.completedStepIds means
  // that step was completed on at least one board → flip its linkedTaskId Task
  // to globally complete.
  const everCompletedStepIds = collectEverCompletedStepIds(legacyBoardTasks);
  for (const step of allSteps) {
    if (!step.linkedTaskId) continue;
    if (!shouldBackfillStepLinkedTaskAsComplete(step, everCompletedStepIds)) continue;
    const linkedTask = await db.tasks.get(step.linkedTaskId);
    if (!linkedTask) continue;
    if (linkedTask.isCompleted) continue; // already set by step 5
    await db.tasks.update(step.linkedTaskId, {
      isCompleted: true,
      completedAt: linkedTask.completedAt ?? now,
      updatedAt: now,
    });
    // Enqueue sync entry for step-completion backfill.
    await enqueueTaskUpdate(step.linkedTaskId);
  }

  // ── 7. Enqueue legacy delete sync ops ─────────────────────────────────────
  // Write SyncQueueItem rows directly — do NOT use the addToSyncQueue helper
  // since it isn't transaction-aware and would open a new transaction, breaking
  // the atomicity guarantee of the upgrade callback.
  function makeLegacyDeleteItem(entityType: string, entityId: string): SyncQueueItem {
    return {
      id: generateUUID(),
      entityType,
      entityId,
      operationType: SyncOperationType.DELETE,
      payload: 'null',
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    };
  }

  for (const step of allSteps) {
    await db.syncQueue.add(makeLegacyDeleteItem('taskSteps', step.id));
  }
  for (const ct of allComposites) {
    await db.syncQueue.add(makeLegacyDeleteItem('compositeTasks', ct.id));
  }
  for (const node of allCompositeNodes) {
    await db.syncQueue.add(makeLegacyDeleteItem('compositeNodes', node.id));
  }

  // ── 8. Recompute board stats via the derivation pass ──────────────────────
  // Build the lookup maps the shared `computeBoardStatsUpdate` needs.
  const allTasksFinal: Task[] = await db.tasks.toArray();
  const taskById: Record<string, Task> = {};
  for (const t of allTasksFinal) taskById[t.id] = t;

  const allChildren: CompoundChild[] = await db.compoundChildren.toArray();
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    if (c.isDeleted) continue;
    (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  }

  const allBoardTasks: BoardTask[] = await db.boardTasks.toArray();
  const allBoards: Board[] = await db.boards.toArray();

  for (const board of allBoards) {
    if (board.isDeleted) continue;
    const boardTasksOnBoard = allBoardTasks.filter((bt) => bt.boardId === board.id);
    const update = computeBoardStatsUpdate(board, boardTasksOnBoard, childrenByCompound, taskById);
    const newVersion = (board.version ?? 0) + 1;
    await db.boards.update(board.id, {
      completedTasks: update.completedTasks,
      linesCompleted: update.linesCompleted,
      completedLineIds: update.completedLineIds,
      updatedAt: now,
      version: newVersion,
    });
    // Enqueue board update so Firestore reflects the recomputed stats.
    const updatedBoard: Board = {
      ...board,
      completedTasks: update.completedTasks,
      linesCompleted: update.linesCompleted,
      completedLineIds: update.completedLineIds,
      updatedAt: now,
      version: newVersion,
    };
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'boards',
      entityId: board.id,
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify(updatedBoard),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  }
}
