import { db } from '../internal';
import type { BoardTask, CreateBoardTaskInput } from '@oybc/shared';
import {
  SyncOperationType,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  resolvePlacements,
  BoardStatus,
  type Board,
  type Task,
  type CompoundChild,
  type BoardStatsUpdate,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { fetchAllCompoundChildren } from './compoundChildren';
import { buildWindowContext } from './windowContext';

/**
 * BoardTask CRUD Operations
 */

/**
 * Fetch all non-deleted board tasks for a board
 */
export async function fetchBoardTasks(boardId: string): Promise<BoardTask[]> {
  return db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).toArray();
}

/**
 * Fetch a single board task by ID. Returns tombstoned rows too — callers
 * that only want live placements should check `.isDeleted` themselves
 * (mirrors `fetchCompoundChild`/`fetchBoard`, which are also un-filtered
 * single-id lookups; the filtering convention lives on the collection-scan
 * helpers, not point lookups).
 */
export async function fetchBoardTask(id: string): Promise<BoardTask | undefined> {
  return db.boardTasks.get(id);
}

/**
 * Fetch every non-deleted BoardTask placement row referencing a given Task.
 *
 * Distinct from `fetchBoardsUsingTask` (which returns just the boardIds) —
 * this returns the full placement rows for per-placement UI (task detail).
 *
 * @param taskId - The placed Task's id.
 * @returns All non-deleted BoardTask rows whose `taskId` matches.
 */
export async function fetchBoardTasksForTask(taskId: string): Promise<BoardTask[]> {
  return db.boardTasks.where('taskId').equals(taskId).filter((bt) => !bt.isDeleted).toArray();
}

/**
 * Count the non-deleted BoardTask rows placed on a board.
 *
 * Used by the board-edit panel to know whether a board has any candidate
 * tasks without loading every row.
 *
 * @param boardId - The board id.
 * @returns The number of non-deleted BoardTask rows for that board.
 */
export async function countBoardTasksForBoard(boardId: string): Promise<number> {
  return db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).count();
}

/**
 * Soft-deletes (tombstones) every live `BoardTask` row for the given board
 * and queues each tombstone for sync. Used when re-saving a draft whose
 * task placement has changed — simpler than diffing the old layout against
 * the new one, and tolerable at scale (at most 25 cells).
 *
 * Board-integrity PR-1 (docs/BOARD_INTEGRITY.md): `BoardTask` now carries
 * `isDeleted`/`deletedAt` like every other synced collection. A hard
 * `db.boardTasks.delete()` here would resurrect the row on the next pull
 * whenever the pushed tombstone LOST the LWW tie-break (the exact bug this
 * PR fixes) — the row must survive locally as a tombstone so the version
 * bump wins the tie-break and the deletion actually sticks.
 */
export async function deleteBoardTasksForBoard(boardId: string): Promise<void> {
  const now = currentTimestamp();
  const tasks = await db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).toArray();
  for (const bt of tasks) {
    const tombstoned = buildBoardTaskTombstone(bt, now);
    await db.boardTasks.update(bt.id, tombstoned);
    await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, tombstoned);
  }
}

/**
 * Build the tombstoned (soft-deleted) snapshot for a live BoardTask row.
 * Pure — callers write it via `db.boardTasks.update`/`.put` and enqueue it
 * for sync. Bumping `version` here is what makes the sync-layer LWW
 * tie-break favor the tombstone over a same-version remote live row (the
 * root fix of docs/BOARD_INTEGRITY.md PR-1 — see `BoardTask`'s docstring).
 *
 * @param existing - The live BoardTask row being removed.
 * @param now - The shared write timestamp for this deletion.
 */
export function buildBoardTaskTombstone(existing: BoardTask, now: string): BoardTask {
  return {
    ...existing,
    isDeleted: true,
    deletedAt: now,
    updatedAt: now,
    version: (existing.version ?? 0) + 1,
  };
}

/**
 * Fetch every non-deleted BoardTask in the workspace.
 *
 * Used by the derivation pass to find which boards are affected by a
 * Task state change. Small-N: every BoardTask across every board.
 * Typical user has fewer than a few thousand.
 *
 * Filters tombstones here (not per call site) so no cascade caller can
 * forget — a tombstoned placement must never contribute to board stats.
 */
export async function fetchAllBoardTasks(): Promise<BoardTask[]> {
  return db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
}

