import { db } from '../internal';
import type { Task, TaskEvent, SealImmuneWindow } from '@oybc/shared';
import {
  SyncOperationType,
  TaskType,
  isEventOwningTask,
  lateLogOccurredAt,
  resolveTaskWindowState,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  buildSealImmuneWindows,
  isOccurredAtSealImmune,
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

/**
 * Sealed-window immunity boundary (docs §Write paths → "Sealed-window immunity",
 * Decision 9). Build the immune windows for a task from the non-deleted SEALED
 * boards that place it — directly or via a placed compound (the same
 * reachability the pull-path re-derivation uses). An event whose `occurredAt`
 * falls inside one of these `[startDate, sealedAt]` windows can NEVER be
 * tombstoned by any un-complete / decrement gesture — history stays history.
 *
 * MUST be called inside the ambient tombstone transaction (covers boards /
 * boardTasks / compoundChildren). Returns `[]` (a fast no-op) when the user has
 * no sealed boards, so unsealed workspaces pay nothing.
 *
 * @param taskId The event-owning task whose immune windows to resolve.
 */
async function getSealImmuneWindowsForTask(taskId: string): Promise<SealImmuneWindow[]> {
  const sealedBoards = (await db.boards.toArray()).filter((b) => !b.isDeleted && b.sealedAt != null);
  if (sealedBoards.length === 0) return [];
  // Live placements only — a tombstoned BoardTask no longer places the task
  // on this board (docs/BOARD_INTEGRITY.md).
  const boardTasks = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
  const children = (await db.compoundChildren.toArray()).filter((c) => !c.isDeleted);
  const parents = findTransitiveParentCompounds(taskId, children);
  const affected = findAffectedBoardIds(taskId, parents, boardTasks);
  const placing = sealedBoards.filter((b) => affected.has(b.id));
  return buildSealImmuneWindows(
    placing.map((b) => ({ startDate: b.startDate, sealedAt: b.sealedAt as string })),
  );
}

/** Enqueue a taskEvent row for sync (append-only precedence lives in the D3 coalescer). */
async function enqueueEventSync(eventId: string, op: SyncOperationType): Promise<void> {
  const row = await db.taskEvents.get(eventId);
  if (row) await addToSyncQueue('taskEvents', eventId, op, row);
}

/**
 * The `occurredAt` for a log made from a board's OWN play surface, looked up
 * by id (2026-09-24 amendment of WC Decision 1, decisions C2/C3): the board's
 * `lateLogOccurredAt` — `min(now, board.endDate)` — so a log on an
 * ended-but-unsealed board counts inside that board's `[startDate, endDate]`
 * window and in no later one. No board (hub, counter detail, library) or a
 * missing board row → `now`. Callers that already hold the board row call
 * `lateLogOccurredAt` directly.
 *
 * Must run inside the caller's transaction (reads `boards`).
 *
 * @param boardId - The board the log was made from, or `undefined`.
 * @param now     - The operation's ISO8601 timestamp.
 * @returns The ISO timestamp to store as the event's `occurredAt`.
 */
export async function lateLogStampForBoard(boardId: string | undefined, now: string): Promise<string> {
  if (boardId === undefined) return now;
  const board = await db.boards.get(boardId);
  return board ? lateLogOccurredAt(board, now) : now;
}

/**
 * Append a `completion` event for a NORMAL task (docs §Write paths — Complete),
 * then restamp its caches. Completing an already-lifetime-complete task from a
 * new window appends a new event (the "re-complete" gesture). No-op if the task
 * is missing / not event-owning.
 *
 * @param taskId     The event-owning (normal) task.
 * @param boardId    Provenance board (where logged), or undefined for library.
 * @param now        Write timestamp (and the default occurrence timestamp).
 * @param occurredAt Optional override for the event's `occurredAt` (defaults
 *   to `now`). Board play surfaces pass `lateLogOccurredAt(board, now)` so a
 *   log made on an ended-but-unsealed board is stamped at its `endDate`
 *   (2026-09-24 amendment of WC Decision 1, decision C2).
 */
export async function appendCompletionEvent(
  taskId: string,
  boardId: string | undefined,
  now: string,
  occurredAt: string = now,
): Promise<void> {
  const task = await db.tasks.get(taskId);
  if (!task || !isEventOwningTask(task)) return;
  const event: TaskEvent = {
    id: generateUUID(),
    userId: task.userId,
    taskId,
    kind: 'completion',
    occurredAt,
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
 * tombstone ALL non-deleted completion events inside `[windowStart, windowEnd]`
 * (inclusive both ends; `windowEnd = null` → open-ended) for the viewed
 * context, then restamp caches. The upper bound (2026-09-24 amendment of WC
 * Decision 1, decision C4) keeps an undo on an ended board from erasing a
 * later window's completions, which that board no longer counts. Sealed-window-immune events
 * (docs Decision 9) are skipped — an event inside a sealed board's frozen window
 * can never be tombstoned, so a live-board un-complete whose window overlaps a
 * sealed window leaves the immune event (and its green) intact.
 *
 * @param taskId      The event-owning task.
 * @param windowStart The context window lower bound (board `startDate`).
 * @param now         The write timestamp.
 * @param windowEnd   The context window inclusive upper bound (board
 *   `endDate`), or `null` for an open-ended (indefinite) board.
 */
export async function tombstoneWindowCompletions(
  taskId: string,
  windowStart: string,
  now: string,
  windowEnd: string | null,
): Promise<void> {
  const lowerMs = new Date(windowStart).getTime();
  const upperMs = windowEnd === null ? null : new Date(windowEnd).getTime();
  const immuneWindows = await getSealImmuneWindowsForTask(taskId);
  const events = await db.taskEvents.where('taskId').equals(taskId).toArray();
  for (const e of events) {
    if (e.isDeleted) continue;
    if (e.kind !== 'completion') continue;
    const occurredMs = new Date(e.occurredAt).getTime();
    if (occurredMs < lowerMs) continue;
    if (upperMs !== null && occurredMs > upperMs) continue; // a later window's completion
    if (isOccurredAtSealImmune(e.occurredAt, immuneWindows)) continue; // sealed history is immutable
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
 * Tombstone the latest non-deleted, non-immune completion event (docs §Write
 * paths — library un-complete "acts on the latest event"), then restamp caches.
 * Used by library-context toggles that have no board window. Sealed-window-immune
 * events (docs Decision 9) are excluded from the candidate set: if the latest —
 * or every — live completion is immune, this is inert (the UI disables the
 * affordance with an explanation rather than silently eating the tap). No-op if
 * no tombstonable completion event exists.
 *
 * @param taskId The event-owning task.
 * @param now    The write timestamp.
 */
export async function tombstoneLatestCompletion(taskId: string, now: string): Promise<void> {
  const immuneWindows = await getSealImmuneWindowsForTask(taskId);
  const events = (await db.taskEvents.where('taskId').equals(taskId).toArray()).filter(
    (e) => !e.isDeleted && e.kind === 'completion' && !isOccurredAtSealImmune(e.occurredAt, immuneWindows),
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
 * Whether a library-context un-complete for this task would be inert because
 * its green is held by a sealed-window-immune completion (docs Decision 9 +
 * §Write paths — "the toggle is disabled with an explanatory affordance").
 * True iff there is at least one live completion event AND every live
 * completion event is sealed-immune (so `tombstoneLatestCompletion` would find
 * no candidate and the square would stay green). The TaskDetail / compound-child
 * un-complete affordance reads this to render disabled-with-explanation.
 *
 * @param taskId The event-owning task.
 * @returns `true` iff the un-complete affordance should be disabled + explained.
 */
export async function isUncompleteBlockedBySeal(taskId: string): Promise<boolean> {
  const immuneWindows = await getSealImmuneWindowsForTask(taskId);
  if (immuneWindows.length === 0) return false;
  const live = (await db.taskEvents.where('taskId').equals(taskId).toArray()).filter(
    (e) => !e.isDeleted && e.kind === 'completion',
  );
  if (live.length === 0) return false;
  return live.every((e) => isOccurredAtSealImmune(e.occurredAt, immuneWindows));
}

/**
 * Append a signed-delta `increment` event (docs §Write paths — Increment /
 * board-context Decrement), then restamp caches. Skips a zero delta. No-op if
 * the task is missing / not event-owning.
 *
 * @param taskId     The event-owning (counting source/plain) task.
 * @param delta      Signed non-zero integer.
 * @param boardId    Provenance board, or undefined.
 * @param now        Write timestamp (and the default occurrence timestamp).
 * @param occurredAt Optional override for the event's `occurredAt` (defaults
 *   to `now`) — the late-log stamp, as for {@link appendCompletionEvent}.
 */
export async function appendIncrementEvent(
  taskId: string,
  delta: number,
  boardId: string | undefined,
  now: string,
  occurredAt: string = now,
): Promise<void> {
  const appended = await insertIncrementEventRaw(taskId, delta, boardId, now, occurredAt);
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
 * @param occurredAt Optional override for the event's `occurredAt` (defaults
 *   to `now`). Used by seed/backfill paths that need to anchor an event at a
 *   sentinel timestamp distinct from the write-time `createdAt`/`updatedAt`,
 *   and by board play surfaces for the late-log stamp (`lateLogOccurredAt`).
 * @returns `true` if an event row was written; `false` on a zero delta / a
 *          missing or non-event-owning task.
 */
export async function insertIncrementEventRaw(
  taskId: string,
  delta: number,
  boardId: string | undefined,
  now: string,
  occurredAt: string = now,
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
    occurredAt,
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
