import { db } from '../internal';
import {
  BoardStatus,
  TaskType,
  SyncOperationType,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  resolveTaskWindowState,
  type Board,
  type Task,
  type CompoundChild,
  type BoardStatsUpdate,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks } from './boardTasks';
import { buildWindowContext } from './windowContext';
import {
  appendCompletionEvent,
  appendIncrementEvent,
  tombstoneWindowCompletions,
} from './taskEvents';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Result of a task completion, including bingo detection and board status changes.
 *
 * @property newBingos - Line IDs that became complete (not previously in board.completedLineIds)
 * @property lostBingos - Line IDs that became incomplete (were in board.completedLineIds, now gone)
 * @property isGreenlog - True when every square on the board is complete (primary board)
 * @property boardCompleted - True if the primary board status transitioned to COMPLETED
 * @property boardReactivated - True if the primary board reverted from COMPLETED to ACTIVE
 * @property collateralBingosByBoard - New bingo lines on OTHER boards that completed as a result
 *   of this write cascading through shared Tasks. Keyed by boardId; empty when no cascade occurred.
 */
export interface TaskCompletionResult {
  newBingos: string[];
  lostBingos: string[];
  isGreenlog: boolean;
  boardCompleted: boolean;
  boardReactivated: boolean;
  collateralBingosByBoard: Record<string, string[]>;
}

/** Extended board stats including transition signals from a cascade pass. */
export interface BoardCascadeEntry extends BoardStatsUpdate {
  boardCompleted: boolean;
  boardReactivated: boolean;
}

// ─── Shared cascade helper ────────────────────────────────────────────────────

/**
 * Run the derivation pass for a Task that just changed (locally OR via pull).
 *
 * Recomputes board stats + status transitions + sync entries for every board
 * affected by `changedTaskId` directly or via a containing compound.
 *
 * Pure cascade — does NOT write the Task itself. Caller owns that write.
 *
 * Pulls do NOT bump Task version (pulled value is authoritative); calling
 * this helper from a pull handler handles the cascade without re-firing
 * the write-path Task update.
 *
 * IMPORTANT: Must be called inside an active Dexie transaction covering
 * `boards`, `boardTasks`, `tasks`, `compoundChildren`, and `syncQueue`.
 * Dexie's auto-batching joins the caller's transaction automatically when
 * invoked within `db.transaction('rw', [...], async () => { ... })`.
 *
 * @param changedTaskId The Task whose state just changed.
 * @returns A map of boardId → BoardCascadeEntry for every recomputed board,
 *   so callers can extract collateral signals (e.g., new bingos).
 */
export async function runBoardCascadeForTask(
  changedTaskId: string,
): Promise<Map<string, BoardCascadeEntry>> {
  return runBoardCascadeForTasks([changedTaskId]);
}

/**
 * Batched multi-task variant of {@link runBoardCascadeForTask}
 * (docs/WINDOWED_COMPLETION.md §Sync — "recompute each affected task's caches
 * once, then run ONE derivation pass per affected live board"). Builds the
 * derivation lookups + the windowed-event map ONCE, resolves the UNION of
 * affected boards across every changed task, and recomputes each affected board
 * exactly once. The single-task path delegates here so both share the windowed
 * evaluation and per-board dedupe.
 *
 * Same transaction contract as `runBoardCascadeForTask` — must run inside an
 * active Dexie `rw` transaction covering `boards`, `boardTasks`, `tasks`,
 * `compoundChildren`, `taskEvents`, and `syncQueue`.
 *
 * @param changedTaskIds The tasks whose state changed (deduped internally).
 * @returns A map of boardId → BoardCascadeEntry for every recomputed board.
 */