/**
 * Fetch non-deleted BoardTask rows for the given board ids, grouped by boardId.
 * Returns a Map keyed by boardId; boards with no live BoardTasks have an empty array entry.
 */
export async function fetchBoardTasksForBoards(
  boardIds: string[],
): Promise<Map<string, BoardTask[]>> {
  const out = new Map<string, BoardTask[]>();
  for (const id of boardIds) out.set(id, []);
  if (boardIds.length === 0) return out;
  const rows = await db.boardTasks.where('boardId').anyOf(boardIds).filter((bt) => !bt.isDeleted).toArray();
  for (const row of rows) {
    const arr = out.get(row.boardId);
    if (arr) arr.push(row);
  }
  return out;
}

/**
 * Create a board task (add task to board).
 *
 * Phase 6.3 — BoardTask is a pure placement record. Achievement-square
 * configuration moved to `Task` (`type === ACHIEVEMENT` + reference
 * fields); see `apps/web/src/db/operations/tasks.ts` for the achievement
 * task creation path. Cycle detection for ACHIEVEMENT tasks happens at
 * the UI layer before this helper runs.
 *
 * Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 3) — write-path
 * invariant guards, checked INSIDE the write transaction against fresh
 * reads so a same-tick race can't slip a violation past the check: rejects
 * a placement that would (i) collide with a live row already at this cell,
 * (ii) place a Task that is already live elsewhere on this board, or
 * (iii) fall outside the owning board's `[0, boardSize)` grid. Throws
 * rather than silently no-opping, matching this file's other write-path
 * error idiom (`throw new Error('functionName: message')`) — every known
 * caller (the wizard's per-cell write loop) either has nothing to catch
 * against (a violation here means the wizard itself built a bad placement
 * array — a real bug worth surfacing loudly) or already wraps callers in
 * try/catch (`addBoardTaskToBoard`, which does NOT call this — see its own
 * guards below).
 *
 * Board-integrity PR-5 (Item 3) — (iv) rejects an `isCenter: true` input
 * when a live center row already exists on this board. Nothing upstream
 * enforced single-center uniqueness before this: the wizard write loop only
 * ever computes ONE positional center per board today, but a future caller,
 * a sync-merge duplicate, or a retried write could otherwise slip a SECOND
 * `isCenter: true` row onto the board at a different cell. Verified
 * render-inert for both the live play grid (`BoardPlaySurface` — `isCenter`
 * is computed purely from `row === floor(size/2) && col === floor(size/2)`,
 * never from the `BoardTask.isCenter` field; cells are looked up via
 * `btByPosition[row-col]`, not by `isCenter`) and the edit-mode rearrange
 * grid (`useBoardPlay.ts` `arrangeSlots` — same positional computation) —
 * so this guard is pure defense-in-depth, not a fix for a live rendering bug.
 * Repair (`computePlacementIntegrityRepair`) intentionally does NOT dedupe
 * a same-position-valid, different-cell second center row — see
 * docs/BOARD_INTEGRITY.md.
 */
