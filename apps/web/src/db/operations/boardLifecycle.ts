import { db } from '../internal';
import {
  SyncOperationType,
  isBoardClosingOut,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  findWatcherTaskIds,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { sealBoard, reDeriveSealedBoardsForTasks } from './sealing';
import { runBoardCascadeForBoardId, runBoardCascadeForTasks } from './orchestration';

/**
 * Board Edit redesign slice 4 — Close / Reopen + the achievement-watcher
 * fan-out (docs/BOARD_EDIT_REDESIGN.md §The model; plan D3, D6, D8, D12).
 *
 * `closeBoard` is the existing seal path verbatim (D3): identical snapshot
 * semantics to the backstop / migration paths, by construction (one
 * function underneath). `reopenBoard` clears the seal + its frozen
 * snapshot, stamps `reopenedAt` (never cleared — a manually reopened board
 * never auto-closes again, D1/D4), and re-runs the LIVE derivation for that
 * one board. Both then fan out to any ACHIEVEMENT task watching the board
 * (D8), so a Close / Reopen / late log always leaves every watcher's own
 * board consistent in the SAME transaction.
 */

/** Board metadata writes this menu-level guard covers. */
export type BoardLifecycleErrorKind = 'notFound' | 'notClosable' | 'notReopenable';

/**
 * Thrown by `closeBoard` / `reopenBoard` when the board is missing/deleted,
 * or isn't in the state the action requires (e.g. Close on a board that
 * hasn't ended yet, or Reopen on a board that isn't sealed). The caller
 * shows a notice, matching `BoardNotEditableError`'s existing UX pattern.
 */
export class BoardLifecycleError extends Error {
  readonly kind: BoardLifecycleErrorKind;

  constructor(kind: BoardLifecycleErrorKind, boardId: string) {
    super(`Board ${boardId}: ${kind}`);
    this.name = 'BoardLifecycleError';
    this.kind = kind;
  }
}

/** The tables every lifecycle transaction below touches. */
const LIFECYCLE_TABLES = [
  db.boards,
  db.boardTasks,
  db.tasks,
  db.compoundChildren,
  db.taskEvents,
  db.syncQueue,
] as const;

/**
 * Close a board (D3, the closing-out banner's "Close out" AND the title-row
 * menu's "Close board" both call this): the existing seal transaction
 * verbatim, plus an achievement-watcher refresh in the SAME transaction.
 * Idempotent — already-closed boards no-op (mirrors `sealBoard`).
 *
 * @param boardId The board to close.
 * @param now     The close timestamp (defaults to wall-clock).
 * @throws {BoardLifecycleError} `notFound` (missing/deleted) or
 *   `notClosable` (not yet ended, a draft, or indefinite — the guard is
 *   exactly {@link isBoardClosingOut}).
 */
export async function closeBoard(boardId: string, now: string = currentTimestamp()): Promise<void> {
  await db.transaction('rw', LIFECYCLE_TABLES, async () => {
    const board = await db.boards.get(boardId);
    if (!board || board.isDeleted) throw new BoardLifecycleError('notFound', boardId);
    if (board.sealedAt != null) return; // already closed — idempotent no-op, matches sealBoard
    if (!isBoardClosingOut(board, new Date(now).getTime())) {
      throw new BoardLifecycleError('notClosable', boardId);
    }
    const sealed = await sealBoard(boardId, now);
    if (sealed) await refreshWatchersForBoards([boardId]);
  });
}

/**
 * Reopen a closed board (D6): clears `sealedAt` + `sealedCompletedCells`,
 * stamps `reopenedAt` (never cleared — a manually reopened board never
 * auto-closes again), bumps `version`, enqueues sync, then re-runs the LIVE
 * derivation for this one board (recomputing `completedTasks` /
 * `linesCompleted` / `completedLineIds` / status from events in
 * `[startDate, endDate]` — exactly {@link runBoardCascadeForBoardId}, which
 * naturally sees the just-cleared `sealedAt` inside this same transaction),
 * then refreshes any achievement watcher of this board (D8).
 *
 * Spawns nothing (no template / recurring write). Window-stamped derived
 * counters have nothing to unfreeze here — `isFrozenDerivedRow` keys on
 * `now > row.endDate`, not `sealedAt` (docs/BOARD_SOURCES.md §Plan B2 notes).
 *
 * @param boardId The board to reopen.
 * @param now     The reopen timestamp (defaults to wall-clock).
 * @throws {BoardLifecycleError} `notFound` (missing/deleted) or
 *   `notReopenable` (not currently sealed).
 */
export async function reopenBoard(boardId: string, now: string = currentTimestamp()): Promise<void> {
  await db.transaction('rw', LIFECYCLE_TABLES, async () => {
    const board = await db.boards.get(boardId);
    if (!board || board.isDeleted) throw new BoardLifecycleError('notFound', boardId);
    if (board.sealedAt == null) throw new BoardLifecycleError('notReopenable', boardId);

    await db.boards.update(boardId, {
      sealedAt: undefined,
      sealedCompletedCells: undefined,
      reopenedAt: now,
      updatedAt: now,
      version: (board.version ?? 1) + 1,
    });
    const updated = await db.boards.get(boardId);
    if (updated) await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, updated, 0);

    // Re-derive this board LIVE now that `sealedAt` is clear (read inside
    // this same transaction, so it sees the write above).
    await runBoardCascadeForBoardId(boardId);
    await refreshWatchersForBoards([boardId]);
  });
}

