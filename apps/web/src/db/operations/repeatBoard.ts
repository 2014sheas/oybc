import { db } from '../internal';
import {
  buildRepeatBoardTemplateInput,
  SyncOperationType,
  type Board,
  type RecurringBoardTemplate,
  type Timeframe,
  type WeekStartDay,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * "Repeat this board…" (P6, docs/POOLS_RECURRING.md §Surfaces item 7) — a
 * one-off board gaining a repeat cadence AFTER the fact. Unlike
 * `spawnTemplateBoard` (Phase 6.2), this does NOT spawn a new board: the
 * source board IS this window's board already. It only:
 *
 *   1. Mints a new `RecurringBoardTemplate` whose `manualTaskIds` are the
 *      board's currently-placed tasks (zero pools — an own-mix record),
 *      with `lastSpawnedWindowKey` pre-seeded to the CHOSEN cadence's
 *      window containing the board's start date
 *      (`buildRepeatBoardTemplateInput` — critically keyed off `cadence`,
 *      never `board.timeframe`).
 *   2. Back-stamps the source board's `spawnedFromTemplateId` so the
 *      manage row / paused badge / spawn idempotency belt all resolve.
 *
 * Both writes + their sync-queue entries happen inside one Dexie
 * transaction (mirrors `spawnTemplateBoard` in `recurringBoardSpawn.ts` —
 * the established atomicity precedent for multi-table recurring-board
 * writes) so a partial failure never leaves an orphaned template or a
 * board pointing at a template that doesn't exist.
 *
 * @param board - The source one-off board (must not itself already be
 *   `spawnedFromTemplateId != null` — the caller gates the CTA on that).
 * @param cadence - The newly-chosen repeat cadence (DAILY/WEEKLY/MONTHLY/
 *   YEARLY — the cadence picker excludes CUSTOM).
 * @param userId - Owner of the new template.
 * @param weekStartDay - Only relevant when `cadence === WEEKLY`.
 * @returns The newly-created `RecurringBoardTemplate`.
 */
export async function repeatBoardAsRecurring(
  board: Board,
  cadence: Timeframe,
  userId: string,
  weekStartDay: WeekStartDay,
): Promise<RecurringBoardTemplate> {
  const now = currentTimestamp();

  return await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.recurringBoardTemplates, db.syncQueue],
    async (): Promise<RecurringBoardTemplate> => {
      // Read the board's live, non-deleted placements, sorted by grid
      // position, mapped to distinct taskIds (dedup preserving order —
      // a task placed on multiple cells, which shouldn't normally happen
      // post board-integrity hardening, still contributes only once).
      const rawBoardTasks = await db.boardTasks
        .where('boardId')
        .equals(board.id)
        .filter((bt) => !bt.isDeleted)
        .toArray();
      const sortedBoardTasks = [...rawBoardTasks].sort(
        (a, b) => a.row * board.boardSize + a.col - (b.row * board.boardSize + b.col),
      );
      const boardTaskIds: string[] = [];
      const seenTaskIds = new Set<string>();
      for (const bt of sortedBoardTasks) {
        if (seenTaskIds.has(bt.taskId)) continue;
        seenTaskIds.add(bt.taskId);
        boardTaskIds.push(bt.taskId);
      }

      const input = buildRepeatBoardTemplateInput(board, boardTaskIds, cadence, weekStartDay);

      const template: RecurringBoardTemplate = {
        id: generateUUID(),
        userId,
        name: input.name,
        timeframe: input.timeframe,
        boardSize: input.boardSize,
        centerSquareType: input.centerSquareType,
        isRandomized: input.isRandomized,
        seedTaskIds: [...input.seedTaskIds],
        poolIds: [...input.poolIds],
        manualTaskIds: [...input.manualTaskIds],
        removedTaskIds: [...input.removedTaskIds],
        lastSpawnedWindowKey: input.lastSpawnedWindowKey,
        isActive: input.isActive,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      };

      await db.recurringBoardTemplates.add(template);
      await addToSyncQueue(
        'recurringBoardTemplates',
        template.id,
        SyncOperationType.CREATE,
        template,
      );

      // Back-stamp the source board. Only `spawnedFromTemplateId` +
      // version/updatedAt change — isCore/status/every other field is
      // left exactly as-is (this board already existed; it isn't being
      // re-spawned).
      const newVersion = (board.version ?? 0) + 1;
      await db.boards.update(board.id, {
        spawnedFromTemplateId: template.id,
        version: newVersion,
        updatedAt: now,
      });
      const updatedBoard = await db.boards.get(board.id);
      if (updatedBoard) {
        await addToSyncQueue('boards', board.id, SyncOperationType.UPDATE, updatedBoard);
      }

      return template;
    },
  );
}