export async function createBoardTask(
  input: CreateBoardTaskInput
): Promise<BoardTask> {
  const now = currentTimestamp();
  const boardTask: BoardTask = {
    id: generateUUID(),
    boardId: input.boardId,
    taskId: input.taskId,
    row: input.row,
    col: input.col,
    isCenter: input.isCenter,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  await db.transaction('rw', [db.boards, db.boardTasks, db.syncQueue], async () => {
    const owningBoard = await db.boards.get(input.boardId);
    if (!owningBoard || owningBoard.isDeleted) {
      throw new Error(`createBoardTask: board ${input.boardId} not found`);
    }
    if (
      input.row < 0 ||
      input.col < 0 ||
      input.row >= owningBoard.boardSize ||
      input.col >= owningBoard.boardSize
    ) {
      throw new Error(
        `createBoardTask: (${input.row}, ${input.col}) is out of bounds for a ${owningBoard.boardSize}x${owningBoard.boardSize} board`,
      );
    }

    const liveOnBoard = await db.boardTasks
      .where('boardId')
      .equals(input.boardId)
      .filter((bt) => !bt.isDeleted)
      .toArray();
    if (liveOnBoard.some((bt) => bt.row === input.row && bt.col === input.col)) {
      throw new Error(
        `createBoardTask: cell (${input.row}, ${input.col}) is already occupied on board ${input.boardId}`,
      );
    }
    if (liveOnBoard.some((bt) => bt.taskId === input.taskId)) {
      throw new Error(
        `createBoardTask: task ${input.taskId} is already placed on board ${input.boardId}`,
      );
    }
    if (input.isCenter && liveOnBoard.some((bt) => bt.isCenter)) {
      throw new Error(
        `createBoardTask: board ${input.boardId} already has a live center placement`,
      );
    }

    await db.boardTasks.add(boardTask);
    await addToSyncQueue('boardTasks', boardTask.id, SyncOperationType.CREATE, boardTask);
  });

  return boardTask;
}

/**
 * Find all boards using a specific task (live placements only)
 */
export async function fetchBoardsUsingTask(taskId: string): Promise<string[]> {
  const boardTasks = await db.boardTasks.where('taskId').equals(taskId).filter((bt) => !bt.isDeleted).toArray();
  return [...new Set(boardTasks.map((bt) => bt.boardId))];
}

// ─── removeBoardTaskFromBoard ────────────────────────────────────────────────

/**
 * Remove a single BoardTask placement from an ACTIVE board (live-edit M4).
 *
 * Semantics (Board-integrity PR-1, docs/BOARD_INTEGRITY.md):
 *   - SOFT-deletes (tombstones) the BoardTask row — `isDeleted`/`deletedAt`
 *     set, `version` bumped, row stays in Dexie. The version bump is load-
 *     bearing: it's what makes the tombstone WIN the sync-layer LWW
 *     tie-break against a same-version remote live row, instead of the
 *     stale pre-delete snapshot losing the tie and getting pushed BACK
 *     locally by the safety-net pull (the self-revert bug this PR fixes).
 *   - Enqueues a DELETE sync entry (with the fresh tombstoned payload, not
 *     the pre-delete snapshot) so the tombstone propagates to Firestore.
 *   - Runs the batched cascade pattern from M2/M3: computes affected board IDs
 *     for the removed task (and any compound parents), then re-derives board stats
 *     + status for every affected board in one Dexie transaction.
 *
 * The underlying Task is NOT touched — it stays in the library and on other boards.
 * Only this board loses the placement.
 *
 * Caller is responsible for:
 *   - Confirming the board is ACTIVE (not expired) before calling.
 *   - Ensuring the target BoardTask is not the center square.
 *
 * @param boardTaskId - The `BoardTask.id` placement record to remove.
 */
export async function removeBoardTaskFromBoard(boardTaskId: string): Promise<void> {
  const existing = await db.boardTasks.get(boardTaskId);
  if (!existing || existing.isDeleted) return;

  const now = currentTimestamp();
  const removedTaskId = existing.taskId;

  // Gather workspace data BEFORE the delete so we can compute affected boards.
  const allBoardTasksPre = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
  const allCompoundChildren = await fetchAllCompoundChildren();

  // Affected boards: those placing the removed task directly OR via a compound parent.
  const parents = findTransitiveParentCompounds(removedTaskId, allCompoundChildren);
  const affectedBoardIds = Array.from(findAffectedBoardIds(removedTaskId, parents, allBoardTasksPre));

  // Windowed Completion — build the event map BEFORE the rw transaction so the
  // cascade resolves each board against its own window (not the lifetime cache),
  // and `db.taskEvents` need not be in the transaction scope.
  const windowContext = await buildWindowContext();

  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // Board-integrity PR-2 (Part 4) — sealed-board guard: re-fetch the
      // OWNING board fresh inside the write txn — the app-shell backstop can
      // seal a board between the pre-txn reads above and this transaction
      // opening, and a live-edit mutator must never write a placement
      // change onto a board that has since sealed. Mirrors the
      // updateBoardAndCascade / reorderBoardTasks sealed-board guards (#357).
      const owningBoard = await db.boards.get(existing.boardId);
      if (!owningBoard || owningBoard.isDeleted || owningBoard.sealedAt) return;

      // 1. Soft-delete (tombstone) the BoardTask placement.
      const tombstoned = buildBoardTaskTombstone(existing, now);
      await db.boardTasks.update(boardTaskId, tombstoned);

      // Enqueue DELETE with the FRESH tombstoned payload (version bumped) —
      // not `existing`, whose stale version was the root cause of the
      // self-revert bug (see docstring above).
      await addToSyncQueue('boardTasks', boardTaskId, SyncOperationType.DELETE, tombstoned, 0);

      // 2. Fetch post-delete state for cascade pass.
      const allBoardTasksPost = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();
      const allChildren = await db.compoundChildren.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        if (!c.isDeleted) {
          (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        }
      }

      // 3. One cascade pass per affected board.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = await db.boards.get(affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted || affectedBoard.sealedAt) continue;

        // Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 2) — resolve
        // through the shared winner rule before deriving: a raw filter can
        // still contain a cell collision (offline sync union, pre-repair
        // corruption), and the kernel must never disagree with render about
        // which row wins a cell.
        const boardTasksOnBoard = resolvePlacements(
          allBoardTasksPost.filter((bt) => bt.boardId === affectedBoardId),
          affectedBoard.boardSize,
        );

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

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (affectedBoard.version ?? 1) + 1,
        };

        if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        } else if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
          boardUpdate.status = BoardStatus.ACTIVE;
          boardUpdate.completedAt = undefined;
        }

        await db.boards.update(affectedBoardId, boardUpdate);

        const updatedBoard = await db.boards.get(affectedBoardId);
        if (updatedBoard) {
          await addToSyncQueue('boards', affectedBoardId, SyncOperationType.UPDATE, updatedBoard, 0);
        }
      }
    },
  );
}