export async function runBoardCascadeForTasks(
  changedTaskIds: Iterable<string>,
): Promise<Map<string, BoardCascadeEntry>> {
  const now = currentTimestamp();

  // Build the lookups for the derivation pass.
  const allChildren = await fetchAllCompoundChildren();
  const allBoardTasks = await fetchAllBoardTasks();
  const allTasks = await db.tasks.toArray();
  // Phase 6.3 — `computeBoardStatsUpdate` needs the workspace's boards
  // to evaluate the specific-board / recurring-template achievement branches.
  const allBoards = await db.boards.toArray();
  // Windowed Completion — group events once so every board evaluates windowed.
  const windowContext = await buildWindowContext();

  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;

  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  }

  // Resolve the UNION of affected boards across every changed task.
  const affectedBoardIds = new Set<string>();
  for (const changedTaskId of changedTaskIds) {
    const parentCompounds = findTransitiveParentCompounds(changedTaskId, allChildren);
    for (const id of findAffectedBoardIds(changedTaskId, parentCompounds, allBoardTasks)) {
      affectedBoardIds.add(id);
    }
  }

  const resultMap = new Map<string, BoardCascadeEntry>();

  for (const affectedBoardId of affectedBoardIds) {
    const affectedBoard = await db.boards.get(affectedBoardId);
    // Windowed Completion — sealed boards drop out of the live derivation
    // fan-out (docs §Effects of sealed). Greenlog can no longer revert on
    // them from live activity; the ONLY sanctioned mutation is the
    // deterministic pull-path re-derivation (see sealing.ts).
    if (!affectedBoard || affectedBoard.isDeleted || affectedBoard.sealedAt) continue;

    const boardTasksOnBoard = allBoardTasks.filter((bt) => bt.boardId === affectedBoardId);
    const stats: BoardStatsUpdate = computeBoardStatsUpdate(
      affectedBoard,
      boardTasksOnBoard,
      childrenByCompound,
      taskById,
      allBoards,
      windowContext,
    );

    const totalSquares = affectedBoard.boardSize * affectedBoard.boardSize;
    const isGreenlog = stats.completedTasks >= totalSquares;

    let boardCompleted = false;
    let boardReactivated = false;

    // Typed as `Partial<Board>` (not `Record<string, unknown>`) so Dexie
    // 4's stricter `UpdateSpec<T>` accepts it. Dexie 4 narrowed the
    // `Table.update` signature to require key-mapped types — the old
    // permissive `Record<string, unknown>` was rejected.
    const boardUpdate: Partial<Board> = {
      completedTasks: stats.completedTasks,
      linesCompleted: stats.linesCompleted,
      completedLineIds: stats.completedLineIds,
      updatedAt: now,
      version: (affectedBoard.version ?? 1) + 1,
    };

    // Auto-complete board on greenlog.
    if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
      boardUpdate.status = BoardStatus.COMPLETED;
      boardUpdate.completedAt = now;
      boardCompleted = true;
    }

    // Revert COMPLETED → ACTIVE if board is no longer fully complete.
    if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
      boardUpdate.status = BoardStatus.ACTIVE;
      boardUpdate.completedAt = undefined;
      boardReactivated = true;
    }

    await db.boards.update(affectedBoardId, boardUpdate);

    // Enqueue sync for this board (inside the transaction for all-or-nothing semantics).
    const updatedBoard = await db.boards.get(affectedBoardId);
    if (updatedBoard) {
      await addToSyncQueue('boards', affectedBoardId, SyncOperationType.UPDATE, updatedBoard, 0);
    }

    resultMap.set(affectedBoardId, {
      ...stats,
      boardCompleted,
      boardReactivated,
    });
  }

  return resultMap;
}

/**
 * Run the derivation pass for a SPECIFIC board, not via task-driven
 * affected-board discovery (Board-integrity PR-1, docs/BOARD_INTEGRITY.md —
 * the boardTasks-pull cascade).
 *
 * `runBoardCascadeForTask(s)` resolve the affected-board set by walking
 * `taskId → boardId` reachability over the LIVE (non-deleted) `boardTasks`
 * snapshot. That's wrong for a pulled `boardTasks` row: a pulled TOMBSTONE
 * is (correctly) invisible to that reachability walk, so a board that lost
 * its only placement of a task via a remote delete would never be
 * discovered as "affected" and its stats would go stale forever. Here the
 * board is already known directly from the pulled row's `boardId`, so this
 * recomputes that ONE board unconditionally from the post-pull snapshot —
 * mirroring `reorderBoardTasks`'s board-driven (not task-driven) recompute,
 * which is exactly this same shape (positional bingo lines can change from
 * either a live rearrange or a pulled one).
 *
 * Sealed boards are skipped (live derivation never mutates a sealed board);
 * callers are responsible for invoking the deterministic sealed re-derive
 * (`reDeriveSealedBoardsByIds`) separately when the board is sealed —
 * mirrors the `boards`-pull branch in `pullApply.ts`.
 *
 * Same transaction contract as `runBoardCascadeForTask` — must run inside an
 * active Dexie `rw` transaction covering `boards`, `boardTasks`, `tasks`,
 * `compoundChildren`, and `syncQueue`.
 *
 * @param boardId The board to recompute.
 */
