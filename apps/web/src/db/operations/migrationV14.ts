import type { Transaction } from 'dexie';
import { db } from '../internal';
import type { Board, Task, CompoundChild } from '@oybc/shared';
import {
  SyncOperationType,
  SyncStatus,
  computeBoardStatsUpdate,
  computeSealedCompletedCells,
  isBoardPastBackstop,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * Dexie v14 data migration — Windowed Completion expired-board sealing
 * (docs/WINDOWED_COMPLETION.md §Migration & backfill, step 3).
 *
 * Runs inside the v14 upgrade callback (one atomic transaction), AFTER v13's
 * event backfill. Every non-deleted, non-draft, non-indefinite board that is
 * ALREADY past its auto-seal backstop deadline at upgrade time is sealed
 * silently. Boards still inside their backstop window are left alone — they go
 * through the normal close-out prompt (slice 2).
 *
 * The frozen snapshot is computed from the PRE-MIGRATION rendered state (live
 * Task `isCompleted`/`currentCount` caches + compound evaluation) — i.e. the
 * derivation pass with NO window context (lifetime). This reproduces exactly
 * what the user currently sees on the board, and is deterministic across
 * devices: the caches were made consistent by the v13 backfill, so two devices
 * seal the same cells regardless of migration order. `sealedAt` is migration
 * wall-clock (per-device), but that only bounds the upper end of a window whose
 * events all predate it, so convergence holds via later re-derivation.
 *
 * The backstop deadline keys off `endDate` here (boards have no `activatedAt`
 * pre-v14 — the new field is null), which is deterministic and endDate-based.
 *
 * @param _tx The Dexie upgrade transaction (unused directly — Dexie binds all
 *            `db` table ops to the active transaction inside the callback).
 */
export async function runMigrationV14(_tx: Transaction): Promise<void> {
  const now = currentTimestamp();
  const nowMs = new Date(now).getTime();

  const allBoards: Board[] = await db.boards.toArray();
  const allBoardTasks = await db.boardTasks.toArray();
  const allTasks: Task[] = await db.tasks.toArray();
  const allChildren: CompoundChild[] = await db.compoundChildren.toArray();

  const taskById: Record<string, Task> = {};
  for (const t of allTasks) taskById[t.id] = t;
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const c of allChildren) {
    if (c.isDeleted) continue;
    (childrenByCompound[c.compoundTaskId] ??= []).push(c);
  }

  for (const board of allBoards) {
    // isBoardPastBackstop already excludes deleted / draft / indefinite /
    // already-sealed boards, and gates on the endDate-keyed backstop deadline.
    if (!isBoardPastBackstop(board, nowMs)) continue;

    const boardTasksOnBoard = allBoardTasks.filter((bt) => bt.boardId === board.id);
    // Lifetime derivation (explicit `undefined` window context) = pre-migration
    // rendered state. Deliberate: sealing an expired pre-v14 board freezes the
    // completion the user actually saw, which was lifetime-resolved.
    const stats = computeBoardStatsUpdate(
      board,
      boardTasksOnBoard,
      childrenByCompound,
      taskById,
      allBoards,
      undefined,
    );
    const cells = computeSealedCompletedCells(
      board,
      boardTasksOnBoard,
      childrenByCompound,
      taskById,
      allBoards,
      undefined,
    );

    const sealed: Board = {
      ...board,
      sealedAt: now,
      sealedCompletedCells: cells,
      completedTasks: stats.completedTasks,
      linesCompleted: stats.linesCompleted,
      completedLineIds: stats.completedLineIds,
      updatedAt: now,
      version: (board.version ?? 1) + 1,
    };
    await db.boards.put(sealed);

    // Enqueue sync UPDATE directly (NOT addToSyncQueue — that helper opens its
    // own transaction and isn't upgrade-tx-aware; mirrors migrationV13).
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'boards',
      entityId: board.id,
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify(sealed),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  }
}