// ─── addBoardTaskToBoard ──────────────────────────────────────────────────────

/**
 * Add a Task to an empty cell on an ACTIVE board (live-edit M4).
 *
 * Creates a new BoardTask placement record at the given grid position and runs
 * the batched cascade pattern (same approach as M2/M3) to re-derive stats for
 * every board affected by the newly-placed task.
 *
 * Shared-task semantics: if the task is already globally completed (isCompleted
 * is true on the Task row), the cascade immediately counts this cell as
 * completed and increments board.completedTasks. No cloning, no reset.
 *
 * Board-integrity PR-5 (Item 3): no `isCenter` uniqueness guard is needed
 * here — unlike `createBoardTask`, this path always constructs its new row
 * with `isCenter: false` (below) and has no parameter through which a caller
 * could set it true. `createBoardTask` (the board-scoped placement path
 * that DOES accept a caller-supplied `isCenter`, used by the wizard write
 * loop) carries the actual guard.
 *
 * Caller is responsible for:
 *   - Confirming the target cell is currently empty.
 *   - Confirming the board is ACTIVE (not expired) before calling.
 *   - Confirming the cell is not the center square.
 *   - Confirming the task is not already placed at this exact cell on this board.
 *
 * @param boardId - The board receiving the new placement.
 * @param taskId - The task to place.
 * @param row - Grid row (0-based).
 * @param col - Grid column (0-based).
 * @returns The newly-created BoardTask record.
 */
