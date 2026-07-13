import { db } from '../internal';
import type {
  Task,
} from '@oybc/shared';
import { BoardStatus, SyncOperationType, TaskType, propagateIncrement } from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTask } from './orchestration';
import { insertIncrementEventRaw } from './taskEvents';

/**
 * Phase 3 — Shared Counters increment hot-path.
 *
 * Increments the source task's `currentCount` by `by` (default 1), then
 * re-derives every linked task (tasks where `sharedCounterId === sourceTaskId`
 * and `!isDeleted`) and runs the board derivation cascade for the source AND
 * every linked task — all inside one Dexie transaction.
 *
 * Invariants enforced:
 *   - NO HIGH-END CLAMP on the source's `currentCount`. Overshoot is intentional.
 *   - ONE-WAY LATCH on each linked task's `isCompleted`: once `true`, stays
 *     `true` regardless of the re-derived value.
 *   - All writes (task rows + board cascade + sync entries) are atomic. A
 *     partial failure rolls back everything.
 *
 * Callers must NOT call this for a linked (derived) task — pass the source
 * task's id. A linked task's `sharedCounterId` points at the source; tapping
 * a linked task on a board should call `incrementSharedCounter` with the
 * source id, not the linked id.
 *
 * @param sourceTaskId - The id of the source (template) task whose `currentCount`
 *   is the shared accumulator.
 * @param by - Amount to increment (default 1). Must be a positive integer.
 */
/** Resolved board reference returned by the shared-counter engine. */
export interface AffectedBoard {
  boardId: string;
  boardName: string;
}

