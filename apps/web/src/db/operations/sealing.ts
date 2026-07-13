import { db } from '../internal';
import {
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
 * Seal a board (docs §Sealing → Lifecycle step 3). One transaction: run the
 * derivation pass one final time, freeze `sealedAt` + `sealedCompletedCells` +
 * the derived stats, bump `version`/`updatedAt`, enqueue the Board sync.
 * `status` is untouched. Idempotent — already-sealed / missing / deleted boards
 * are a no-op.
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
    // Local-only re-derivation: snapshot fields only, no version bump / enqueue.
    await db.boards.update(boardId, {
      sealedCompletedCells: snapshot.sealedCompletedCells,
      completedTasks: snapshot.completedTasks,
      linesCompleted: snapshot.linesCompleted,
      completedLineIds: snapshot.completedLineIds,
    });
  }
}