/**
 * Board Edit redesign slice 4 (D12) — relax the editable guard for the two
 * metadata writes the closed-board menu still offers (Repeat, Archive):
 * throws only when the board is missing or deleted, unlike
 * `assertBoardEditable` (`boards.ts`), which also throws when sealed.
 * Archive only ever writes `status` (never a snapshot field); Repeat's
 * back-stamp writes template provenance only — neither touches the frozen
 * snapshot, so both are safe on a closed board.
 *
 * @param boardId Board about to have its metadata (not squares) written.
 * @throws {BoardLifecycleError} `notFound` when missing or deleted.
 */
export async function assertBoardMetadataWritable(boardId: string): Promise<void> {
  const board = await db.boards.get(boardId);
  if (!board || board.isDeleted) throw new BoardLifecycleError('notFound', boardId);
}

/**
 * The board ids reachable from `changedTaskIds` (D9 / D8's watcher-refresh
 * seed): the same placement reachability {@link reDeriveSealedBoardsForTasks}
 * uses (direct placement, a placed compound ancestor, or — for a
 * shared-counter root — a window-stamped derived counter linked to it),
 * exposed here so callers can seed {@link refreshWatchersForBoards} with the
 * boards whose stats a write actually touched.
 *
 * @param changedTaskIds The tasks whose event set (or derived state) changed.
 */
export async function resolveAffectedBoardIds(changedTaskIds: Iterable<string>): Promise<Set<string>> {
  const ids = [...new Set(changedTaskIds)];
  if (ids.length === 0) return new Set();

  const boardTasks = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
  const children = await db.compoundChildren.filter((c) => !c.isDeleted).toArray();

  const affected = new Set<string>();
  for (const taskId of ids) {
    const parents = findTransitiveParentCompounds(taskId, children);
    for (const id of findAffectedBoardIds(taskId, parents, boardTasks)) affected.add(id);
  }
  return affected;
}

/**
 * Board Edit redesign slice 4 (D8) — refresh every ACHIEVEMENT task watching
 * any of `changedBoardIds` (specific-board or recurring-template mode, via
 * {@link findWatcherTaskIds}), re-deriving the board(s) that PLACE each
 * watcher square: a live cascade for unsealed boards
 * ({@link runBoardCascadeForTasks}, which itself skips sealed boards) and the
 * deterministic sealed re-derive ({@link reDeriveSealedBoardsForTasks}) for
 * closed ones. Iterates to a fixpoint over newly-changed boards (a watcher
 * board's own stats changing can itself be watched by another achievement),
 * bounded by a visited set — `hasCycle` already forbids an authoring cycle,
 * this is the runtime belt.
 *
 * MUST be called inside the caller's transaction (reads/writes `boards`,
 * `boardTasks`, `tasks`, `compoundChildren`, `taskEvents`, `syncQueue`).
 *
 * @param changedBoardIds Boards whose persisted `status` / `linesCompleted`
 *   just changed (Close, Reopen, or any late-log / undo commit).
 */
export async function refreshWatchersForBoards(changedBoardIds: Iterable<string>): Promise<void> {
  const visited = new Set<string>();
  let frontier = new Set(changedBoardIds);

  while (frontier.size > 0) {
    for (const id of frontier) visited.add(id);

    const allTasks = await db.tasks.toArray();
    const frontierBoards = (await db.boards.where('id').anyOf([...frontier]).toArray()).map((b) => ({
      id: b.id,
      spawnedFromTemplateId: b.spawnedFromTemplateId,
    }));
    const watcherTaskIds = findWatcherTaskIds(allTasks, frontierBoards);
    if (watcherTaskIds.length === 0) return;

    const watcherBoardIds = await resolveAffectedBoardIds(watcherTaskIds);

    await runBoardCascadeForTasks(watcherTaskIds);
    await reDeriveSealedBoardsForTasks(watcherTaskIds);

    const nextFrontier = new Set<string>();
    for (const id of watcherBoardIds) if (!visited.has(id)) nextFrontier.add(id);
    frontier = nextFrontier;
  }
}
