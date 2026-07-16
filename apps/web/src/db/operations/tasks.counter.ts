import { db } from '../internal';
import {
  CreateTaskInputSchema,
  SEED_EVENT_OCCURRED_AT,
  SyncOperationType,
  TaskType,
  deriveDisplayedCount,
  generateCounterTaskTitle,
  type Task,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { insertIncrementEventRaw } from './taskEvents';
import { deleteTaskWithCascadeInTxn } from './tasks.deletion';

/**
 * P5 — Counters Hub write ops (docs/SHARED_COUNTERS.md §P5).
 *
 * `createCounterTask` (hub "+ New counter"), `promoteTaskToCounter`
 * (decision 7 — flag an existing standalone counting task as a counter),
 * and `deleteCounterWithUnlink` (decision 8 — deleting a source unlinks its
 * members rather than orphaning them) are the three write paths that touch
 * `Task.isCounter`. No other code path sets this flag.
 */

/**
 * Create a goal-less hub-born counter Task, optionally seeded with a
 * starting count. Task row + optional seed increment event are written in
 * ONE Dexie transaction so a seeded counter never exists without its
 * founding event (or vice versa).
 *
 * The seed event (when `startingCount > 0`) is anchored at
 * `SEED_EVENT_OCCURRED_AT` (not `now`) so it never counts toward any
 * windowed board read — it exists purely so the lifetime event sum matches
 * the task row's authoritative `currentCount`. Uses `insertIncrementEventRaw`
 * (no cache restamp): `task.currentCount` is already written authoritatively
 * as `startingCount` above; a restamp would double-bump `version`.
 *
 * @param userId - Owning user.
 * @param input - `action` + `unit` (both required, trimmed) and an optional
 *   non-negative integer `startingCount` (defaults to 0).
 * @returns The newly created counter Task.
 * @throws If `action`/`unit` are blank after trimming, or `startingCount`
 *   is not a non-negative integer.
 */
export async function createCounterTask(
  userId: string,
  input: { action: string; unit: string; startingCount?: number },
): Promise<Task> {
  const action = input.action.trim();
  const unit = input.unit.trim();
  const startingCount = input.startingCount ?? 0;
  if (!action || !unit) throw new Error('createCounterTask: action and unit are required');
  if (!Number.isInteger(startingCount) || startingCount < 0) {
    throw new Error('createCounterTask: startingCount must be a non-negative integer');
  }
  const validated = CreateTaskInputSchema.parse({
    title: generateCounterTaskTitle(action, null, unit),
    type: TaskType.COUNTING,
    action,
    unit,
    isCounter: true,
  });
  const now = currentTimestamp();
  const task: Task = {
    id: generateUUID(),
    userId,
    title: validated.title,
    type: TaskType.COUNTING,
    action,
    unit,
    isCounter: true,
    currentCount: startingCount,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };
  await db.transaction('rw', [db.tasks, db.taskEvents, db.syncQueue], async () => {
    await db.tasks.add(task);
    await addToSyncQueue('tasks', task.id, SyncOperationType.CREATE, task);
    if (startingCount > 0) {
      // Raw (no cache restamp): currentCount is already authoritative above.
      await insertIncrementEventRaw(task.id, startingCount, undefined, now, SEED_EVENT_OCCURRED_AT);
    }
  });
  return task;
}

/**
 * P5 decision 7 — flag a standalone (non-derived) COUNTING task as a
 * counter, so it appears in the Counters Hub. Bumps `version`/`updatedAt`
 * and enqueues an UPDATE sync entry.
 *
 * @param taskId - The standalone counting task to promote.
 * @returns The updated Task.
 * @throws If the task is missing/deleted, not `TaskType.COUNTING`, or is
 *   itself a derived (linked) task (`sharedCounterId` set) — a derived task
 *   can never be a counter source.
 */
export async function promoteTaskToCounter(taskId: string): Promise<Task> {
  const now = currentTimestamp();
  let updated: Task | undefined;
  await db.transaction('rw', [db.tasks, db.syncQueue], async () => {
    const t = await db.tasks.get(taskId);
    if (!t || t.isDeleted) throw new Error(`promoteTaskToCounter: task ${taskId} not found`);
    if (t.type !== TaskType.COUNTING) throw new Error('promoteTaskToCounter: only counting tasks');
    if (t.sharedCounterId != null) throw new Error('promoteTaskToCounter: derived tasks cannot be counters');
    updated = { ...t, isCounter: true, updatedAt: now, version: t.version + 1 };
    await db.tasks.put(updated);
    await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, updated);
  });
  return updated!;
}

/**
 * P5 decision 8 — delete a counter source by first unlinking every live
 * member (writing a snapshot increment event so the member's displayed
 * value survives as its own standalone lifetime count) then cascade-
 * deleting the source itself. All in ONE Dexie transaction.
 *
 * Each member's `sharedCounterId`/`baseline` are cleared and its
 * `currentCount` is set to its current derived `displayed` value (via
 * `deriveDisplayedCount`), so it becomes an independent counting task that
 * keeps whatever progress it showed. The snapshot event is anchored at
 * `now` (NOT the seed sentinel) — it's a real, present-day event, not
 * backfill. No-op (returns without writing) if the source is missing or
 * already deleted.
 *
 * @param sourceId - The counter source task to delete.
 */
export async function deleteCounterWithUnlink(sourceId: string): Promise<void> {
  const now = currentTimestamp();
  await db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const source = await db.tasks.get(sourceId);
      if (!source || source.isDeleted) return;
      const members = await db.tasks
        .where('sharedCounterId').equals(sourceId)
        .filter((t) => !t.isDeleted).toArray();
      for (const m of members) {
        const { displayed } = deriveDisplayedCount(
          { baseline: m.baseline ?? 0, maxCount: m.maxCount ?? 0 },
          { currentCount: source.currentCount ?? 0 },
        );
        const unlinked: Task = {
          ...m,
          sharedCounterId: null,
          baseline: null,
          currentCount: displayed,
          updatedAt: now,
          version: m.version + 1,
        };
        await db.tasks.put(unlinked);
        await addToSyncQueue('tasks', m.id, SyncOperationType.UPDATE, unlinked);
        if (displayed > 0) await insertIncrementEventRaw(m.id, displayed, undefined, now);
      }
      await deleteTaskWithCascadeInTxn(sourceId, now);
    },
  );
}