export async function runBoardCascadeForBoardId(boardId: string): Promise<void> {
  const board = await db.boards.get(boardId);
  if (!board || board.isDeleted || board.sealedAt) return;

  const now = currentTimestamp();
  const allChildren = await fetchAllCompoundChildren();
  const allBoardTasks = await fetchAllBoardTasks();
  const allTasks = await db.tasks.toArray();
  const allBoards = await db.boards.toArray();
  const windowContext = await buildWindowContext();

  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;

  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  }

  const boardTasksOnBoard = allBoardTasks.filter((bt) => bt.boardId === boardId);
  const stats: BoardStatsUpdate = computeBoardStatsUpdate(
    board,
    boardTasksOnBoard,
    childrenByCompound,
    taskById,
    allBoards,
    windowContext,
  );

  const totalSquares = board.boardSize * board.boardSize;
  const isGreenlog = stats.completedTasks >= totalSquares;

  const boardUpdate: Partial<Board> = {
    completedTasks: stats.completedTasks,
    linesCompleted: stats.linesCompleted,
    completedLineIds: stats.completedLineIds,
    updatedAt: now,
    version: (board.version ?? 1) + 1,
  };

  if (isGreenlog && board.status === BoardStatus.ACTIVE) {
    boardUpdate.status = BoardStatus.COMPLETED;
    boardUpdate.completedAt = now;
  } else if (!isGreenlog && board.status === BoardStatus.COMPLETED) {
    boardUpdate.status = BoardStatus.ACTIVE;
    boardUpdate.completedAt = undefined;
  }

  await db.boards.update(boardId, boardUpdate);
  const updatedBoard = await db.boards.get(boardId);
  if (updatedBoard) {
    await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, updatedBoard, 0);
  }
}

// ─── Orchestration ───────────────────────────────────────────────────────────

/**
 * Handles a task completion event on a board, orchestrating the full chain:
 * update the underlying global Task → run the shared derivation pass →
 * recompute stats + status for every affected board → enqueue sync.
 *
 * Because Tasks are global (not per-board), completing a Task that appears on
 * multiple boards or is a child of compound Tasks on other boards cascades
 * automatically. All writes happen inside a single Dexie transaction.
 *
 * The caller uses the return value to trigger celebrations immediately (rather
 * than waiting for reactive hook updates which may lag by a frame).
 *
 * @param boardId - The primary board the user interacted with
 * @param boardTaskId - The specific BoardTask the user tapped/checked
 * @param updates - Partial update to apply (isCompleted, currentCount).
 *   `completedStepIds` is no longer supported; pass it and this function throws.
 * @returns TaskCompletionResult with new bingos, greenlog status, board completion flag,
 *   and cascading bingos on other boards.
 */
