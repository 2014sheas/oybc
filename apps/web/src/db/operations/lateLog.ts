import { db } from '../internal';
import {
  TaskType,
  boardWindowEnd,
  evaluateCompound,
  isEventOwningTask,
  isEventSealImmune,
  isQuantizedCount,
  isWindowStampedDerived,
  quantizeCount,
  lateLogOccurredAt,
  selectClosedBoardLateLogs,
  SyncOperationType,
  type Board,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { resolveClosedBoardCounterDisplay } from '../adapters';
import { addToSyncQueue } from './syncQueue';
import {
  appendCompletionEvent,
  appendIncrementEvent,
  insertIncrementEventRaw,
  computeTaskCachesFromEvents,
  getSealImmuneWindowsForTask,
} from './taskEvents';
import { refreshDerivedBaselines, withWindowStampedDerived } from './derivedCounters';
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
export type LateLogErrorKind = 'boardNotFound' | 'boardNotClosed' | 'taskNotFound' | 'wrongType' | 'ruleNotMet';

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
  // A shared-counter ROOT is never placed: live-cascade from its
  // window-stamped derived rows too (iOS `reDeriveAfterLateLogWrite` reaches
  // the same boards via `boardIdsReachedByTasks`).
  await runBoardCascadeForTasks(await withWindowStampedDerived(new Set(ids)), { lateLog: true });
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
 * @param delta   A positive 2dp amount to log.
 * @param now     Write timestamp; the event is stamped at the board's
 *   `endDate`.
 */
export async function lateLogIncrement(
  boardId: string,
  taskId: string,
  delta: number,
  now: string = currentTimestamp(),
): Promise<void> {
  if (!isQuantizedCount(delta) || delta <= 0) {
    throw new Error('lateLogIncrement: delta must be a positive 2dp number');
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
    const newRootCount = quantizeCount((root.currentCount ?? 0) + delta);
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
  /** Required when `kind === 'increment'`; a positive 2dp number. */
  delta?: number;
}

/**
 * Late-log a COMPOUND task's staged child parts on a closed board (D7). The
 * caller (the late-log sheet) stages which children to mark; this choke
 * point re-validates each action structurally (a real, non-deleted,
 * event-owning direct child of the right type), drops the rest, and then
 * commits ONLY if the compound's rule is met under the staged state
 * ({@link previewLateLogCompoundRule} is the sheet's read-only twin) —
 * otherwise it throws `LateLogError('ruleNotMet')` and writes nothing.
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

    const planned = await planCompoundActions(board, compoundTaskId, actions);
    const occurredAt = lateLogOccurredAt(board, now);

    // Parity with iOS `lateLogCompoundParts`: the rule is enforced HERE, not
    // only by the sheet's preview — a rule-unmet commit writes nothing.
    if (!(await isCompoundRuleMetOnClosedBoard(board, compound, planned, occurredAt, now))) {
      throw new LateLogError('ruleNotMet', compoundTaskId);
    }

    const touchedTaskIds = new Set<string>([compoundTaskId]);
    for (const action of planned) {
      if (action.kind === 'completion') {
        await appendCompletionEvent(action.childTaskId, boardId, now, occurredAt);
      } else {
        await appendIncrementEvent(action.childTaskId, action.delta as number, boardId, now, occurredAt);
      }
      touchedTaskIds.add(action.childTaskId);
    }

    await applyLateLogSideEffects([...touchedTaskIds]);
  });
}

/**
 * Structural re-validation of a compound late-log request: keeps only
 * actions on a real, non-deleted, event-owning DIRECT child of the right type
 * (NORMAL → completion not already in the sealed window; plain COUNTING →
 * positive 2dp increment). Everything else is silently dropped.
 */
async function planCompoundActions(
  board: Board,
  compoundTaskId: string,
  actions: ReadonlyArray<LateLogCompoundAction>,
): Promise<LateLogCompoundAction[]> {
  const links = await db.compoundChildren
    .where('compoundTaskId')
    .equals(compoundTaskId)
    .filter((c) => !c.isDeleted)
    .toArray();
  const childIds = new Set(links.map((l) => l.childTaskId));
  const planned: LateLogCompoundAction[] = [];
  for (const action of actions) {
    if (!childIds.has(action.childTaskId)) continue;
    const child: Task | undefined = await db.tasks.get(action.childTaskId);
    if (!child || child.isDeleted || !isEventOwningTask(child)) continue;
    if (action.kind === 'completion') {
      if (child.type !== TaskType.NORMAL) continue;
      const events = await db.taskEvents.where('taskId').equals(child.id).toArray();
      if (hasCompletionInSealedWindow(events, board.startDate, board.endDate, board.sealedAt as string)) continue;
      planned.push({ childTaskId: child.id, kind: 'completion' });
    } else {
      if (child.type !== TaskType.COUNTING || child.sharedCounterId != null) continue;
      if (!isQuantizedCount(action.delta as number) || (action.delta as number) <= 0) continue;
      planned.push({ childTaskId: child.id, kind: 'increment', delta: action.delta });
    }
  }
  return planned;
}

/**
 * Whether `compound`'s rule is met on the closed `board` once the `planned`
 * child events are added — the shared windowed `evaluateCompound` over the
 * board's window `[startDate, endDate]`, with every event bounded at
 * `sealedAt` (the sealed snapshot's own bound) plus the planned events as
 * synthetic rows. Pure read: nothing is written.
 */
async function isCompoundRuleMetOnClosedBoard(
  board: Board,
  compound: Task,
  planned: ReadonlyArray<LateLogCompoundAction>,
  occurredAt: string,
  now: string,
): Promise<boolean> {
  const sealedMs = new Date(board.sealedAt as string).getTime();
  const [tasks, links, events] = await Promise.all([
    db.tasks.toArray(),
    db.compoundChildren.filter((c) => !c.isDeleted).toArray(),
    db.taskEvents.filter((e) => !e.isDeleted).toArray(),
  ]);
  const taskById: Record<string, Task> = {};
  for (const t of tasks) taskById[t.id] = t;
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const l of links) (childrenByCompound[l.compoundTaskId] ??= []).push(l);
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    if (new Date(e.occurredAt).getTime() > sealedMs) continue;
    (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  planned.forEach((a, i) => {
    (eventsByTaskId[a.childTaskId] ??= []).push({
      id: `staged-${i}`,
      userId: compound.userId,
      taskId: a.childTaskId,
      kind: a.kind,
      ...(a.kind === 'increment' ? { delta: a.delta } : {}),
      occurredAt,
      boardId: board.id,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    } as TaskEvent);
  });
  return evaluateCompound(compound, childrenByCompound, taskById, {
    windowStart: board.startDate,
    windowEnd: boardWindowEnd(board),
    eventsByTaskId,
  });
}

/**
 * Read-only preview for the late-log sheet's compound body: would committing
 * `actions` meet the compound's rule on this closed board? Same planning +
 * evaluation the commit ({@link lateLogCompoundParts}) enforces, so the
 * "Mark done on board" button can never enable for a commit the DB rejects.
 *
 * @param boardId        The closed board.
 * @param compoundTaskId The compound placed on it.
 * @param actions        The currently staged per-child actions.
 * @returns `false` for a board that isn't closed or a non-compound task.
 */
export async function previewLateLogCompoundRule(
  boardId: string,
  compoundTaskId: string,
  actions: ReadonlyArray<LateLogCompoundAction>,
): Promise<boolean> {
  const board = await db.boards.get(boardId);
  if (!board || board.isDeleted || board.sealedAt == null) return false;
  const compound = await db.tasks.get(compoundTaskId);
  if (!compound || compound.isDeleted || compound.type !== TaskType.COMPOUND) return false;
  const now = currentTimestamp();
  const planned = await planCompoundActions(board, compoundTaskId, actions);
  return isCompoundRuleMetOnClosedBoard(board, compound, planned, lateLogOccurredAt(board, now), now);
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
      const newRootCount = Math.max(0, quantizeCount(currentCount - entryDelta));
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

// ─── Read model for the late-log sheet (D15) ───────────────────────────────

/** What the late-log sheet needs to render a NORMAL or COUNTING square. */
export interface ClosedBoardSquareState {
  /** Whether the square is already green under the sealed-bounded window
   *  (`[startDate, min(endDate, sealedAt)]`) — from ANY source, immune
   *  history or a late log. */
  isGreen: boolean;
  /** For COUNTING only: the sealed-bounded windowed count (D16); `0` for NORMAL. */
  count: number;
  /** Late logs made directly on this board for this task (root-resolved for
   *  a window-stamped derived square), newest first — `[]` means nothing to
   *  undo. */
  lateLogs: TaskEvent[];
  /** The event-owning id whose events this state was READ from — the tapped
   *  task for NORMAL/plain COUNTING, or the ROOT for a window-stamped derived
   *  square (derived rows own no events). Read-side only: the write/undo
   *  entry points (`lateLogIncrement`, `undoLateLog`, …) take the TAPPED
   *  (placed) task id and resolve the root themselves. */
  effectiveTaskId: string;
}

/**
 * Read-only state for the late-log sheet's normal/counting body — one query,
 * reused by `useLiveQuery` so the sheet updates as events change. Returns
 * `null` when the board isn't closed or the task can't be late-logged from
 * this sheet (missing/deleted/wrong type/hub-linked derived — OQ2).
 *
 * @param boardId The closed board.
 * @param taskId  The tapped square's task (NORMAL or COUNTING).
 */
export async function readClosedBoardSquareState(
  boardId: string,
  taskId: string,
): Promise<ClosedBoardSquareState | null> {
  const board = await db.boards.get(boardId);
  if (!board || board.isDeleted || board.sealedAt == null) return null;
  const task = await db.tasks.get(taskId);
  if (!task || task.isDeleted) return null;

  if (task.type === TaskType.NORMAL) {
    const events = await db.taskEvents.where('taskId').equals(taskId).toArray();
    const isGreen = hasCompletionInSealedWindow(events, board.startDate, board.endDate, board.sealedAt);
    const lateLogs = selectClosedBoardLateLogs(events, board, taskId);
    return { isGreen, count: 0, lateLogs, effectiveTaskId: taskId };
  }

  if (task.type !== TaskType.COUNTING) return null;
  if (task.sharedCounterId != null && !isWindowStampedDerived(task)) return null; // hub-linked — OQ2

  const effectiveTaskId = task.sharedCounterId ?? taskId;
  const rootEvents = await db.taskEvents.where('taskId').equals(effectiveTaskId).toArray();
  // Same resolver the closed grid cell uses (D16), so the sheet's readout can
  // never disagree with the square: windowed to `[startDate, min(endDate,
  // sealedAt)]` — never the prior windows' or the overtime gap's events.
  const { displayed: count, isCompleted: isGreen } = resolveClosedBoardCounterDisplay(
    task,
    { [effectiveTaskId]: rootEvents.filter((e) => !e.isDeleted) },
    board,
  );
  const lateLogs = selectClosedBoardLateLogs(rootEvents, board, effectiveTaskId);
  return { isGreen, count, lateLogs, effectiveTaskId };
}

/**
 * Every non-deleted TaskEvent for a set of task ids — the late-log
 * compound sheet's read seam (its parts list needs each direct child's
 * events to resolve current completion). `db/operations` is the only
 * layer allowed to touch the raw Dexie table (B3, issue #284); this lets
 * `LateLogSheet.tsx` stay off `db/internal`.
 *
 * @param taskIds Candidate task ids (deleted rows are filtered internally).
 */
export async function fetchLiveEventsForTaskIds(taskIds: ReadonlyArray<string>): Promise<TaskEvent[]> {
  if (taskIds.length === 0) return [];
  const events = await db.taskEvents.where('taskId').anyOf([...taskIds]).toArray();
  return events.filter((e) => !e.isDeleted);
}

