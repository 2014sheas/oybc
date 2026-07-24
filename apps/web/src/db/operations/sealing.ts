import { db } from '../internal';
import {
  BoardStatus,
  SyncOperationType,
  computeBoardStatsUpdate,
  computeSealedCompletedCells,
  findAffectedBoardIds,
  findTransitiveParentCompounds,
  isBoardPastBackstop,
  type Board,
  type BoardTask,
  type Task,
  type CompoundChild,
  type TaskEvent,
  type WindowEvaluationContext,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks } from './boardTasks';

/**
 * Windowed Completion — board sealing data layer
 * (docs/WINDOWED_COMPLETION.md §Sealing).
 *
 * Three surfaces:
 *   - `sealBoard` — the seal transaction (user Seal action + migration + the
 *     backstop below): stamp `sealedAt`, freeze the snapshot from the event
 *     union, bump `version`, enqueue Board sync. Idempotent.
 *   - `runBackstopAutoSeal` — the lazy app-open backstop check: seal every
 *     board past its timeframe-scaled deadline via `sealBoard`.
 *   - `reDeriveSealedBoardsForTasks` — the pull-path re-derivation hook: when
 *     late pre-seal events for a placed task arrive, re-derive the sealed
 *     board's snapshot deterministically from the (bounded) event union. No
 *     `version` bump, no sync enqueue — the input converges, so every device
 *     converges independently (docs §Seal snapshots re-derive).
 *
 * The frozen snapshot is a pure function of the events in `[startDate, sealedAt]`.
 * We bound the upper end explicitly (events with `occurredAt > sealedAt` belong
 * to the NEXT window's board and must never leak into a sealed record — the
 * exact cross-window bleed this whole design prevents). `resolveTaskWindowState`
 * has only a start bound, so the upper bound is applied by pre-filtering events.
 */