export async function handleTaskCompletion(
  boardId: string,
  boardTaskId: string,
  updates: {
    isCompleted?: boolean;
    currentCount?: number;
    completedStepIds?: string[];
  }
): Promise<TaskCompletionResult> {
  // Reject the legacy completedStepIds param — there is no per-board step state
  // under the unified compound model. Toggle each leaf Task directly instead.
  if (updates.completedStepIds !== undefined) {
    throw new Error(
      'completedStepIds is no longer supported under the unified compound model. ' +
        'Toggle leaf Tasks directly via handleTaskCompletion(boardId, leafBoardTaskId, { isCompleted: true }).',
    );
  }

  let result: TaskCompletionResult = {
    newBingos: [],
    lostBingos: [],
    isGreenlog: false,
    boardCompleted: false,
    boardReactivated: false,
    collateralBingosByBoard: {},
  };

  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch + auto-activate the primary board.
      let primaryBoard = await db.boards.get(boardId);
      if (!primaryBoard) throw new Error(`Board ${boardId} not found`);

      if (primaryBoard.status === BoardStatus.DRAFT) {
        await db.boards.update(boardId, {
          status: BoardStatus.ACTIVE,
          // Windowed Completion — stamp the activation instant so the
          // auto-seal backstop keys off max(endDate, activatedAt): a draft
          // activated after its window expired gets a full prompt cycle
          // (docs §Sealing → backstop). Only stamp once.
          activatedAt: primaryBoard.activatedAt ?? now,
          updatedAt: now,
          version: (primaryBoard.version ?? 1) + 1,
        });
        // Re-fetch to get updated version for subsequent writes.
        primaryBoard = (await db.boards.get(boardId))!;
      }

      // 2. Resolve target BoardTask + its underlying Task.
      const targetBt = await db.boardTasks.get(boardTaskId);
      if (!targetBt || targetBt.isDeleted) throw new Error(`BoardTask ${boardTaskId} not found`);
      if (targetBt.boardId !== boardId) {
        throw new Error(`BoardTask ${boardTaskId} does not belong to board ${boardId}`);
      }

      const targetTask = await db.tasks.get(targetBt.taskId);
      if (!targetTask) throw new Error(`Task ${targetBt.taskId} not found`);

      // Compound squares are read-only on the grid. Their state derives from
      // children — clients toggle children, not the compound itself.
      if (targetTask.type === TaskType.COMPOUND) {
        throw new Error(
          'Compound BoardTasks are read-only on the grid. Toggle a child task ' +
            'via the detail sheet — its completion cascades to this compound automatically.',
        );
      }

      // 3. Windowed Completion (docs §Write paths): board-context taps write
      //    TaskEvents (not the lifetime cache). The event choke points append
      //    the row, restamp the lifetime caches, bump `Task.version`, and
      //    enqueue the Task sync entry — all inside THIS transaction.
      //
      //    `updates.currentCount` is the UI's desired NEW windowed count (the
      //    grid derives it from `resolveTaskWindowState`), so the event delta
      //    is `desired - currentWindowedCount`. Increment → positive delta;
      //    decrement/reset → negative delta, gated so the window sum can't go
      //    below zero from a local gesture. `updates.isCompleted` toggles a
      //    normal square: complete → append a completion event; un-complete →
      //    window-scoped tombstone of this board's in-window completions.
      const windowStart = primaryBoard.startDate;
      if (updates.currentCount !== undefined) {
        const events = await db.taskEvents.where('taskId').equals(targetTask.id).toArray();
        const { count: windowedCount } = resolveTaskWindowState(
          targetTask,
          events.filter((e) => !e.isDeleted),
          windowStart,
        );
        let delta = updates.currentCount - windowedCount;
        // Gate a decrement so the window sum stays ≥ 0 (belt against a local
        // gesture poisoning the window with a dangling negative).
        if (delta < 0) delta = Math.max(delta, -windowedCount);
        if (delta !== 0) {
          await appendIncrementEvent(targetTask.id, delta, boardId, now);
        }
      } else if (updates.isCompleted !== undefined) {
        if (updates.isCompleted) {
          await appendCompletionEvent(targetTask.id, boardId, now);
        } else {
          await tombstoneWindowCompletions(targetTask.id, windowStart, now);
        }
      }

      // 4. Run the shared derivation pass — cascade to every affected board.
      const cascadeMap = await runBoardCascadeForTask(targetTask.id);

      // 5. Build TaskCompletionResult from the cascade map.
      const collateralBingosByBoard: Record<string, string[]> = {};
      for (const [affectedBoardId, entry] of cascadeMap) {
        if (affectedBoardId === boardId) {
          const totalSquares = primaryBoard.boardSize * primaryBoard.boardSize;
          result = {
            newBingos: entry.newBingos,
            lostBingos: entry.lostBingos,
            isGreenlog: entry.completedTasks >= totalSquares,
            boardCompleted: entry.boardCompleted,
            boardReactivated: entry.boardReactivated,
            collateralBingosByBoard, // re-attached below after the loop
          };
        } else if (entry.newBingos.length > 0) {
          collateralBingosByBoard[affectedBoardId] = entry.newBingos;
        }
      }

      // 6. The Task sync entry is already enqueued by the event choke points
      //    (they restamp the lifetime caches as an authored write, bump
      //    `Task.version`, and enqueue the Task UPDATE — docs §Task caches).

      // Populate collateralBingosByBoard on the result now that the loop is done.
      result.collateralBingosByBoard = collateralBingosByBoard;
    },
  );

  return result;
}