export async function addBoardTaskToBoard(
  boardId: string,
  taskId: string,
  row: number,
  col: number,
): Promise<BoardTask> {
  const now = currentTimestamp();

  const newBoardTask: BoardTask = {
    id: generateUUID(),
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  // Gather workspace data BEFORE the insert for affected-board computation.
  const allBoardTasksPre = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
  const allCompoundChildren = await fetchAllCompoundChildren();

  // Compute affected boards using the post-insert state (the new placement is included).
  const syntheticBoardTasks: BoardTask[] = [...allBoardTasksPre, newBoardTask];
  const parents = findTransitiveParentCompounds(taskId, allCompoundChildren);
  const affectedBoardIds = Array.from(findAffectedBoardIds(taskId, parents, syntheticBoardTasks));

  // Windowed Completion — build the event map BEFORE the rw transaction so the
  // cascade resolves each board against its own window (not the lifetime cache),
  // and `db.taskEvents` need not be in the transaction scope.
  const windowContext = await buildWindowContext();

  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // Board-integrity PR-2 (Part 4) — sealed-board guard: re-fetch the
      // OWNING board fresh inside the write txn. The app-shell backstop can
      // seal a board between the pre-txn reads above and this transaction
      // opening; a live-edit mutator must never write a placement change
      // onto a board that has since sealed. Mirrors the
      // updateBoardAndCascade / reorderBoardTasks sealed-board guards (#357).
      const owningBoard = await db.boards.get(boardId);
      if (!owningBoard || owningBoard.isDeleted || owningBoard.sealedAt) {
        throw new Error(`addBoardTaskToBoard: board ${boardId} is missing, deleted, or sealed`);
      }

      // Board-integrity PR-2 (Part 3) — write-path invariant guards, checked
      // against FRESH reads inside the txn: reject a placement that would
      // collide with a live row at this cell, place a task already live on
      // this board, or fall outside the board's grid.
      if (row < 0 || col < 0 || row >= owningBoard.boardSize || col >= owningBoard.boardSize) {
        throw new Error(
          `addBoardTaskToBoard: (${row}, ${col}) is out of bounds for a ${owningBoard.boardSize}x${owningBoard.boardSize} board`,
        );
      }
      const liveOnBoard = await db.boardTasks
        .where('boardId')
        .equals(boardId)
        .filter((bt) => !bt.isDeleted)
        .toArray();
      if (liveOnBoard.some((bt) => bt.row === row && bt.col === col)) {
        throw new Error(`addBoardTaskToBoard: cell (${row}, ${col}) is already occupied`);
      }
      if (liveOnBoard.some((bt) => bt.taskId === taskId)) {
        throw new Error(`addBoardTaskToBoard: task ${taskId} is already placed on board ${boardId}`);
      }

      // 1. Write the new BoardTask placement.
      await db.boardTasks.add(newBoardTask);
      await addToSyncQueue('boardTasks', newBoardTask.id, SyncOperationType.CREATE, newBoardTask, 0);

      // 2. Fetch post-insert state for cascade pass.
      const allBoardTasksPost = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();
      const allChildren = await db.compoundChildren.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        if (!c.isDeleted) {
          (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        }
      }

      // 3. One cascade pass per affected board.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = await db.boards.get(affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted || affectedBoard.sealedAt) continue;

        // Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 2) — resolve
        // through the shared winner rule before deriving: a raw filter can
        // still contain a cell collision (offline sync union, pre-repair
        // corruption), and the kernel must never disagree with render about
        // which row wins a cell.
        const boardTasksOnBoard = resolvePlacements(
          allBoardTasksPost.filter((bt) => bt.boardId === affectedBoardId),
          affectedBoard.boardSize,
        );

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

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (affectedBoard.version ?? 1) + 1,
        };

        if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        } else if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
          boardUpdate.status = BoardStatus.ACTIVE;
          boardUpdate.completedAt = undefined;
        }

        await db.boards.update(affectedBoardId, boardUpdate);

        const updatedBoard = await db.boards.get(affectedBoardId);
        if (updatedBoard) {
          await addToSyncQueue('boards', affectedBoardId, SyncOperationType.UPDATE, updatedBoard, 0);
        }
      }
    },
  );

  return newBoardTask;
}

// ─── reorderBoardTasks ───────────────────────────────────────────────────────

/**
 * Describes a single position-change for a BoardTask row.
 * Used by the Phase-3 staged-rearrange Save commit path.
 */
export interface BoardTaskMove {
  boardTaskId: string;
  row: number;
  col: number;
}

/**
 * Atomically apply position changes to one board's BoardTask rows, then
 * re-derive the board's positional bingo lines.
 *
 * Called at Save time after staged-draft Replace/Edit commits (Phase 3).
 *
 * Design invariants:
 *   - All moves are written in ONE Dexie transaction → no two rows transiently
 *     share the same (row, col) from the perspective of outside readers.
 *   - Global Task completion (isCompleted / currentCount) is NEVER touched —
 *     it rides with the task to its new slot.
 *   - Bingo lines (`completedLineIds` / `linesCompleted`) are re-derived via
 *     `computeBoardStatsUpdate` on the post-move board-task snapshot because
 *     bingos are positional (row, column, diagonal).
 *   - `completedTasks` is also re-derived (unchanged in value — task completion
 *     states are global) but kept consistent via the same cascade pass.
 *   - Each moved BoardTask row is bump-versioned and enqueued for sync UPDATE.
 *   - The board row is bump-versioned and enqueued for sync UPDATE.
 *
 * @param boardId - The board whose placements are being reordered.
 * @param moves - Array of `{ boardTaskId, row, col }` describing each moved row.
 *                Must not include center-square rows (the caller — BoardPlaySurface —
 *                filters them out since the center is pinned). Must not be empty.
 */