/** The lookups the shared derivation kernel needs, loaded once. */
interface DerivationLookups {
  childrenByCompound: Record<string, CompoundChild[]>;
  taskById: Record<string, Task>;
  allBoards: Board[];
  allBoardTasks: BoardTask[];
  /** ALL non-deleted events grouped by taskId (unbounded on the upper end). */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/**
 * Load the workspace lookups for derivation + a full non-deleted-event map.
 * Callers apply their own upper-bound filter to the event map per board.
 */
async function loadDerivationLookups(): Promise<DerivationLookups> {
  const allChildren = await fetchAllCompoundChildren();
  const allBoardTasks = await fetchAllBoardTasks();
  const allTasks = await db.tasks.toArray();
  const allBoards = await db.boards.toArray();
  const events = await db.taskEvents.toArray();

  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    if (e.isDeleted) continue;
    (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);

  return { childrenByCompound, taskById, allBoards, allBoardTasks, eventsByTaskId };
}

/**
 * Build a windowed-evaluation context for a board sealed at `sealedAtMs`,
 * bounding every task's events to `occurredAt <= sealedAtMs` (the `[startDate,
 * sealedAt]` window). At seal time `sealedAtMs = now`, so no event is dropped
 * (nothing is logged in the future) — the filter matters for re-derivation.
 */
function boundedWindowContext(
  eventsByTaskId: Record<string, TaskEvent[]>,
  sealedAtMs: number,
): WindowEvaluationContext {
  const bounded: Record<string, TaskEvent[]> = {};
  for (const [taskId, evs] of Object.entries(eventsByTaskId)) {
    const kept = evs.filter((e) => new Date(e.occurredAt).getTime() <= sealedAtMs);
    if (kept.length > 0) bounded[taskId] = kept;
  }
  return { eventsByTaskId: bounded };
}

/** The frozen fields written to a sealed board row. */
interface SealSnapshot {
  completedTasks: number;
  linesCompleted: number;
  completedLineIds: string[];
  sealedCompletedCells: number[];
}

/**
 * Compute the frozen snapshot for `board` from the event union bounded at
 * `sealedAtMs` (docs §Seal snapshots re-derive). Deterministic: same converged
 * union → same snapshot on any device.
 */
function computeSealSnapshot(
  board: Board,
  lookups: DerivationLookups,
  sealedAtMs: number,
): SealSnapshot {
  const boardTasksOnBoard = lookups.allBoardTasks.filter((bt) => bt.boardId === board.id);
  const windowContext = boundedWindowContext(lookups.eventsByTaskId, sealedAtMs);
  const stats = computeBoardStatsUpdate(
    board,
    boardTasksOnBoard,
    lookups.childrenByCompound,
    lookups.taskById,
    lookups.allBoards,
    windowContext,
  );
  const cells = computeSealedCompletedCells(
    board,
    boardTasksOnBoard,
    lookups.childrenByCompound,
    lookups.taskById,
    lookups.allBoards,
    windowContext,
  );
  return {
    completedTasks: stats.completedTasks,
    linesCompleted: stats.linesCompleted,
    completedLineIds: stats.completedLineIds,
    sealedCompletedCells: cells,
  };
}

/**
 * Apply the deterministic board-status transition for a sealed snapshot onto a
 * pending board `update`, mirroring the LIVE cascade's completion predicate
 * (orchestration.ts `runBoardCascadeForTasks`: `isGreenlog = completedTasks >=
 * boardSize²`; greenlog + ACTIVE → COMPLETED; !greenlog + COMPLETED → ACTIVE).
 *
 * Without this, a board sealed while ACTIVE whose FINAL completing event only
 * arrives (via pull) after the seal would re-derive to fully-complete stats yet
 * stay frozen ACTIVE forever — and a greenlog-trigger ACHIEVEMENT (which gates
 * on `status === COMPLETED`) would never fire. This is derivation OUTPUT inside
 * the deterministic pull path, so it does not violate "sealed boards only mutate
 * via deterministic pull-path re-derivation" — it IS that path.
 *
 * `completedAtTs` is the seal instant (`board.sealedAt`), NOT wall-clock `now`,
 * so every device computes the same status/completedAt from the same converged
 * event union — no LWW/version race.
 */
function applySealedStatus(
  board: Board,
  snapshot: SealSnapshot,
  update: Partial<Board>,
  completedAtTs: string,
): void {
  const isGreenlog = snapshot.completedTasks >= board.boardSize * board.boardSize;
  if (isGreenlog && board.status === BoardStatus.ACTIVE) {
    update.status = BoardStatus.COMPLETED;
    update.completedAt = completedAtTs;
  } else if (!isGreenlog && board.status === BoardStatus.COMPLETED) {
    update.status = BoardStatus.ACTIVE;
    update.completedAt = undefined;
  }
}

/**
 * Seal a board (docs §Sealing → Lifecycle step 3). One transaction: run the
 * derivation pass one final time, freeze `sealedAt` + `sealedCompletedCells` +
 * the derived stats, bump `version`/`updatedAt`, enqueue the Board sync.
 * `status`/`completedAt` are set deterministically from the sealed snapshot via
 * the SAME greenlog predicate the live cascade uses (see `applySealedStatus`).
 * Idempotent — already-sealed / missing / deleted boards are a no-op.
 *
 * @param boardId The board to seal.
 * @param now     The seal timestamp (defaults to wall-clock).
 * @returns `true` if the board was sealed by this call; `false` if it was a
 *          no-op (missing / deleted / already sealed).
 */
export async function sealBoard(boardId: string, now: string = currentTimestamp()): Promise<boolean> {
  let sealed = false;
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      const board = await db.boards.get(boardId);
      if (!board || board.isDeleted || board.sealedAt) return; // idempotent

      const lookups = await loadDerivationLookups();
      const snapshot = computeSealSnapshot(board, lookups, new Date(now).getTime());

      const update: Partial<Board> = {
        sealedAt: now,
        sealedCompletedCells: snapshot.sealedCompletedCells,
        completedTasks: snapshot.completedTasks,
        linesCompleted: snapshot.linesCompleted,
        completedLineIds: snapshot.completedLineIds,
        updatedAt: now,
        version: (board.version ?? 1) + 1,
      };
      // Deterministic status from the sealed snapshot. `now` is the sealedAt
      // instant being stamped, so this matches the re-derivation path's source.
      applySealedStatus(board, snapshot, update, now);
      await db.boards.update(boardId, update);
      const updated = await db.boards.get(boardId);
      if (updated) await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, updated, 0);
      sealed = true;
    },
  );
  return sealed;
}

