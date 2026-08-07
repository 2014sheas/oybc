import { db } from '../internal';
import type { Board, Task, CompoundChild, CreateBoardInput } from '@oybc/shared';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  Timeframe,
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  resolvePlacements,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { fetchAllCompoundChildren } from './compoundChildren';
import { fetchAllBoardTasks, buildBoardTaskTombstone } from './boardTasks';
import { buildWindowContext } from './windowContext';

/**
 * Board CRUD Operations
 */

// ─── Edit-active patch type ───────────────────────────────────────────────────

/**
 * Editable fields for an ACTIVE board (M2 — live-edit board metadata).
 *
 * Immutable on active boards:
 *   - `boardSize` — render as read-only chip in the UI (too disruptive to change).
 *   - `isCore`, `spawnedFromTemplateId`, `isRandomized` — internal state.
 *   - Placement set (`BoardTask` rows) — M3/M4.
 */
export interface UpdateActiveBoardPatch {
  name?: string;
  centerSquareType?: Board['centerSquareType'];
  /**
   * Cleared automatically when `centerSquareType` switches away from
   * `CHOSEN`. Callers may still pass the old value; the helper discards
   * it.
   *
   * NOTE (center-switch asymmetry): switching CHOSEN → FREE
   * does NOT hard-delete the underlying BoardTask — it preserves the
   * placement so a later switch back to CHOSEN can reuse it. The cell
   * renders as FREE on top of the placement. This is
   * intentional; do not treat it as a bug.
   */
  centerTaskId?: string | null;
  timeframe?: Board['timeframe'];
  /** Local-ISO8601 (via `toLocalISO`) snap to 00:00:00.000 start-of-day. */
  startDate?: string | null;
  /** Local-ISO8601 (via `toLocalISO`) snap to 23:59:59.999 end-of-day. */
  endDate?: string | null;
}

// ─── updateBoardAndCascade ────────────────────────────────────────────────────

/**
 * Apply a metadata patch to an ACTIVE board and re-derive stats for every
 * placed task.
 *
 * Sequence:
 *   1. Apply the patch via `updateBoard` (bumps version + enqueues sync).
 *   2. Sanitize center-square fields (clear `centerTaskId` when
 *      `centerSquareType` is not CHOSEN).
 *   3. Fetch every `BoardTask` that places a task on this board.
 *   4. Run `runBoardCascadeForTask` for each placed task inside a single
 *      Dexie transaction covering the required tables.
 *
 * Per-task cascade (not per-board) is deliberate: timeframe/dates changes
 * can flip expiry state on placed tasks, and each task's derivation reads
 * from board.timeframe + board.endDate — so every placed task needs a
 * re-derive.
 *
 * NOTE on renaming: board lookups are by id, so renaming propagates
 * everywhere (Achievement tasks watching this board, recurring-template
 * spawn metadata, etc.) without any extra work. Renaming a board does NOT
 * propagate to its spawning template name or to historical spawns —
 * references are always by id.
 *
 * @param boardId - Board to update.
 * @param patch - Editable fields for ACTIVE boards.
 */
