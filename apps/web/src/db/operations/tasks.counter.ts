import { db } from '../internal';
import {
  CreateTaskInputSchema,
  SEED_EVENT_OCCURRED_AT,
  SyncOperationType,
  TaskType,
  contextlessCounterState,
  isQuantizedCount,
  isWholeCountKind,
  renderCounterTitle,
  type CountKind,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { computeTaskCachesFromEvents, insertIncrementEventRaw } from './taskEvents';
import { deleteTaskWithCascadeInTxn } from './tasks.deletion';
import { unflagContributorsOf } from './countsToward';

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
 *   non-negative `startingCount` (defaults to 0) and `countKind` (written explicitly, default 'discrete'; whole-number kinds refuse a fractional seed).
 * @returns The newly created counter Task.
 * @throws If `action`/`unit` are blank after trimming, or `startingCount`
 *   is not a non-negative 2dp number.
 */
export async function createCounterTask(
  userId: string,
  input: {
    action: string;
    unit: string;
    startingCount?: number;
    countKind?: CountKind;
    /** Shared counter settings the create sheet stored (absent = default). */
    settings?: Pick<Task, 'counterName' | 'titleTemplateSingular' | 'titleTemplatePlural' | 'timeframeGoals'>;
  },
): Promise<Task> {
  const action = input.action.trim();
  const unit = input.unit.trim();
  const startingCount = input.startingCount ?? 0;
  const countKind: CountKind = input.countKind ?? 'discrete';
  if (!action || !unit) throw new Error('createCounterTask: action and unit are required');
  if (!isQuantizedCount(startingCount) || startingCount < 0 || (isWholeCountKind(countKind) && !Number.isInteger(startingCount))) {
    throw new Error('createCounterTask: startingCount must be a non-negative count at the counter kind');
  }
  const settings = definedSettings(input.settings);
  const validated = CreateTaskInputSchema.parse({
    // Goal-less: the title is the counter's name (`renderCounterTitle`).
    title: renderCounterTitle({ action, unit, countKind, ...settings }, null),
    type: TaskType.COUNTING,
    action,
    unit,
    isCounter: true,
    countKind,
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
    countKind,
    ...settings,
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
 * The settings keys that carry a value, trimmed (an absent or whitespace-only key stays absent — D3).
 *
 * @param settings - The create sheet's stored settings.
 */
function definedSettings(
  settings: Pick<Task, 'counterName' | 'titleTemplateSingular' | 'titleTemplatePlural' | 'timeframeGoals'> | undefined,
): Partial<Task> {
  const out: Partial<Task> = {};
  // Trimmed; whitespace-only = absent (the iOS `CounterSettings.storedText` rule).
  const text = (v: string | undefined): string | undefined => v?.trim() || undefined;
  const counterName = text(settings?.counterName);
  const singular = text(settings?.titleTemplateSingular);
  const plural = text(settings?.titleTemplatePlural);
  if (counterName) out.counterName = counterName;
  if (singular) out.titleTemplateSingular = singular;
  if (plural) out.titleTemplatePlural = plural;
  if (settings?.timeframeGoals && Object.keys(settings.timeframeGoals).length > 0) {
    out.timeframeGoals = settings.timeframeGoals;
  }
  return out;
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
    // A counter may not count toward a counter (Zod shape rule — a flagged
    // promoted row would be dropped by every other device's pull).
    if (t.countsTowardCounterId != null) throw new Error('promoteTaskToCounter: a task that counts toward a counter cannot be a counter');
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
 * `currentCount` is seeded from the root's lifetime events
 * (`contextlessCounterState` — TASK_WINDOW_REWORK slice 5), so it becomes an
 * independent counting task that keeps the counter's total. The snapshot event is anchored at
 * `SEED_EVENT_OCCURRED_AT` (the same far-past seed sentinel `createCounterTask`
 * uses), NOT `now` — it captures a one-time carried-over lifetime balance, not
 * a present-day activity occurrence, so it must be excluded from day-bucketing
 * (`deriveCounterDailyTotals`) rather than inflating the member's "Today" /
 * sparkline. The authoritative `currentCount` (lifetime sum) is unchanged.
 * No-op (returns without writing) if the source is missing or already deleted.
 *
 * @param sourceId - The counter source task to delete.
 */
export async function deleteCounterWithUnlink(sourceId: string): Promise<void> {
  const now = currentTimestamp();
  await db.transaction(
    'rw',
    // `boards` is in scope for the cascade step of `deleteTaskWithCascadeInTxn`
    // (the deleted source's own placements re-derive their boards in-txn).
    [db.tasks, db.taskEvents, db.boardTasks, db.compoundChildren, db.boards, db.syncQueue],
    async () => {
      const source = await db.tasks.get(sourceId);
      if (!source || source.isDeleted) return;
      const members = await db.tasks
        .where('sharedCounterId').equals(sourceId)
        .filter((t) => !t.isDeleted).toArray();
      const rootEvents = await db.taskEvents.where('taskId').equals(sourceId).toArray();
      const eventsByTaskId = { [sourceId]: rootEvents.filter((e) => !e.isDeleted) };
      for (const m of members) {
        const displayed = contextlessCounterState(m, eventsByTaskId).count;
        // Now an event owner: its lifetime caches follow its (seed) event,
        // never the linked row's stale latch.
        const seed = { kind: 'increment', delta: displayed, occurredAt: SEED_EVENT_OCCURRED_AT, isDeleted: false } as TaskEvent;
        const caches = computeTaskCachesFromEvents(
          { ...m, sharedCounterId: null, baseline: null },
          displayed > 0 ? [seed] : [],
        );
        const unlinked: Task = {
          ...m,
          sharedCounterId: null,
          baseline: null,
          currentCount: displayed,
          isCompleted: caches.isCompleted,
          completedAt: caches.completedAt,
          totalCompletions: caches.totalCompletions,
          updatedAt: now,
          version: m.version + 1,
        };
        await db.tasks.put(unlinked);
        await addToSyncQueue('tasks', m.id, SyncOperationType.UPDATE, unlinked);
        if (displayed > 0) {
          // Anchor the carried-over lifetime snapshot at the seed sentinel (not
          // `now`) so it is excluded from day-bucketing — it's a starting
          // balance, not a present-day occurrence.
          await insertIncrementEventRaw(m.id, displayed, undefined, now, SEED_EVENT_OCCURRED_AT);
        }
      }
      // "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3e) — contributors
      // stop counting toward the deleted counter; their events go with it.
      await unflagContributorsOf(sourceId, now);
      await deleteTaskWithCascadeInTxn(sourceId, now);
    },
  );
}