/**
 * Lazy auto-seal backstop (docs §Sealing → Lifecycle step 4). On app-open /
 * Boards-visible, seal every board past its timeframe-scaled backstop deadline
 * (keyed off `max(endDate, activatedAt)`) with no prompt. This is the same
 * lazy-detection posture as recurring-board spawn — no background scheduling,
 * no DB write without the user having opened the app.
 *
 * @param userId The authenticated user's uid.
 * @param now    The check timestamp (defaults to wall-clock).
 * @returns The ids of boards sealed by this pass.
 */
export async function runBackstopAutoSeal(
  userId: string,
  now: string = currentTimestamp(),
): Promise<string[]> {
  const nowMs = new Date(now).getTime();
  const boards = await db.boards.filter((b) => b.userId === userId && !b.isDeleted).toArray();
  const due = boards.filter((b) => isBoardPastBackstop(b, nowMs));

  const sealedIds: string[] = [];
  for (const b of due) {
    if (await sealBoard(b.id, now)) sealedIds.push(b.id);
  }
  return sealedIds;
}

/** Order-independent string-array equality (for comparing completedLineIds). */
function sameStringSet(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  const sa = new Set(a);
  for (const x of b) if (!sa.has(x)) return false;
  return true;
}

/**
 * Windowed Completion — one-shot self-heal for existing boards (app-open, lazy).
 *
 * Before this fix, the edit/structure cascades (add/remove/reorder/edit board +
 * board-task) recomputed `completedLineIds`/`linesCompleted`/`completedTasks`
 * from the LIFETIME `Task.isCompleted` cache instead of the board's window, so a
 * cell holding a task that is lifetime-complete but NOT complete in THIS board's
 * `[startDate, ∞)` window could be counted into a bingo line while rendering
 * un-green (a phantom bingo). Boards edited under the old code carry that stale
 * state on disk. This pass recomputes each live board's stats WINDOWED and, when
 * anything changed, writes the corrected row (version bump + sync enqueue).
 *
 * Scope: the user's non-deleted, non-sealed boards in ACTIVE or COMPLETED status
 * (DRAFT boards have no meaningful derived stats yet; sealed boards are frozen
 * and only ever re-derive via the deterministic pull path). Idempotent — once a
 * board has converged the recompute equals the stored value and it is skipped,
 * so re-running on every app-open is a no-op and emits no sync churn.
 *
 * Lazy/app-open only, mirroring the backstop + recurring-spawn posture — no
 * background scheduling, no DB write without the user having opened the app.
 *
 * @param userId The authenticated user's uid.
 * @param now    The write timestamp (defaults to wall-clock).
 * @returns The ids of boards this pass corrected.
 */
export async function reDeriveActiveBoards(
  userId: string,
  now: string = currentTimestamp(),
): Promise<string[]> {
  const boards = await db.boards
    .filter(
      (b) =>
        b.userId === userId &&
        !b.isDeleted &&
        !b.sealedAt &&
        // Every non-sealed status is in scope. DRAFT/ARCHIVED matter because
        // achievement bingo-triggers read ANY non-deleted board's persisted
        // lines — a stale phantom line on a draft/archived board would poison
        // a watcher forever if the heal skipped it. Status transitions below
        // gate on ACTIVE/COMPLETED, so drafts/archived only get stats
        // corrected, never status-flipped.
        (b.status === BoardStatus.ACTIVE ||
          b.status === BoardStatus.COMPLETED ||
          b.status === BoardStatus.ARCHIVED ||
          b.status === BoardStatus.DRAFT),
    )
    .toArray();
  if (boards.length === 0) return [];

  // Build the derivation lookups + full non-deleted event map ONCE, before the
  // rw transaction (so `db.taskEvents` need not be in the transaction scope —
  // matches the live-cascade pattern). Active boards have no seal upper bound;
  // the window is `[startDate, ∞)`, so the unbounded event map is the context.
  const lookups = await loadDerivationLookups();
  const windowContext: WindowEvaluationContext = { eventsByTaskId: lookups.eventsByTaskId };

  const rederivedIds: string[] = [];

  await db.transaction('rw', [db.boards, db.syncQueue], async () => {
    for (const staleBoard of boards) {
      // Re-read the row INSIDE the txn: the heal fires at app-open, exactly
      // when the initial sync pull bursts — computing `changed`/version/status
      // from the pre-txn snapshot could clobber a just-pulled newer row (and
      // write a version LOWER than remote, silently losing LWW on the push).
      const board = await db.boards.get(staleBoard.id);
      if (!board || board.isDeleted || board.sealedAt) continue;
      const boardTasksOnBoard = lookups.allBoardTasks.filter((bt) => bt.boardId === board.id);
      const stats = computeBoardStatsUpdate(
        board,
        boardTasksOnBoard,
        lookups.childrenByCompound,
        lookups.taskById,
        lookups.allBoards,
        windowContext,
      );

      const isGreenlog = stats.completedTasks >= board.boardSize * board.boardSize;
      let nextStatus = board.status;
      let nextCompletedAt = board.completedAt;
      if (isGreenlog && board.status === BoardStatus.ACTIVE) {
        nextStatus = BoardStatus.COMPLETED;
        nextCompletedAt = now;
      } else if (!isGreenlog && board.status === BoardStatus.COMPLETED) {
        nextStatus = BoardStatus.ACTIVE;
        nextCompletedAt = undefined;
      }

      const changed =
        !sameStringSet(board.completedLineIds ?? [], stats.completedLineIds) ||
        (board.completedTasks ?? 0) !== stats.completedTasks ||
        (board.linesCompleted ?? 0) !== stats.linesCompleted ||
        board.status !== nextStatus;
      if (!changed) continue;

      const update: Partial<Board> = {
        completedTasks: stats.completedTasks,
        linesCompleted: stats.linesCompleted,
        completedLineIds: stats.completedLineIds,
        status: nextStatus,
        completedAt: nextCompletedAt,
        updatedAt: now,
        version: (board.version ?? 1) + 1,
      };
      await db.boards.update(board.id, update);
      const updated = await db.boards.get(board.id);
      if (updated) await addToSyncQueue('boards', board.id, SyncOperationType.UPDATE, updated, 0);
      rederivedIds.push(board.id);
    }
  });

  return rederivedIds;
}

