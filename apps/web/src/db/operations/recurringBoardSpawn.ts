import { db } from '../internal';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  buildSpawnPlacement,
  validateSpawnPool,
  computeBoardStatsUpdate,
  resolveMix,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
  type TaskEvent,
  type PendingTemplateSpawn,
  type SpawnPoolFailureReason,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * Recurring-board spawn (Phase 6.2).
 *
 * Atomically creates a Board + BoardTasks from a `PendingTemplateSpawn`,
 * and updates the template's `lastSpawnedWindowKey` in the same Dexie
 * transaction. If the multi-step write fails partway, the entire
 * transaction rolls back — the next Boards-tab open will retry.
 *
 * Multi-device race: two devices each open the Boards tab before sync
 * settles → both spawn the same window. Two boards land in Firestore
 * with different UUIDs but matching `spawnedFromTemplateId + startDate`.
 * Phase 6.2 MVP accepts this; user deletes the duplicate. Single-device
 * idempotency is structurally guaranteed by the
 * `findTemplatesPendingSpawn` belt (lastSpawnedWindowKey check + existing
 * Board scan).
 */

export type SpawnResult =
  | { ok: true; boardId: string; templateId: string; windowStart: string }
  | {
      ok: false;
      templateId: string;
      reason: SpawnPoolFailureReason | 'no_pool_tasks_resolved' | 'spawn_failed';
    };

/**
 * Spawn one board from a pending-spawn descriptor.
 *
 * @param spawn - From `findTemplatesPendingSpawn`. Carries the template +
 *                window boundaries.
 */