export async function incrementSharedCounter(
  sourceTaskId: string,
  by = 1,
): Promise<{ affectedBoards: AffectedBoard[] }> {
  if (by <= 0 || !Number.isInteger(by)) throw new Error('incrementSharedCounter: `by` must be a positive integer');

  return db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch and validate the source task.
      const source = await db.tasks.get(sourceTaskId);
      if (!source || source.isDeleted) return { affectedBoards: [] };
      if (source.type !== TaskType.COUNTING) {
        throw new Error(
          `incrementSharedCounter: source task ${sourceTaskId} is not a COUNTING task`,
        );
      }
      // Source must NOT be a linked task itself (it must be the accumulator).
      if (source.sharedCounterId != null) {
        throw new Error(
          `incrementSharedCounter: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
        );
      }

      // 2. Compute new source count — NO high-end clamp (overshoot is intentional).
      if (source.maxCount == null) {
        throw new Error(
          `incrementSharedCounter: source task ${sourceTaskId} has null/undefined maxCount — data integrity error`,
        );
      }
      const newSourceCount = (source.currentCount ?? 0) + by;
      const sourceMaxCount = source.maxCount;

      // isCompleted: one-way latch. Source uses a simpler logic than derived tasks:
      // the source tracks its own maxCount independently. We apply the latch here too.
      const sourceWasCompleted = source.isCompleted;
      const sourceNowCompleted = sourceWasCompleted || newSourceCount >= sourceMaxCount;

      const updatedSource: Partial<Task> = {
        currentCount: newSourceCount,
        isCompleted: sourceNowCompleted,
        completedAt: !sourceWasCompleted && sourceNowCompleted ? now : source.completedAt,
        updatedAt: now,
        version: (source.version ?? 0) + 1,
      };
      await db.tasks.update(sourceTaskId, updatedSource);
      // Enqueue sync for the source task.
      const savedSource = await db.tasks.get(sourceTaskId);
      if (savedSource) {
        await addToSyncQueue('tasks', sourceTaskId, SyncOperationType.UPDATE, savedSource, 0);
      }

      // Windowed Completion (docs §Write paths — "incrementSharedCounter …
      // becomes append-event-on-source + propagation-stamp of derived tasks").
      // Append a +by increment event on the SOURCE only (derived tasks are
      // carved out — they never own events). Raw append, no cache restamp: the
      // source's lifetime `currentCount` is already written authoritatively
      // above and equals the lifetime event sum.
      await insertIncrementEventRaw(sourceTaskId, by, undefined, now);

      // 3. Find all linked (derived) tasks for this source.
      const linkedTasks = await db.tasks
        .filter((t) => !t.isDeleted && t.sharedCounterId === sourceTaskId)
        .toArray();

      // 4. Compute propagation results using the pure shared helper.
      const propagationResults = propagateIncrement(
        { currentCount: newSourceCount },
        linkedTasks.map((t) => ({
          id: t.id,
          baseline: t.baseline,
          maxCount: t.maxCount,
          isCompleted: t.isCompleted,
        })),
      );

      // 5. Write each linked task's new state + enqueue its sync entry.
      for (const result of propagationResults) {
        const linkedTask = linkedTasks.find((t) => t.id === result.taskId);
        if (!linkedTask) continue;

        const wasCompleted = linkedTask.isCompleted;
        const nowCompleted = result.newIsCompleted;

        const linkedPatch: Partial<Task> = {
          currentCount: result.newCurrentCount,
          isCompleted: nowCompleted,
          completedAt: !wasCompleted && nowCompleted ? now : linkedTask.completedAt,
          updatedAt: now,
          version: (linkedTask.version ?? 0) + 1,
        };
        await db.tasks.update(result.taskId, linkedPatch);
        const savedLinked = await db.tasks.get(result.taskId);
        if (savedLinked) {
          await addToSyncQueue('tasks', result.taskId, SyncOperationType.UPDATE, savedLinked, 0);
        }
      }

      // 6. Collect ACTIVE boards containing the source + any linked task BEFORE the
      //    cascade rewrites board stats/status. This is the set used for the credited
      //    toast — the boards that "also counted" this increment.
      const allChangedTaskIds = [sourceTaskId, ...linkedTasks.map((t) => t.id)];
      const placements = await db.boardTasks
        .where('taskId').anyOf(allChangedTaskIds)
        .toArray();
      const uniqueBoardIds = [...new Set(placements.map((p) => p.boardId))];
      const boardRows = uniqueBoardIds.length > 0
        ? await db.boards.where('id').anyOf(uniqueBoardIds).toArray()
        : [];
      const affectedBoards: AffectedBoard[] = boardRows
        .filter((b) => !b.isDeleted && b.status === BoardStatus.ACTIVE)
        .map((b) => ({ boardId: b.id, boardName: b.name }));

      // 7. Run the board derivation cascade for the source AND each linked task.
      // The cascade reads from the already-updated task rows (same transaction),
      // so board stats, bingo lines, and completion flags are all recomputed
      // with the fresh counts in one pass.
      for (const taskId of allChangedTaskIds) {
        await runBoardCascadeForTask(taskId);
      }

      return { affectedBoards };
    },
  );
}
/**
 * Decrement the shared-counter accumulator for a given source task id.
 *
 * Mirrors `incrementSharedCounter` with the following differences:
 *   - `eff = min(by, source.currentCount)` — cannot go below 0.
 *   - If `eff === 0` → no-op, returns `{ affectedBoards: [], effectiveDelta: 0 }`.
 *   - ONE-WAY COMPLETION LATCH is preserved: decrement does NOT un-complete any
 *     task — once `isCompleted` is true it stays true. This is consistent with the
 *     increment engine.
 *
 * Returns the DISTINCT live ACTIVE boards containing any member task of the group,
 * and the `effectiveDelta` (positive integer = actual units removed, 0 on no-op).
 *
 * Callers must pass the SOURCE task's id (same rule as `incrementSharedCounter`).
 *
 * @param sourceTaskId - The id of the source (template) task whose `currentCount`
 *   is the shared accumulator.
 * @param by - Amount to decrement (default 1). Must be a positive integer.
 */
export async function decrementSharedCounter(
  sourceTaskId: string,
  by = 1,
): Promise<{ affectedBoards: AffectedBoard[]; effectiveDelta: number }> {
  if (by <= 0 || !Number.isInteger(by)) throw new Error('decrementSharedCounter: `by` must be a positive integer');

  return db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch and validate the source task.
      const source = await db.tasks.get(sourceTaskId);
      if (!source || source.isDeleted) return { affectedBoards: [], effectiveDelta: 0 };
      if (source.type !== TaskType.COUNTING) {
        throw new Error(
          `decrementSharedCounter: source task ${sourceTaskId} is not a COUNTING task`,
        );
      }
      if (source.sharedCounterId != null) {
        throw new Error(
          `decrementSharedCounter: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
        );
      }

      // 2. Compute effective delta — clamp to what the source actually holds.
      const currentCount = source.currentCount ?? 0;
      const eff = Math.min(by, currentCount);
      if (eff === 0) return { affectedBoards: [], effectiveDelta: 0 };

      if (source.maxCount == null) {
        throw new Error(
          `decrementSharedCounter: source task ${sourceTaskId} has null/undefined maxCount — data integrity error`,
        );
      }

      const newSourceCount = currentCount - eff;

      // 3. ONE-WAY LATCH: decrement does NOT un-complete.
      const sourceWasCompleted = source.isCompleted;
      const sourceNowCompleted = sourceWasCompleted || newSourceCount >= source.maxCount;

      const updatedSource: Partial<Task> = {
        currentCount: newSourceCount,
        isCompleted: sourceNowCompleted,
        completedAt: !sourceWasCompleted && sourceNowCompleted ? now : source.completedAt,
        updatedAt: now,
        version: (source.version ?? 0) + 1,
      };
      await db.tasks.update(sourceTaskId, updatedSource);
      const savedSource = await db.tasks.get(sourceTaskId);
      if (savedSource) {
        await addToSyncQueue('tasks', sourceTaskId, SyncOperationType.UPDATE, savedSource, 0);
      }

      // Windowed Completion (docs §Write paths — board-context decrement
      // "append a negative-delta event … gated by windowed count > 0"). `eff`
      // is already clamped to the source's lifetime count above, so the
      // lifetime event sum can't go negative. Raw append on the SOURCE only
      // (derived tasks are carved out); the source cache is written
      // authoritatively above.
      await insertIncrementEventRaw(sourceTaskId, -eff, undefined, now);

      // 4. Find all linked (derived) tasks for this source.
      const linkedTasks = await db.tasks
        .filter((t) => !t.isDeleted && t.sharedCounterId === sourceTaskId)
        .toArray();

      // 5. Propagate via the same pure helper (works for both inc and dec — it
      //    simply re-derives from the new sourceCount, and the one-way latch is
      //    enforced by wasCompleted || derivedCompleted).
      const propagationResults = propagateIncrement(
        { currentCount: newSourceCount },
        linkedTasks.map((t) => ({
          id: t.id,
          baseline: t.baseline,
          maxCount: t.maxCount,
          isCompleted: t.isCompleted,
        })),
      );

      // 6. Write each linked task's new state + enqueue sync.
      for (const result of propagationResults) {
        const linkedTask = linkedTasks.find((t) => t.id === result.taskId);
        if (!linkedTask) continue;

        const wasCompleted = linkedTask.isCompleted;
        const nowCompleted = result.newIsCompleted; // one-way latch already applied by propagateIncrement

        const linkedPatch: Partial<Task> = {
          currentCount: result.newCurrentCount,
          isCompleted: nowCompleted,
          completedAt: !wasCompleted && nowCompleted ? now : linkedTask.completedAt,
          updatedAt: now,
          version: (linkedTask.version ?? 0) + 1,
        };
        await db.tasks.update(result.taskId, linkedPatch);
        const savedLinked = await db.tasks.get(result.taskId);
        if (savedLinked) {
          await addToSyncQueue('tasks', result.taskId, SyncOperationType.UPDATE, savedLinked, 0);
        }
      }

      // 7. Collect ACTIVE boards BEFORE the cascade.
      const allChangedTaskIds = [sourceTaskId, ...linkedTasks.map((t) => t.id)];
      const placements = await db.boardTasks
        .where('taskId').anyOf(allChangedTaskIds)
        .toArray();
      const uniqueBoardIds = [...new Set(placements.map((p) => p.boardId))];
      const boardRows = uniqueBoardIds.length > 0
        ? await db.boards.where('id').anyOf(uniqueBoardIds).toArray()
        : [];
      const affectedBoards: AffectedBoard[] = boardRows
        .filter((b) => !b.isDeleted && b.status === BoardStatus.ACTIVE)
        .map((b) => ({ boardId: b.id, boardName: b.name }));

      // 8. Run the board derivation cascade.
      for (const taskId of allChangedTaskIds) {
        await runBoardCascadeForTask(taskId);
      }

      return { affectedBoards, effectiveDelta: eff };
    },
  );
}