/**
 * Pull-path seal re-derivation (docs §Seal snapshots re-derive from the event
 * union). For every sealed board that places one of `changedTaskIds` (directly
 * or via a compound), re-derive its frozen snapshot from the converged event
 * union bounded at its own `sealedAt`. Local-only: overwrites the snapshot
 * fields WITHOUT bumping `version` or enqueuing sync (pull paths don't author
 * writes; the input converges, so every device converges independently).
 *
 * MUST run inside the caller's pull transaction (covering boards / boardTasks /
 * tasks / compoundChildren / taskEvents), after event rows are upserted.
 *
 * @param changedTaskIds The tasks whose event set changed in this pull cycle.
 */
export async function reDeriveSealedBoardsForTasks(
  changedTaskIds: Iterable<string>,
): Promise<void> {
  const changed = new Set(changedTaskIds);
  if (changed.size === 0) return;

  const lookups = await loadDerivationLookups();

  // A sealed board is affected if it places a changed task directly or via a
  // compound that transitively contains it. Reuse the same reachability the
  // live cascade uses by walking placements. (Static imports — a dynamic
  // `await import()` here would break the ambient Dexie transaction.)
  const allChildren = Object.values(lookups.childrenByCompound).flat();

  const affectedBoardIds = new Set<string>();
  for (const taskId of changed) {
    const parents = findTransitiveParentCompounds(taskId, allChildren);
    for (const id of findAffectedBoardIds(taskId, parents, lookups.allBoardTasks)) {
      affectedBoardIds.add(id);
    }
  }

  for (const boardId of affectedBoardIds) {
    const board = await db.boards.get(boardId);
    if (!board || board.isDeleted || !board.sealedAt) continue;
    const snapshot = computeSealSnapshot(board, lookups, new Date(board.sealedAt).getTime());
    // Local-only re-derivation: snapshot fields + deterministic status, no
    // version bump / enqueue. `status`/`completedAt` derive from the converged
    // event union via the same greenlog predicate the live cascade uses, with
    // `completedAt` stamped from the deterministic `sealedAt` instant — so a
    // board sealed while ACTIVE whose final completing event lands post-seal
    // converges to COMPLETED on every device (no LWW race).
    const update: Partial<Board> = {
      sealedCompletedCells: snapshot.sealedCompletedCells,
      completedTasks: snapshot.completedTasks,
      linesCompleted: snapshot.linesCompleted,
      completedLineIds: snapshot.completedLineIds,
    };
    applySealedStatus(board, snapshot, update, board.sealedAt);
    await db.boards.update(boardId, update);
  }
}
