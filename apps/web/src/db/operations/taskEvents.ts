import { db } from '../internal';
import type { Task, TaskEvent } from '@oybc/shared';
import {
  SyncOperationType,
  TaskType,
  isEventOwningTask,
  resolveTaskWindowState,
} from '@oybc/shared';
import { generateUUID } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * Windowed Completion — TaskEvent write choke points + cache recompute
 * (docs/WINDOWED_COMPLETION.md §Write paths + §Task caches).
 *
 * Every function here MUST be called from inside an ambient Dexie `rw`
 * transaction that already covers at least `[tasks, taskEvents, syncQueue]`
 * (the write choke points open one that also covers `boards`, `boardTasks`,
 * `compoundChildren` for the derivation cascade). Appending an event and
 * stamping the lifetime caches ride the SAME transaction so a peer / older
 * surface never sees an event without its cache stamp (or vice versa).
 *
 * `Task.isCompleted` / `currentCount` / `completedAt` are demoted to LIFETIME
 * caches (docs §Task caches): recomputed from the full non-deleted event set,
 * never trusted for anything windowed (grids + derivation read events). The
 * board-grid + derivation-pass windowing lives in the shared kernel
 * (`resolveTaskWindowState` / `computeBoardStatsUpdate`); this module owns the
 * local write + cache side.
 */

/** The lifetime cache fields recomputed from a task's event set. */
export interface TaskCacheFields {
  isCompleted: boolean;
  currentCount: number | undefined;
  completedAt: string | undefined;
}

/**
 * Pure recompute of an event-owning task's LIFETIME caches from its events
 * (docs §Task caches — "isCompleted = latest lifetime toggle state,
 * currentCount = lifetime delta sum, completedAt = occurredAt of the latest
 * non-deleted completion event"). Deterministic function of the (converged)
 * event union, so on-pull recompute converges across devices.
 *
 * NORMAL: `isCompleted` iff any non-deleted completion event exists; `completedAt`
 * is the latest such event's `occurredAt`; `currentCount` stays undefined.
 * COUNTING (plain / source): `currentCount` is the lifetime delta sum
 * (low-clamped at 0 — overshoot preserved); `isCompleted` iff sum ≥ maxCount;
 * `completedAt` is the latest increment's `occurredAt` when complete (a
 * deterministic anchor for the library "when completed" display).
 *
 * @param task   The event-owning task (caller guarantees `isEventOwningTask`).
 * @param events The task's events (deleted rows ignored internally).
 * @returns The cache fields to stamp onto the Task row.
 */
export function computeTaskCachesFromEvents(
  task: Task,
  events: TaskEvent[],
): TaskCacheFields {
  const live = events.filter((e) => !e.isDeleted);

  if (task.type === TaskType.COUNTING) {
    const { count } = resolveTaskWindowState(task, live, null); // lifetime sum
    const isCompleted = task.maxCount != null && count >= task.maxCount;
    let completedAt: string | undefined;
    if (isCompleted) {
      for (const e of live) {
        if (e.kind !== 'increment') continue;
        if (completedAt === undefined || e.occurredAt > completedAt) completedAt = e.occurredAt;
      }
    }
    return { isCompleted, currentCount: count, completedAt };
  }

  // NORMAL (and defensive non-counting owners).
  let completedAt: string | undefined;
  let hasCompletion = false;
  for (const e of live) {
    if (e.kind !== 'completion') continue;
    hasCompletion = true;
    if (completedAt === undefined || e.occurredAt > completedAt) completedAt = e.occurredAt;
  }
  return { isCompleted: hasCompletion, currentCount: task.currentCount, completedAt };
}

/**
 * Stamp the recomputed lifetime caches onto a task as an AUTHORED write
 * (docs §Task caches — "Cache stamps are authored writes: they ride the same
 * transaction as the event append, bump `Task.version`, and enqueue a Task
 * sync entry"). Called by the local write choke points after an event
 * append/tombstone. No-op if the task is missing / not event-owning.
 *
 * @param taskId The event-owning task whose caches to restamp.
 * @param now    The write timestamp (shared with the event for coherence).
 */
async function stampTaskCachesAuthored(taskId: string, now: string): Promise<void> {
  const task = await db.tasks.get(taskId);
  if (!task || !isEventOwningTask(task)) return;
  const events = await db.taskEvents.where('taskId').equals(taskId).toArray();
  const caches = computeTaskCachesFromEvents(task, events);
  await db.tasks.update(taskId, {
    isCompleted: caches.isCompleted,
    currentCount: caches.currentCount,
    completedAt: caches.completedAt,
    updatedAt: now,
    version: (task.version ?? 0) + 1,
  });
  const updated = await db.tasks.get(taskId);
  if (updated) await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, updated);
}

/**
 * Recompute the lifetime caches from events on the PULL path (docs §Sync —
 * "On pull, event-owning tasks' caches are recomputed from events, not
 * trusted"). Unlike the authored stamp, this does NOT bump `version` and does
 * NOT enqueue a sync entry — pull paths don't author writes; the recompute
 * overwrites only the completion-cache fields.
 *
 * @param taskId The event-owning task whose caches to recompute.
 */
export async function recomputeTaskCachesFromPull(taskId: string): Promise<void> {
  const task = await db.tasks.get(taskId);
  if (!task || !isEventOwningTask(task)) return;
  const events = await db.taskEvents.where('taskId').equals(taskId).toArray();
  const caches = computeTaskCachesFromEvents(task, events);
  await db.tasks.update(taskId, {
    isCompleted: caches.isCompleted,
    currentCount: caches.currentCount,
    completedAt: caches.completedAt,
  });
}