export async function reorderBoardTasks(
  boardId: string,
  moves: BoardTaskMove[],
): Promise<void> {
  if (moves.length === 0) return;

  const now = currentTimestamp();

  // Gather workspace data once before the transaction (cheap snapshot reads).
  const allTasks = await db.tasks.toArray();
  const allBoards = await db.boards.toArray();
  const allChildren = await db.compoundChildren.toArray();

  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;

  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    if (!c.isDeleted) {
      (childrenByCompound[c.compoundTaskId] ??= []).push(c);
    }
  }

  // DB-level guard (matches the iOS twin + the sibling cascades in this file):
  // a sealed board must never be mutated by a live rearrange — the app-shell
  // backstop can seal a board while an edit session is already open, and
  // sealed boards never mutate except via deterministic pull-path re-derivation.
  const board = allBoards.find((b) => b.id === boardId);
  if (!board || board.isDeleted || board.sealedAt) return;

  // Board-integrity PR-2 (Part 3) — validate every staged move's target
  // against the board's bounds BEFORE writing any of them. Rejecting the
  // whole batch (rather than skipping just the bad move) avoids leaving a
  // rearrange half-committed; `BoardEditPanel`'s Save flow already expects
  // `onExtraCommit` (which calls this) to throw on failure and surfaces it
  // as a real validation error, so a real bug here is loud, not silent.
  for (const move of moves) {
    if (move.row < 0 || move.col < 0 || move.row >= board.boardSize || move.col >= board.boardSize) {
      throw new Error(
        `reorderBoardTasks: target (${move.row}, ${move.col}) is out of bounds for a ${board.boardSize}x${board.boardSize} board`,
      );
    }
  }

  // Windowed Completion — build the event map BEFORE the rw transaction so the
  // cascade resolves each board against its own window (not the lifetime cache),
  // and `db.taskEvents` need not be in the transaction scope.
  const windowContext = await buildWindowContext();

  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.syncQueue],
    async () => {
      // 1. Write new row/col for every moved BoardTask (version-bumped; isCenter kept).
      for (const move of moves) {
        const existing = await db.boardTasks.get(move.boardTaskId);
        if (!existing || existing.isDeleted) continue;

        const patched: BoardTask = {
          ...existing,
          row: move.row,
          col: move.col,
          // isCenter is intentionally preserved — rearrange never converts center squares.
          updatedAt: now,
          version: (existing.version ?? 0) + 1,
        };
        await db.boardTasks.put(patched);
        await addToSyncQueue('boardTasks', move.boardTaskId, SyncOperationType.UPDATE, patched, 0);
      }

      // 2. Re-derive bingo lines for this board from the post-move snapshot.
      //    Bingo lines are positional (row / col / diagonal), so any position
      //    change can create or break lines. Global Task completion is unchanged.
      // Board-integrity PR-2 (Part 2) — resolve through the shared winner
      // rule before deriving (see the sibling cascades above for why).
      const boardTasksOnBoard = resolvePlacements(
        await db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).toArray(),
        board.boardSize,
      );

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
    },
  );
}

// ─── updateBoardTaskAndCascade ────────────────────────────────────────────────

/**
 * Patch a BoardTask's `taskId` (cell swap) and run the board derivation
 * cascade for every board affected by either the OLD task or the NEW task.
 *
 * Design mirrors `updateTaskAndCascade` (M1) and the batched cascade from
 * `updateBoardAndCascade` (M2/PR #95):
 *   1. Apply the taskId patch atomically (bumps version + enqueues boardTask sync).
 *   2. Build the union of affected board IDs across both the old and new task:
 *      - Boards where the OLD task was placed (they need to re-derive because
 *        the task is no longer there).
 *      - Boards where the NEW task is placed (they need to re-derive because
 *        the task is now there, potentially forming new bingos).
 *   3. Run one derivation pass per affected board inside a single transaction.
 *
 * Counter-overshoot invariant: derivation never clamps `currentCount`. The cascade
 * delegates to `computeBoardStatsUpdate`, which reads `task.isCompleted` for non-
 * counting tasks; for counting tasks the actual over-max value is preserved on the
 * Task row and the cascade only recalculates board-level stats (bingos, completedTasks).
 *
 * Caller is responsible for:
 *   - Confirming the board is ACTIVE (not expired/archived) before calling.
 *   - Ensuring the target `BoardTask` cell (identified by `boardTaskId`) is not the center square.
 *   - Providing a `newTaskId` that is NOT the same as the current `taskId` (no-op
 *     guard: if they are equal, the function returns immediately without writing).
 *
 * @param boardTaskId - The `BoardTask.id` placement record to update.
 * @param newTaskId - The new `Task.id` to write into `BoardTask.taskId`.
 */
