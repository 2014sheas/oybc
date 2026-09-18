import { db } from '../internal';
import {
  buildRepeatBoardTemplateInput,
  isWindowStampedDerived,
  SyncOperationType,
  type Board,
  type RecurringBoardTemplate,
  type Timeframe,
  type WeekStartDay,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { isWindowStampedDerivedCompound } from './derivedCounters';

/**
 * "Repeat this board…" (P6, docs/POOLS_RECURRING.md §Surfaces item 7) — a
 * one-off board gaining a repeat cadence AFTER the fact. Unlike
 * `spawnTemplateBoard` (Phase 6.2), this does NOT spawn a new board: the
 * source board IS this window's board already. It only:
 *
 *   1. Mints a new `RecurringBoardTemplate` whose `manualTaskIds` are the
 *      board's currently-placed tasks, minus this window's derived compounds
 *      and with each derived counter recorded by its durable ROOT id
 *      (B2 RB4 as amended by final-review FI2), with `sources: []` /
 *      `manualTaskVary: {}` written explicitly (zero sources — an
 *      own-members record),
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
    // `tasks` is read-only here (the RB4 derived-compound check).
    [db.boards, db.boardTasks, db.tasks, db.recurringBoardTemplates, db.syncQueue],
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
      // One batched read for the RB4 check below (the batched style this
      // file's neighbours use), not a `get` per cell.
      const placedTasks = await db.tasks
        .where('id')
        .anyOf([...new Set(sortedBoardTasks.map((bt) => bt.taskId))])
        .toArray();
      const placedTaskById = new Map(placedTasks.map((t) => [t.id, t]));

      // RB4 amended (final-review FI2) — the roots behind any placed
      // window-stamped derived counters, in one batched read.
      const rootIds = [
        ...new Set(
          placedTasks
            .filter((t) => isWindowStampedDerived(t))
            .map((t) => t.sharedCounterId)
            .filter((id): id is string => id != null),
        ),
      ];
      const rootById = new Map(
        (rootIds.length > 0 ? await db.tasks.where('id').anyOf(rootIds).toArray() : []).map((t) => [
          t.id,
          t,
        ]),
      );

      const boardTaskIds: string[] = [];
      const seenTaskIds = new Set<string>();
      for (const bt of sortedBoardTasks) {
        // Board Sources §Member rules (B2, RB4) — a per-window derived
        // COMPOUND is this window's re-targeted copy of a source compound;
        // carrying it forward as a hand-added member would pin every future
        // window to it.
        const task = placedTaskById.get(bt.taskId);
        if (task && isWindowStampedDerivedCompound(task)) continue;
        // RB4 amended (final-review FI2) — a derived COUNTER is recorded by
        // its ROOT id, never its own. The derived row belongs to THIS board's
        // window and is retired with this board (RB5), so a record naming it
        // would be skipped as `has_deleted_tasks` for every future window the
        // day the user deletes the board they repeated. The root is durable
        // library content and is what each new window re-mints from anyway. A
        // root that is itself missing or deleted contributes no member.
        let memberId = bt.taskId;
        if (task && isWindowStampedDerived(task) && task.sharedCounterId != null) {
          const root = rootById.get(task.sharedCounterId);
          if (!root || root.isDeleted) continue;
          memberId = root.id;
        }
        if (seenTaskIds.has(memberId)) continue;
        seenTaskIds.add(memberId);
        boardTaskIds.push(memberId);
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
        // Board Sources §Member rules (B2, RB4) — authored, not inferred: a
        // repeat-this-board record pulls from no source at all, and no member
        // carries a vary level until a UI can author one. Writing both
        // explicitly keeps `sourcesForRecord`'s legacy-shape inference off
        // this record and gives the member-rules readers a real empty map.
        sources: [],
        manualTaskVary: {},
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
      // re-spawned). The version bump reads the LIVE row, never the
      // caller's possibly-stale snapshot (mirrors the iOS
      // `repeatBoardAsTemplate` in-transaction re-read): Board Edit's
      // two-phase Save commits a board write immediately before calling
      // this, and a stale-snapshot bump would fail to advance the version
      // — losing the LWW tie-break on sync.
      const liveBoard = await db.boards.get(board.id);
      const newVersion = ((liveBoard ?? board).version ?? 0) + 1;
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