/** Enqueue a taskEvent row for sync (append-only precedence lives in the D3 coalescer). */
async function enqueueEventSync(eventId: string, op: SyncOperationType): Promise<void> {
  const row = await db.taskEvents.get(eventId);
  if (row) await addToSyncQueue('taskEvents', eventId, op, row);
}

/**
 * Append a `completion` event for a NORMAL task (docs §Write paths — Complete),
 * then restamp its caches. Completing an already-lifetime-complete task from a
 * new window appends a new event (the "re-complete" gesture). No-op if the task
 * is missing / not event-owning.
 *
 * @param taskId  The event-owning (normal) task.
 * @param boardId Provenance board (where logged), or undefined for library.
 * @param now     Occurrence + write timestamp.
 */
export async function appendCompletionEvent(
  taskId: string,
  boardId: string | undefined,
  now: string,
): Promise<void> {
  const task = await db.tasks.get(taskId);
  if (!task || !isEventOwningTask(task)) return;
  const event: TaskEvent = {
    id: generateUUID(),
    userId: task.userId,
    taskId,
    kind: 'completion',
    occurredAt: now,
    boardId,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
  await enqueueEventSync(event.id, SyncOperationType.CREATE);
  await stampTaskCachesAuthored(taskId, now);
}

/**
 * Window-scoped un-complete (docs §Write paths — "Un-complete is window-scoped"):
 * tombstone ALL non-deleted completion events with `occurredAt >= windowStart`
 * for the viewed context, then restamp caches. (Sealed-window immunity lands in
 * PR C; no sealed boards exist yet, so every in-window event is tombstonable.)
 *
 * @param taskId      The event-owning task.
 * @param windowStart The context window lower bound (board `startDate`).
 * @param now         The write timestamp.
 */
export async function tombstoneWindowCompletions(
  taskId: string,
  windowStart: string,
  now: string,
): Promise<void> {
  const lowerMs = new Date(windowStart).getTime();
  const events = await db.taskEvents.where('taskId').equals(taskId).toArray();
  for (const e of events) {
    if (e.isDeleted) continue;
    if (e.kind !== 'completion') continue;
    if (new Date(e.occurredAt).getTime() < lowerMs) continue;
    await db.taskEvents.update(e.id, {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (e.version ?? 1) + 1,
    });
    await enqueueEventSync(e.id, SyncOperationType.DELETE);
  }
  await stampTaskCachesAuthored(taskId, now);
}

/**
 * Tombstone the latest non-deleted completion event (docs §Write paths —
 * library un-complete "acts on the latest event"), then restamp caches. Used
 * by library-context toggles that have no board window. No-op if no live
 * completion event exists.
 *
 * @param taskId The event-owning task.
 * @param now    The write timestamp.
 */
export async function tombstoneLatestCompletion(taskId: string, now: string): Promise<void> {
  const events = (await db.taskEvents.where('taskId').equals(taskId).toArray()).filter(
    (e) => !e.isDeleted && e.kind === 'completion',
  );
  if (events.length === 0) {
    // Still restamp — a stale lifetime cache (e.g. legacy isCompleted with no
    // event) must reconcile to "incomplete" from the empty event set.
    await stampTaskCachesAuthored(taskId, now);
    return;
  }
  const latest = events.reduce((a, b) =>
    new Date(b.occurredAt).getTime() >= new Date(a.occurredAt).getTime() ? b : a,
  );
  await db.taskEvents.update(latest.id, {
    isDeleted: true,
    deletedAt: now,
    updatedAt: now,
    version: (latest.version ?? 1) + 1,
  });
  await enqueueEventSync(latest.id, SyncOperationType.DELETE);
  await stampTaskCachesAuthored(taskId, now);
}

/**
 * Append a signed-delta `increment` event (docs §Write paths — Increment /
 * board-context Decrement), then restamp caches. Skips a zero delta. No-op if
 * the task is missing / not event-owning.
 *
 * @param taskId  The event-owning (counting source/plain) task.
 * @param delta   Signed non-zero integer.
 * @param boardId Provenance board, or undefined.
 * @param now     Occurrence + write timestamp.
 */
export async function appendIncrementEvent(
  taskId: string,
  delta: number,
  boardId: string | undefined,
  now: string,
): Promise<void> {
  const appended = await insertIncrementEventRaw(taskId, delta, boardId, now);
  if (appended) await stampTaskCachesAuthored(taskId, now);
}

/**
 * Append a signed-delta `increment` event WITHOUT restamping caches. Used by
 * the shared-counter engine (`incrementSharedCounter` / `decrementSharedCounter`),
 * which already writes the source's lifetime `currentCount` authoritatively via
 * its own arithmetic (provably equal to the lifetime event sum) — a restamp
 * would double-bump `version`. The event still needs to exist so windowed board
 * reads of the source counting square resolve correctly.
 *
 * @returns `true` if an event row was written; `false` on a zero delta / a
 *          missing or non-event-owning task.
 */
export async function insertIncrementEventRaw(
  taskId: string,
  delta: number,
  boardId: string | undefined,
  now: string,
): Promise<boolean> {
  if (delta === 0) return false;
  const task = await db.tasks.get(taskId);
  if (!task || !isEventOwningTask(task)) return false;
  const event: TaskEvent = {
    id: generateUUID(),
    userId: task.userId,
    taskId,
    kind: 'increment',
    delta,
    occurredAt: now,
    boardId,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
  await enqueueEventSync(event.id, SyncOperationType.CREATE);
  return true;
}