export async function updateBoardTaskAndCascade(
  boardTaskId: string,
  newTaskId: string,
): Promise<void> {
  // 1. Fetch the existing BoardTask.
  const existing = await db.boardTasks.get(boardTaskId);
  if (!existing || existing.isDeleted) return;

  const oldTaskId = existing.taskId;
  // No-op guard: swapping to the same task is a no-op.
  if (oldTaskId === newTaskId) return;

  const now = currentTimestamp();

  // 2. Gather all workspace data for the cascade pass (fetched once outside
  //    the transaction so the transaction body stays thin).
  const allBoardTasksPre = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
  const allCompoundChildren = await fetchAllCompoundChildren();

  // Build the union of affected board IDs for OLD and NEW tasks.
  // We use the pre-patch boardTask list for the old-task side (the old task
  // still occupies this cell), and synthesise the new state for the new task
  // side (after the patch the new task will be at this cell).
  // The simplest correct approach: compute affected boards for old task using
  // current state (which still has oldTaskId at this cell), then compute
  // affected boards for new task using a synthetic list where the cell carries
  // newTaskId.
  const syntheticBoardTasks: BoardTask[] = allBoardTasksPre.map((bt) =>
    bt.id === boardTaskId ? { ...bt, taskId: newTaskId } : bt,
  );

  const oldParents = findTransitiveParentCompounds(oldTaskId, allCompoundChildren);
  const oldAffected = findAffectedBoardIds(oldTaskId, oldParents, allBoardTasksPre);

  const newParents = findTransitiveParentCompounds(newTaskId, allCompoundChildren);
  const newAffected = findAffectedBoardIds(newTaskId, newParents, syntheticBoardTasks);

  const affectedBoardIds = Array.from(new Set([...oldAffected, ...newAffected]));

  // Windowed Completion — build the event map BEFORE the rw transaction so the
  // cascade resolves each board against its own window (not the lifetime cache),
  // and `db.taskEvents` need not be in the transaction scope.
  const windowContext = await buildWindowContext();

  // 3. Write the patch + cascade in one transaction.
  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // Board-integrity PR-2 (Part 4) — sealed-board guard: re-fetch the
      // OWNING board fresh inside the write txn (see removeBoardTaskFromBoard
      // for the full rationale — same idiom, matching updateBoardAndCascade /
      // reorderBoardTasks (#357)).
      const owningBoard = await db.boards.get(existing.boardId);
      if (!owningBoard || owningBoard.isDeleted || owningBoard.sealedAt) return;

      // 3a. Patch the BoardTask row.
      const patched: BoardTask = {
        ...existing,
        taskId: newTaskId,
        updatedAt: now,
        version: (existing.version ?? 0) + 1,
      };
      await db.boardTasks.put(patched);
      await addToSyncQueue('boardTasks', boardTaskId, SyncOperationType.UPDATE, patched, 0);

      // 3b. Fetch fresh workspace data inside the transaction for the cascade pass.
      //     We need the post-patch boardTask list and the full task / child sets.
      const allBoardTasksPost = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();
      const allChildren = await db.compoundChildren.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        if (!c.isDeleted) {
          (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        }
      }

      // 3c. One cascade pass per affected board.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = await db.boards.get(affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted || affectedBoard.sealedAt) continue;

        // Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 2) — resolve
        // through the shared winner rule before deriving: a raw filter can
        // still contain a cell collision (offline sync union, pre-repair
        // corruption), and the kernel must never disagree with render about
        // which row wins a cell.
        const boardTasksOnBoard = resolvePlacements(
          allBoardTasksPost.filter((bt) => bt.boardId === affectedBoardId),
          affectedBoard.boardSize,
        );

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

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (affectedBoard.version ?? 1) + 1,
        };

        if (isGreenlog && affectedBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        } else if (!isGreenlog && affectedBoard.status === BoardStatus.COMPLETED) {
          boardUpdate.status = BoardStatus.ACTIVE;
          boardUpdate.completedAt = undefined;
        }

        await db.boards.update(affectedBoardId, boardUpdate);

        const updatedBoard = await db.boards.get(affectedBoardId);
        if (updatedBoard) {
          await addToSyncQueue('boards', affectedBoardId, SyncOperationType.UPDATE, updatedBoard, 0);
        }
      }
    },
  );
}
