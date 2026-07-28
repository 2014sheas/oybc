import { db } from '../internal';
import { computePlacementIntegrityRepair, SyncOperationType } from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { buildBoardTaskTombstone } from './boardTasks';

/**
 * Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 1) — placement-integrity
 * repair pass. PR-1 gave `BoardTask` durable tombstones, but did nothing to
 * fix boards ALREADY corrupted from the pre-tombstone era (duplicate
 * placement rows left behind by an interrupted Replace/Move edit, or two
 * offline devices independently writing to the same cell before converging).
 *
 * Runs as a PRE-step in the existing app-open self-heal, BEFORE
 * `reDeriveActiveBoards` (`sealing.ts`) — see `useBackstopAutoSeal.ts` for
 * the call site: `runBackstopAutoSeal` → `repairPlacementIntegrity` →
 * `reDeriveActiveBoards`. Repair first, so the stats re-derive that follows
 * sees the ALREADY-clean placement set, not the corrupted one.
 *
 * Scope: the user's non-deleted boards, EVERY status — including sealed.
 * A sealed board's LIVE placement rows can still be corrupted (the
 * corruption predates sealing, or a pulled tombstone lost a stale LWW race
 * before this fix), so its rows are repaired too. What this pass does NOT
 * do: touch a sealed board's frozen snapshot (`sealedCompletedCells` /
 * `completedTasks` / etc.) — that snapshot is a separate, deliberately
 * immutable record; only the deterministic pull-path re-derivation
 * (`reDeriveSealedBoards*` in `sealing.ts`) is allowed to rewrite it. This
 * pass only tombstones placement rows, nothing on `Board` itself — no
 * stats rewrite happens here for ANY board (sealed or not); that is
 * `reDeriveActiveBoards`'s job, and it already excludes sealed boards.
 *
 * The winner rule (`computePlacementIntegrityRepair`, shared + vector-
 * pinned) is deterministic, so two devices repairing the SAME corrupted
 * board independently pick the SAME losers to tombstone — no ping-pong;
 * the tombstones then converge via ordinary per-row LWW, exactly like any
 * other soft-delete.
 *
 * Idempotent: a board with no violations contributes zero writes and is
 * skipped entirely (not even a transaction is opened if no board in the
 * user's workspace has anything to repair).
 *
 * @param userId The authenticated user's uid.
 * @param now    The write timestamp for any tombstones created (defaults to
 *               wall-clock).
 * @returns The ids of boards that had at least one placement tombstoned by
 *          this pass.
 */
export async function repairPlacementIntegrity(
  userId: string,
  now: string = currentTimestamp(),
): Promise<string[]> {
  const boards = await db.boards.filter((b) => b.userId === userId && !b.isDeleted).toArray();
  if (boards.length === 0) return [];

  const repairedBoardIds: string[] = [];

  await db.transaction('rw', [db.boardTasks, db.syncQueue], async () => {
    for (const board of boards) {
      const livePlacements = await db.boardTasks
        .where('boardId')
        .equals(board.id)
        .filter((bt) => !bt.isDeleted)
        .toArray();
      if (livePlacements.length === 0) continue;

      const { toTombstone } = computePlacementIntegrityRepair(livePlacements, board.boardSize);
      if (toTombstone.length === 0) continue;

      for (const bt of toTombstone) {
        const tombstoned = buildBoardTaskTombstone(bt, now);
        await db.boardTasks.update(bt.id, tombstoned);
        await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, tombstoned, 0);
      }
      repairedBoardIds.push(board.id);
    }
  });

  return repairedBoardIds;
}
