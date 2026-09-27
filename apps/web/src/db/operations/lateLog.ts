import { db } from '../internal';
import {
  TaskType,
  isEventOwningTask,
  isEventSealImmune,
  isWindowStampedDerived,
  lateLogOccurredAt,
  selectClosedBoardLateLogs,
  SyncOperationType,
  type Task,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import {
  appendCompletionEvent,
  appendIncrementEvent,
  insertIncrementEventRaw,
  computeTaskCachesFromEvents,
  getSealImmuneWindowsForTask,
} from './taskEvents';
import { refreshDerivedBaselines } from './derivedCounters';
import { propagateToLinkedRows } from './tasks.sharedCounter';
import { reDeriveSealedBoardsForTasks } from './sealing';
import { resolveAffectedBoardIds, refreshWatchersForBoards } from './boardLifecycle';
import { runBoardCascadeForTasks } from './orchestration';

/**
 * Board Edit redesign slice 4 (D7) — direct late log on a CLOSED board's own
 * play surface. ONE DB choke point per task-type shape (this file), so every
 * OTHER write path keeps its sealed no-op guard intact: a closed board
 * authors an event ONLY through the four entry points here, each stamped at
 * the board's `endDate` ({@link lateLogOccurredAt}), then re-derived (D9) and
 * fanned out to achievement watchers (D8) — all in ONE transaction.
 */

/** Board metadata / task-shape guards these entry points enforce. */
export type LateLogErrorKind = 'boardNotFound' | 'boardNotClosed' | 'taskNotFound' | 'wrongType';

/** Thrown by every entry point in this file on a guard failure. */
export class LateLogError extends Error {
  readonly kind: LateLogErrorKind;

  constructor(kind: LateLogErrorKind, id: string) {
    super(`LateLog: ${kind} (${id})`);
    this.name = 'LateLogError';
    this.kind = kind;
  }
}

/** The tables every late-log transaction below touches. */
const LATE_LOG_TABLES = [
  db.boards,
  db.boardTasks,
  db.tasks,
  db.compoundChildren,
  db.taskEvents,
  db.syncQueue,
] as const;

/**
 * D9(b–d) — after a late-log / undo write: live-cascade the unsealed boards
 * placing any of `changedTaskIds` (skips sealed internally), deterministically
 * re-derive every SEALED board placing them (local-only, no version bump —
 * same function the pull path uses), then refresh any achievement watcher of
 * whatever board just changed. Called from every entry point below.
 */
async function applyLateLogSideEffects(changedTaskIds: Iterable<string>): Promise<void> {
  const ids = [...new Set(changedTaskIds)];
  if (ids.length === 0) return;
  const affectedBoardIds = await resolveAffectedBoardIds(ids);
  await runBoardCascadeForTasks(ids);
  await reDeriveSealedBoardsForTasks(ids);
  if (affectedBoardIds.size > 0) await refreshWatchersForBoards(affectedBoardIds);
}

/** Restamp an event-owning task's lifetime caches (mirrors `taskEvents.ts`'s
 *  private `stampTaskCachesAuthored` — duplicated here rather than exported,
 *  since it's a one-line wrapper around the exported pure function). */
async function restampCaches(taskId: string, now: string): Promise<void> {
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

/** Guard shared by every entry point: the board exists, is live, and is closed. */
async function requireClosedBoard(boardId: string) {
  const board = await db.boards.get(boardId);
  if (!board || board.isDeleted) throw new LateLogError('boardNotFound', boardId);
  if (board.sealedAt == null) throw new LateLogError('boardNotClosed', boardId);
  return board;
}

/**
 * Whether a non-deleted completion event already falls inside the window a
 * sealed board's snapshot counted (`[startDate, min(endDate, sealedAt)]`) —
 * tapping "Mark done on board" again on an already-green square is a no-op,
 * never a second event.
 */
function hasCompletionInSealedWindow(
  events: ReadonlyArray<{ isDeleted: boolean; kind: string; occurredAt: string }>,
  startDate: string,
  endDate: string | null | undefined,
  sealedAt: string,
): boolean {
  const startMs = new Date(startDate).getTime();
  const endMs = endDate != null ? new Date(endDate).getTime() : NaN;
  const sealedMs = new Date(sealedAt).getTime();
  const boundMs = Number.isNaN(endMs) ? sealedMs : Math.min(endMs, sealedMs);
  return events.some((e) => {
    if (e.isDeleted || e.kind !== 'completion') return false;
    const t = new Date(e.occurredAt).getTime();
    return t >= startMs && t <= boundMs;
  });
}

/**
 * Late-log a NORMAL task's completion on a closed board (D7). No-op if the
 * task is already complete inside the sealed window (never a duplicate
 * event).
 *
 * @param boardId The closed board the log is made from.
 * @param taskId  The NORMAL task placed on it.
 * @param now     Write timestamp; the event is stamped at the board's
 *   `endDate` ({@link lateLogOccurredAt}), not `now`.
 */
export async function lateLogCompletion(
  boardId: string,
  taskId: string,
  now: string = currentTimestamp(),
): Promise<void> {
  await db.transaction('rw', LATE_LOG_TABLES, async () => {
    const board = await requireClosedBoard(boardId);
    const task = await db.tasks.get(taskId);
    if (!task || task.isDeleted) throw new LateLogError('taskNotFound', taskId);
    if (task.type !== TaskType.NORMAL) throw new LateLogError('wrongType', taskId);

    const events = await db.taskEvents.where('taskId').equals(taskId).toArray();
    if (hasCompletionInSealedWindow(events, board.startDate, board.endDate, board.sealedAt as string)) {
      return;
    }

    const occurredAt = lateLogOccurredAt(board, now);
    await appendCompletionEvent(taskId, boardId, now, occurredAt);
    await applyLateLogSideEffects([taskId]);
  });
}

/**
 * Late-log a COUNTING task's increment on a closed board (D7). Partial and
 * overshoot are both valid — never high-clamped.
 *
 *  - **Plain / source** (`sharedCounterId == null`): appends directly on the
 *    task (which may itself be a shared-counter root with live linked rows —
 *    propagated exactly like {@link incrementSharedCounter}, just without its
 *    sealed no-op).
 *  - **Window-stamped derived** ({@link isWindowStampedDerived}): the event is
 *    authored on the ROOT (`task.sharedCounterId`), never the derived row
 *    itself (WC's derived-task carve-out) — the closed board's own square
 *    resolves from the root's in-window events on the next read.
 *  - **Hub-linked derived** (no `startDate`): a full no-op (OQ2 default) — its
 *    state is the lifetime latch, not windowed; a backdated root log would
 *    repaint every board placing it.
 *
 * @param boardId The closed board the log is made from.
 * @param taskId  The COUNTING task (or window-stamped derived row) tapped.
 * @param delta   A positive integer amount to log.
 * @param now     Write timestamp; the event is stamped at the board's
 *   `endDate`.
 */
export async function lateLogIncrement(
  boardId: string,
  taskId: string,
  delta: number,
  now: string = currentTimestamp(),
): Promise<void> {
  if (!Number.isInteger(delta) || delta <= 0) {
    throw new Error('lateLogIncrement: delta must be a positive integer');
  }
  await db.transaction('rw', LATE_LOG_TABLES, async () => {
    const board = await requireClosedBoard(boardId);
    const task = await db.tasks.get(taskId);
    if (!task || task.isDeleted) throw new LateLogError('taskNotFound', taskId);
    if (task.type !== TaskType.COUNTING) throw new LateLogError('wrongType', taskId);

    // Hub-linked derived counter — OQ2: not tappable on a closed board.
    if (task.sharedCounterId != null && !isWindowStampedDerived(task)) return;

    const rootId = task.sharedCounterId ?? taskId;
    const root = await db.tasks.get(rootId);
    if (!root || root.isDeleted) return; // orphaned link — defensive no-op

    const occurredAt = lateLogOccurredAt(board, now);
    const newRootCount = (root.currentCount ?? 0) + delta;
    const rootWasCompleted = root.isCompleted;
    const rootNowCompleted =
      rootWasCompleted || (root.maxCount != null && newRootCount >= root.maxCount);

    await db.tasks.update(rootId, {
      currentCount: newRootCount,
      isCompleted: rootNowCompleted,
      completedAt: !rootWasCompleted && rootNowCompleted ? now : root.completedAt,
      updatedAt: now,
      version: (root.version ?? 0) + 1,
    });
    const savedRoot = await db.tasks.get(rootId);
    if (savedRoot) await addToSyncQueue('tasks', rootId, SyncOperationType.UPDATE, savedRoot, 0);

    await insertIncrementEventRaw(rootId, delta, boardId, now, occurredAt);
    await refreshDerivedBaselines(rootId);
    // Propagates to every LIVE linked row (frozen ones reached cascade-only
    // via `isFrozenRowReachedByEvent`, since `occurredAt` falls in this
    // closed board's own window) and runs the live cascade for the source +
    // linked ids (sealed boards are skipped there — `applyLateLogSideEffects`
    // below covers the sealed re-derive for THIS board).
    await propagateToLinkedRows(rootId, newRootCount, now, occurredAt);
    await applyLateLogSideEffects([rootId, taskId]);
  });
}

/** One staged part of a compound late-log commit ({@link lateLogCompoundParts}). */
export interface LateLogCompoundAction {
  /** The compound's direct child task id (verified against `compoundChildren`). */
  childTaskId: string;
  /** `'completion'` for a NORMAL child; `'increment'` for a plain COUNTING child. */
  kind: 'completion' | 'increment';
  /** Required when `kind === 'increment'`; a positive integer. */
  delta?: number;
}

/**
 * Late-log a COMPOUND task's staged child parts on a closed board (D7). The
 * caller (the late-log sheet) has already staged which children to mark and
 * verified the compound's rule is met under that staged state — this choke
 * point re-validates each action structurally (a real, non-deleted,
 * event-owning direct child of the right type) and applies only the ones
 * that pass, silently ignoring the rest (defense in depth, never a partial
 * throw mid-commit).
 *
 * Non-event-owning children (a derived counter, or a nested compound) are
 * read-only and always skipped — matching the WC compound-child-fallback
 * rule. A plain COUNTING child that is ITSELF a shared-counter link is also
 * skipped here (out of scope for this sheet — vanishingly rare nesting).
 *
 * @param boardId        The closed board the log is made from.
 * @param compoundTaskId The compound task placed on it.
 * @param actions        The staged per-child actions to commit.
 * @param now            Write timestamp; every event is stamped at the
 *   board's `endDate`.
 */
export async function lateLogCompoundParts(
  boardId: string,
  compoundTaskId: string,
  actions: LateLogCompoundAction[],
  now: string = currentTimestamp(),
): Promise<void> {
  await db.transaction('rw', LATE_LOG_TABLES, async () => {
    const board = await requireClosedBoard(boardId);
    const compound = await db.tasks.get(compoundTaskId);
    if (!compound || compound.isDeleted) throw new LateLogError('taskNotFound', compoundTaskId);
    if (compound.type !== TaskType.COMPOUND) throw new LateLogError('wrongType', compoundTaskId);

    const links = await db.compoundChildren
      .where('compoundTaskId')
      .equals(compoundTaskId)
      .filter((c) => !c.isDeleted)
      .toArray();
    const childIds = new Set(links.map((l) => l.childTaskId));

    const occurredAt = lateLogOccurredAt(board, now);
    const touchedTaskIds = new Set<string>([compoundTaskId]);

    for (const action of actions) {
      if (!childIds.has(action.childTaskId)) continue;
      const child: Task | undefined = await db.tasks.get(action.childTaskId);
      if (!child || child.isDeleted || !isEventOwningTask(child)) continue;

      if (action.kind === 'completion') {
        if (child.type !== TaskType.NORMAL) continue;
        const events = await db.taskEvents.where('taskId').equals(child.id).toArray();
        if (hasCompletionInSealedWindow(events, board.startDate, board.endDate, board.sealedAt as string)) {
          continue;
        }
        await appendCompletionEvent(child.id, boardId, now, occurredAt);
        touchedTaskIds.add(child.id);
      } else {
        if (child.type !== TaskType.COUNTING || child.sharedCounterId != null) continue;
        const delta = action.delta;
        if (!Number.isInteger(delta) || (delta as number) <= 0) continue;
        await appendIncrementEvent(child.id, delta as number, boardId, now, occurredAt);
        touchedTaskIds.add(child.id);
      }
    }

    await applyLateLogSideEffects([...touchedTaskIds]);
  });
}

/**
 * Undo the newest late log a user made directly on a closed board for one
 * task (D10 / owner ruling R2) — identified by provenance (`boardId` +
 * `occurredAt` == the board's `endDate` instant), never a marker field, and
 * ordered by `createdAt` descending so repeated taps undo one at a time. For
 * a window-stamped derived square, resolves to the ROOT's late logs (derived
 * rows own no events).
 *
 * @param boardId The closed board the log was made on.
 * @param taskId  The task (or window-stamped derived row) to undo for.
 * @param now     Write timestamp for the tombstone.
 * @returns `true` if a late log was found and undone; `false` if there was
 *   none (the caller should hide/disable the affordance).
 */
export async function undoLateLog(
  boardId: string,
  taskId: string,
  now: string = currentTimestamp(),
): Promise<boolean> {
  return db.transaction('rw', LATE_LOG_TABLES, async () => {
    const board = await requireClosedBoard(boardId);
    const task = await db.tasks.get(taskId);
    if (!task || task.isDeleted) throw new LateLogError('taskNotFound', taskId);

    const effectiveTaskId =
      isWindowStampedDerived(task) && task.sharedCounterId != null ? task.sharedCounterId : taskId;

    const events = await db.taskEvents.where('taskId').equals(effectiveTaskId).toArray();
    const candidates = selectClosedBoardLateLogs(events, board, effectiveTaskId);
    const entry = candidates[0];
    if (!entry) return false;

    // D10 — a late log re-freezes once ANY containing board (not just this
    // one) seals AFTER it was created; check the general immunity rule
    // before tombstoning, not just this board's own provenance.
    const immuneWindows = await getSealImmuneWindowsForTask(effectiveTaskId);
    if (isEventSealImmune(entry, immuneWindows)) return false;

    await db.taskEvents.update(entry.id, {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (entry.version ?? 1) + 1,
    });
    const savedEvent = await db.taskEvents.get(entry.id);
    if (savedEvent) await addToSyncQueue('taskEvents', entry.id, SyncOperationType.DELETE, savedEvent, 0);

    if (entry.kind === 'completion') {
      await restampCaches(effectiveTaskId, now);
      await applyLateLogSideEffects([effectiveTaskId]);
      return true;
    }

    // increment — effectiveTaskId is always a ROOT (standalone counter or a
    // shared-counter source): correct its lifetime `currentCount` by
    // subtracting the reversed entry's delta (raw-appended events bypass the
    // cache restamp — see `insertIncrementEventRaw`'s docstring), preserving
    // the one-way completion latch, exactly like `undoLastCounterLog`.
    const root = await db.tasks.get(effectiveTaskId);
    if (root) {
      const entryDelta = entry.delta ?? 0;
      const currentCount = root.currentCount ?? 0;
      const newRootCount = Math.max(0, currentCount - entryDelta);
      const rootWasCompleted = root.isCompleted;
      const rootNowCompleted =
        rootWasCompleted || (root.maxCount != null && newRootCount >= root.maxCount);

      await db.tasks.update(effectiveTaskId, {
        currentCount: newRootCount,
        isCompleted: rootNowCompleted,
        completedAt: !rootWasCompleted && rootNowCompleted ? now : root.completedAt,
        updatedAt: now,
        version: (root.version ?? 0) + 1,
      });
      const savedRoot = await db.tasks.get(effectiveTaskId);
      if (savedRoot) await addToSyncQueue('tasks', effectiveTaskId, SyncOperationType.UPDATE, savedRoot, 0);

      await refreshDerivedBaselines(
        effectiveTaskId,
        events.map((e) => (e.id === entry.id ? { ...e, isDeleted: true } : e)),
      );
      await propagateToLinkedRows(effectiveTaskId, newRootCount, now, entry.occurredAt);
    }

    await applyLateLogSideEffects([effectiveTaskId, taskId]);
    return true;
  });
}