export async function updateBoardAndCascade(
  boardId: string,
  patch: UpdateActiveBoardPatch,
): Promise<void> {
  // Build the sanitized Partial<Board> for updateBoard.
  // Board.startDate / endDate / centerTaskId are typed as `string`
  // (non-nullable) on the Board model, but an edit may want to clear
  // centerTaskId. We represent "clear" as `undefined` in the Partial
  // update (Dexie skips undefined keys). For startDate/endDate the
  // EditBoardSheet always provides a concrete string, so null is
  // converted to undefined as a safety net.
  //
  // NOTE: CenterSquareType is a STATIC import. It was previously an
  // unconditional `await import('@oybc/shared')` here — harmless when this
  // function opened its own transaction (the import awaited before the txn),
  // but fatal once PR-4 composed Board-Edit Save into one outer Dexie
  // transaction: an awaited dynamic import inside an open Dexie transaction
  // leaves its zone, throwing PrematureCommitError on EVERY real Save in the
  // browser (invisible to node-side vitest timing; caught by the first e2e to
  // ever press Save). Never dynamic-import inside transactional code.

  const sanitized: Partial<Board> = {};
  if (patch.name !== undefined) sanitized.name = patch.name;
  if (patch.timeframe !== undefined) sanitized.timeframe = patch.timeframe;
  if (patch.startDate != null) sanitized.startDate = patch.startDate;
  // Clear the deadline when converting to an indefinite board or when the
  // edit explicitly passes `endDate: null`. Writing `undefined` clears the
  // stored value (same mechanism the centerTaskId clear below relies on — a
  // bare omit can't clear, but an undefined write does). Otherwise apply a
  // provided endDate.
  if (patch.timeframe === Timeframe.INDEFINITE || patch.endDate === null) {
    sanitized.endDate = undefined;
  } else if (patch.endDate != null) {
    sanitized.endDate = patch.endDate;
  }

  if (patch.centerSquareType !== undefined) {
    sanitized.centerSquareType = patch.centerSquareType;
    // Sanitize auxiliary center fields based on the new type.
    if (patch.centerSquareType !== CenterSquareType.CHOSEN) {
      // Switching away from CHOSEN → clear centerTaskId so no stale
      // reference remains. The underlying BoardTask row is preserved
      // (the placement lives in boardTasks, not on the board row itself).
      // NOTE (center-switch asymmetry): switching CHOSEN → FREE
      // does NOT delete the BoardTask row — the placement is retained so a
      // later switch back to CHOSEN can reuse it. The board.centerTaskId
      // field merely controls which type the center cell renders as.
      sanitized.centerTaskId = undefined;
    } else if (patch.centerTaskId != null) {
      sanitized.centerTaskId = patch.centerTaskId;
    }
  }

  // DB-level guard (matches the iOS twin): a sealed or deleted board must
  // never take a metadata edit — the app-shell backstop can seal a board
  // while an edit session is already open, and sealed boards never mutate
  // except via deterministic pull-path re-derivation. UI gates exist
  // (Board Edit gates on !sealedAt) but the DB level must hold too.
  const target = await db.boards.get(boardId);
  if (!target || target.isDeleted || target.sealedAt) return;

  // 1. Apply patch (bumps version, enqueues boards sync entry).
  await updateBoard(boardId, sanitized);

  // 2. Fetch placed tasks.
  const placements = await db.boardTasks
    .where('boardId')
    .equals(boardId)
    .filter((bt) => !bt.isDeleted)
    .toArray();

  if (placements.length === 0) return;

  // 3. Batch cascade: load shared tables ONCE, find the union of affected
  //    board IDs across all placed tasks, then write one stats update per
  //    affected board. This replaces the previous per-task loop which did
  //    O(N) full-table scans for a 5×5 board (25 cascade calls).
  const taskIds = Array.from(new Set(placements.map((bt) => bt.taskId)));

  // Windowed Completion — build the event map BEFORE the rw transaction so the
  // cascade resolves each board against its own window (not the lifetime cache),
  // and `db.taskEvents` need not be in the transaction scope.
  const windowContext = await buildWindowContext();

  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();
      const allChildren = await fetchAllCompoundChildren();
      const allBoardTasks = await fetchAllBoardTasks();
      const allTasks = await db.tasks.toArray();
      const allBoards = await db.boards.toArray();

      const taskById: Record<string, Task> = {};
      for (const t of allTasks) taskById[t.id] = t;

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) {
        (childrenByCompound[c.compoundTaskId] ??= []).push(c);
      }

      // Collect the union of all affected board IDs across every placed task.
      const affectedBoardIds = new Set<string>();
      for (const taskId of taskIds) {
        const parents = findTransitiveParentCompounds(taskId, allChildren);
        for (const bid of findAffectedBoardIds(taskId, parents, allBoardTasks)) {
          affectedBoardIds.add(bid);
        }
      }

      // Update each affected board exactly once.
      for (const affectedBoardId of affectedBoardIds) {
        const affectedBoard = allBoards.find((b) => b.id === affectedBoardId);
        if (!affectedBoard || affectedBoard.isDeleted) continue;

        // Re-fetch so we see the just-written metadata update (updateBoard ran above).
        const freshBoard = await db.boards.get(affectedBoardId);
        if (!freshBoard || freshBoard.isDeleted || freshBoard.sealedAt) continue;

        // Board-integrity PR-2 (Part 2) — resolve through the shared winner
        // rule before deriving (see boardTasks.ts cascades for why).
        const boardTasksOnBoard = resolvePlacements(
          allBoardTasks.filter((bt) => bt.boardId === affectedBoardId),
          freshBoard.boardSize,
        );
        const stats = computeBoardStatsUpdate(
          freshBoard,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
          windowContext,
        );

        const isGreenlog = stats.completedTasks >= freshBoard.boardSize * freshBoard.boardSize;

        const boardUpdate: Partial<Board> = {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
          updatedAt: now,
          version: (freshBoard.version ?? 1) + 1,
        };

        if (isGreenlog && freshBoard.status === BoardStatus.ACTIVE) {
          boardUpdate.status = BoardStatus.COMPLETED;
          boardUpdate.completedAt = now;
        }
        if (!isGreenlog && freshBoard.status === BoardStatus.COMPLETED) {
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

/**
 * Fetch all boards for a user (excluding deleted)
 */
export async function fetchBoards(userId: string): Promise<Board[]> {
  return db.boards
    .filter((b) => b.userId === userId && !b.isDeleted)
    .reverse()
    .sortBy('updatedAt');
}

/**
 * Fetch a single board by ID
 */
export async function fetchBoard(id: string): Promise<Board | undefined> {
  return db.boards.get(id);
}

/**
 * Fetch every non-deleted board across all users in the workspace.
 *
 * Reactive callers (task-library / filter surfaces) that don't scope to a
 * single userId use this. Order is Dexie's insertion/primary-key order —
 * callers that need a display order sort in memory.
 *
 * @returns All non-deleted Board rows (unsorted).
 */
export async function fetchAllBoards(): Promise<Board[]> {
  return db.boards.filter((b) => !b.isDeleted).toArray();
}

/**
 * Fetch every non-deleted board across all users, sorted by name.
 *
 * Used by pickers (e.g. the Achievement board picker) that render a
 * name-ordered list.
 *
 * @returns All non-deleted Board rows, sorted ascending by `name`.
 */
export async function fetchAllBoardsSortedByName(): Promise<Board[]> {
  return db.boards.filter((b) => !b.isDeleted).sortBy('name');
}

/**
 * Fetch non-deleted boards by an explicit set of ids.
 *
 * @param ids - Board ids to fetch.
 * @returns The matching non-deleted Board rows.
 */
export async function fetchBoardsByIds(ids: string[]): Promise<Board[]> {
  return db.boards.where('id').anyOf(ids).filter((b) => !b.isDeleted).toArray();
}

/**
 * Fetch the user's CORE boards for a timeframe.
 *
 * Uses the `[userId+timeframe+status]` compound index to scan only the
 * user's boards in that timeframe, then narrows in memory on
 * `!isDeleted && isCore` (IndexedDB boolean keys are unreliable, so those
 * predicates are JS-filtered — see `useCoreBoardBrowser` for the rationale).
 *
 * @param userId    - Owning user.
 * @param timeframe - The core timeframe (daily / weekly / monthly / yearly).
 * @returns The user's non-deleted core Board rows for that timeframe.
 */
export async function fetchCoreBoardsForTimeframe(
  userId: string,
  timeframe: Timeframe,
): Promise<Board[]> {
  return db.boards
    .where('[userId+timeframe+status]')
    .between(
      [userId, timeframe, ''] as readonly unknown[],
      [userId, timeframe, '￿'] as readonly unknown[],
    )
    .and((b) => !b.isDeleted && b.isCore === true)
    .toArray();
}

/**
 * Create a new board
 */
export async function createBoard(
  userId: string,
  input: CreateBoardInput,
  /** Optional fields not on CreateBoardInput. Currently used by the
   *  wizard to carry the Phase 6.1 `isCore` marker when launched from
   *  the recurring banner. Kept off CreateBoardInput so external
   *  callers don't need to think about provenance fields. */
  options: { isCore?: boolean } = {},
): Promise<Board> {
  const board: Board = {
    id: generateUUID(),
    userId,
    name: input.name,
    description: input.description,
    status: BoardStatus.DRAFT,
    boardSize: input.boardSize,
    timeframe: input.timeframe,
    startDate: input.startDate,
    endDate: input.endDate,
    centerSquareType: input.centerSquareType,
    centerTaskId: input.centerTaskId,
    isRandomized: input.isRandomized,
    totalTasks: input.boardSize * input.boardSize,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
    isCore: options.isCore === true,
  };

  await db.boards.add(board);
  await addToSyncQueue('boards', board.id, SyncOperationType.CREATE, board);
  return board;
}

/**
 * Update a board
 */
export async function updateBoard(
  id: string,
  updates: Partial<Board>
): Promise<void> {
  const board = await db.boards.get(id);
  if (!board) return;
  await db.boards.update(id, {
    ...updates,
    updatedAt: currentTimestamp(),
    version: (board.version ?? 0) + 1,
  });
  const updated = await db.boards.get(id);
  if (updated) await addToSyncQueue('boards', id, SyncOperationType.UPDATE, updated);
}

/**
 * Archive a board. Sets `status = ARCHIVED`, bumps `version`, enqueues sync.
 *
 * The board is NOT deleted — it remains readable and can be restored.
 * Mirrors the shape of the soft-`deleteBoard` helper (read → update → re-fetch → enqueue).
 * `BoardStatus.ARCHIVED` already exists in the shared enum; no schema change needed.
 */
export async function archiveBoard(id: string): Promise<void> {
  const existing = await db.boards.get(id);
  if (!existing) return;
  await db.boards.update(id, {
    status: BoardStatus.ARCHIVED,
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const board = await db.boards.get(id);
  if (board) await addToSyncQueue('boards', id, SyncOperationType.UPDATE, board);
}

/**
 * Soft delete a board.
 *
 * Increments `version` so LWW conflict resolution treats the deletion
 * as a later-wins operation against any concurrent update on another
 * device. See `deleteTask` for the same rationale.
 */
export async function deleteBoard(id: string): Promise<void> {
  const existing = await db.boards.get(id);
  if (!existing) return;
  await db.boards.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const board = await db.boards.get(id);
  if (board) await addToSyncQueue('boards', id, SyncOperationType.DELETE, board);
}

/**
 * Delete a DRAFT board and its attached BoardTask placements atomically.
 *
 * Used by the Create Hub's drafts-list delete affordance. Soft-deletes the
 * Board (so sync propagates the tombstone) and soft-deletes (tombstones)
 * the BoardTask rows too (docs/BOARD_INTEGRITY.md — a hard delete here
 * would let the pushed tombstone lose the LWW tie-break and resurrect the
 * placement on the next pull; see `deleteBoardTasksForBoard`). Both happen
 * inside one Dexie transaction so a mid-flight failure rolls back instead
 * of leaving orphan BoardTask rows pointing at a soft-deleted Board.
 *
 * Caller is responsible for confirming the user wants the deletion.
 */
export async function deleteDraftWithCascade(id: string): Promise<void> {
  await db.transaction('rw', [db.boards, db.boardTasks, db.syncQueue], async () => {
    const existing = await db.boards.get(id);
    if (!existing) return;
    // Helper is draft-only by design — the caller (Create Hub drafts list)
    // never passes a non-draft board. Throwing on misuse keeps the
    // helper from silently destroying ACTIVE/COMPLETED placements if a
    // future caller forgets the gate. For "delete an active board",
    // use `deleteBoard(id)` (which leaves BoardTask rows in place).
    if (existing.status !== BoardStatus.DRAFT) {
      throw new Error(
        `deleteDraftWithCascade: board ${id} has status "${existing.status}", not "draft". ` +
          `Use deleteBoard() for non-draft boards.`,
      );
    }

    const now = currentTimestamp();
    const placements = await db.boardTasks.where('boardId').equals(id).filter((bt) => !bt.isDeleted).toArray();
    for (const bt of placements) {
      const tombstoned = buildBoardTaskTombstone(bt, now);
      await db.boardTasks.update(bt.id, tombstoned);
      await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, tombstoned);
    }

    await db.boards.update(id, {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (existing.version ?? 0) + 1,
    });
    const board = await db.boards.get(id);
    if (board) await addToSyncQueue('boards', id, SyncOperationType.DELETE, board);
  });
}

// NOTE (pre-WC audit, issue #379): the legacy `updateBoardStats` /
// `completeBoard` hand-write helpers were DELETED here. They pre-dated
// Windowed Completion, had zero callers, and wiring them up would have
// bypassed the windowed derivation pass — board stats and status flips are
// derivation-pass output ONLY (`runBoardCascadeForTask(s)` /
// `runBoardCascadeForBoardId` in orchestration.ts). Do not reintroduce a
// direct stat/status writer.

/**
 * Activate a board (transition from DRAFT to ACTIVE)
 *
 * @param boardId - The board to activate
 */
export async function activateBoard(boardId: string): Promise<void> {
  const board = await db.boards.get(boardId);
  if (!board || board.status !== BoardStatus.DRAFT) return;
  await db.boards.update(boardId, {
    status: BoardStatus.ACTIVE,
    // Windowed Completion — stamp the activation instant (only if not already
    // set) so the auto-seal backstop keys off max(endDate, activatedAt) and a
    // draft activated after its window expired still gets a prompt cycle.
    activatedAt: board.activatedAt ?? currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (board.version ?? 0) + 1,
  });
  // Re-fetch so the enqueued payload captures the post-activate status
  // and bumped version — otherwise Firestore would only ever see the
  // original DRAFT snapshot from the paired create, and the ACTIVE
  // transition wouldn't reach other devices until an unrelated update.
  const activated = await db.boards.get(boardId);
  if (activated) await addToSyncQueue('boards', boardId, SyncOperationType.UPDATE, activated);
}

/**
 * Fetch boards by timeframe (for achievement tracking)
 */
export async function fetchBoardsByTimeframe(
  userId: string,
  timeframe: string
): Promise<Board[]> {
  return db.boards
    .where('[userId+timeframe+status]')
    // Dexie's `.equals()` signature takes `IndexableType` and doesn't
    // model compound-index tuples; `any` is the project convention for
    // this specific library-typing quirk.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    .equals([userId, timeframe, BoardStatus.COMPLETED] as any)
    .toArray();
}

/**
 * Count boards with bingos by timeframe
 */
export async function countBingos(
  userId: string,
  timeframe: string
): Promise<number> {
  return db.boards
    .where('[userId+timeframe+linesCompleted]')
    .between(
      [userId, timeframe, 1] as readonly unknown[],
      [userId, timeframe, Infinity] as readonly unknown[]
    )
    .count();
}

/**
 * Count completed boards by timeframe
 */
export async function countCompletedBoards(
  userId: string,
  timeframe: string
): Promise<number> {
  return db.boards
    .filter((b) => b.userId === userId && !b.isDeleted && b.timeframe === timeframe && b.status === 'completed')
    .count();
}