export async function spawnTemplateBoard(
  spawn: PendingTemplateSpawn,
): Promise<SpawnResult> {
  const { template, windowStart, windowEnd, suggestedName } = spawn;

  const boardId = generateUUID();
  const now = currentTimestamp();

  // Single transaction covers task resolution + pool validation +
  // placement + writes. Folding the read inside the same txn closes
  // the soft-delete race — without `db.tasks` in the scope, sync could
  // soft-delete a seed task between the read and the writes, allowing
  // a board to spawn against stale pool data.
  //
  // Returning a non-throwing skip outcome from within the txn requires
  // a sentinel pattern (Dexie aborts a txn on thrown errors but we
  // want to commit nothing AND return the structured failure cleanly).
  // The closure resolves to a SpawnResult; abort outcomes return
  // before reaching the writes.
  return await db.transaction(
    'rw',
    [
      db.boards,
      db.boardTasks,
      db.tasks,
      db.pools,
      db.compoundChildren,
      db.taskEvents,
      db.recurringBoardTemplates,
      db.syncQueue,
    ],
    async (): Promise<SpawnResult> => {
      // P1 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
      // §Changed: the spawn record) — the task source is the resolved
      // pool-mix, not `template.seedTaskIds` directly. Post-migration EVERY
      // live template has `poolIds` set, so `seedTaskIds` is never read
      // here (left verbatim on the record for decode-compat only — see
      // `RecurringBoardTemplate`'s docstring's "seedTaskIds end state").
      //
      // Single full-table reads (tasks, pools) rather than a targeted
      // `anyOf(seedTaskIds)` lookup: `resolveMix` needs a `tasksById` map
      // to filter each pool's OWN resolvable supply (deleted tasks skipped
      // — derived detachment), and the same `allTasks`/`tasksById` are
      // reused below for the spawn-time derivation pass, so this is not an
      // added read.
      const allTasks = await db.tasks.toArray();
      const tasksById: Record<string, Task> = {};
      for (const t of allTasks) tasksById[t.id] = t;

      const poolIds = template.poolIds ?? [];
      const pools = poolIds.length > 0 ? await db.pools.where('id').anyOf(poolIds).toArray() : [];
      const poolsById: Record<string, Pool> = {};
      for (const p of pools) poolsById[p.id] = p;

      const mix = resolveMix(template, poolsById, tasksById);
      // Resolve mix task ids → Task[] in mix order. Drops any ids that
      // don't resolve at all (e.g. a hard-gone manual reference — the
      // manual layer isn't deleted-filtered by resolveMix itself); the
      // validator below catches a resolved-but-deleted task (possible
      // for a manual-sourced id, since resolveMix only filters deletion
      // for pool-sourced supply) as `has_deleted_tasks`.
      const orderedPool: Task[] = mix.taskIds
        .map((id) => tasksById[id])
        .filter((t): t is Task => t !== undefined);

      if (orderedPool.length === 0) {
        return {
          ok: false,
          templateId: template.id,
          reason: 'no_pool_tasks_resolved',
        };
      }

      const validation = validateSpawnPool(template, orderedPool);
      if (!validation.ok) {
        return {
          ok: false,
          templateId: template.id,
          reason: validation.reason,
        };
      }

      const placement = buildSpawnPlacement({
        template,
        poolTasks: orderedPool,
      });

      const board: Board = {
        id: boardId,
        userId: template.userId,
        name: suggestedName,
        status: BoardStatus.ACTIVE,
        boardSize: template.boardSize,
        timeframe: template.timeframe,
        startDate: windowStart,
        endDate: windowEnd,
        centerSquareType: template.centerSquareType,
        isRandomized: template.isRandomized,
        totalTasks: template.boardSize * template.boardSize,
        completedTasks: 0,
        linesCompleted: 0,
        completedLineIds: [],
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
        spawnedFromTemplateId: template.id,
        // Phase 6.1 — template-spawned boards are core by construction.
        // They fulfill the same "recurring board for this window exists"
        // promise as banner-spawned boards, so the recurring banner
        // detector must treat them the same.
        isCore: true,
      };

      // For odd-sized boards, the center cell index is `floor(N²/2)`;
      // for even-sized, no center exists. `placement` encodes a FREE
      // center as `null`, so the `t === null`
      // check below covers the "auto-completed center" case directly.
      const centerCellIndex =
        template.boardSize % 2 === 1
          ? Math.floor((template.boardSize * template.boardSize) / 2)
          : -1;

      const boardTasks: BoardTask[] = [];
      for (let cell = 0; cell < placement.length; cell++) {
        const t = placement[cell];
        if (t === null) continue; // auto-completed FREE center
        const row = Math.floor(cell / template.boardSize);
        const col = cell % template.boardSize;
        boardTasks.push({
          id: generateUUID(),
          boardId,
          taskId: t.id,
          row,
          col,
          // isCenter marks a CHOSEN centre task only. Recurring templates
          // never use CHOSEN (free = null centre slot, none = an
          // ordinary task), so this is effectively always false — but gating
          // on CHOSEN keeps it correct + prevents a stale isCenter from
          // syncing to iOS as a gold "FREE" cell over a real task.
          isCenter:
            cell === centerCellIndex &&
            template.centerSquareType === CenterSquareType.CHOSEN,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        });
      }

      // Windowed Completion (docs/WINDOWED_COMPLETION.md §What this closes —
      // respawn-bleed row): run the derivation pass at spawn so stored stats are
      // derivation output, not a hand-initialized 0. A fresh window has no events,
      // so event-owning squares resolve incomplete (no respawn bleed); a
      // FREE center still auto-fills. The invariant "stored stats are
      // always derivation output" now holds from the first row written.
      const allChildren = (await db.compoundChildren.toArray()).filter((c) => !c.isDeleted);
      const childrenByCompound: Record<string, CompoundChild[]> = {};
      for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);
      // Reuse the `tasksById` map read at the top of this closure for
      // mix resolution — no writes to `tasks` happen in between, so it's
      // still an accurate snapshot for the derivation pass.
      const taskById: Record<string, Task> = tasksById;
      const eventsByTaskId: Record<string, TaskEvent[]> = {};
      for (const e of await db.taskEvents.toArray()) {
        if (e.isDeleted) continue;
        (eventsByTaskId[e.taskId] ??= []).push(e);
      }
      const allBoards = await db.boards.toArray();
      const stats = computeBoardStatsUpdate(
        board,
        boardTasks,
        childrenByCompound,
        taskById,
        allBoards,
        { eventsByTaskId },
      );
      board.completedTasks = stats.completedTasks;
      board.linesCompleted = stats.linesCompleted;
      board.completedLineIds = stats.completedLineIds;

      const updatedTemplate: RecurringBoardTemplate = {
        ...template,
        lastSpawnedWindowKey: windowStart,
        updatedAt: now,
        version: (template.version ?? 0) + 1,
      };

      await db.boards.add(board);
      if (boardTasks.length > 0) await db.boardTasks.bulkAdd(boardTasks);
      await db.recurringBoardTemplates.put(updatedTemplate);

      // Enqueue through the D3 choke point (per-entity coalescing). The
      // board + boardTasks are freshly-minted UUIDs so their lookups are
      // no-op appends; the template UPDATE coalesces with any pending
      // template edit.
      await addToSyncQueue('boards', board.id, SyncOperationType.CREATE, board);
      for (const bt of boardTasks) {
        await addToSyncQueue('boardTasks', bt.id, SyncOperationType.CREATE, bt);
      }
      await addToSyncQueue(
        'recurringBoardTemplates',
        updatedTemplate.id,
        SyncOperationType.UPDATE,
        updatedTemplate,
      );

      return { ok: true, boardId, templateId: template.id, windowStart };
    },
  );
}
