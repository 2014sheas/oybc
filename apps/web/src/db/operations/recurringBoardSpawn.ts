import { db } from '../database';
import {
  BoardStatus,
  SyncOperationType,
  SyncStatus,
  buildSpawnPlacement,
  validateSpawnPool,
  type Board,
  type BoardTask,
  type RecurringBoardTemplate,
  type Task,
  type PendingTemplateSpawn,
  type SpawnPoolFailureReason,
  type SyncQueueItem,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

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
      reason: SpawnPoolFailureReason | 'no_pool_tasks_resolved';
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

  // Resolve seedTaskIds → Task[]. Read outside the txn because Dexie
  // doesn't lock tables on read; the txn below scopes only the writes.
  // Tasks resolved here may end up soft-deleted between this read and the
  // txn — `validateSpawnPool` re-checks inside.
  const tasks = await db.tasks.where('id').anyOf(template.seedTaskIds).toArray();
  // Order tasks to match `seedTaskIds` (anyOf doesn't guarantee order),
  // dropping any ids that don't resolve. Drops are surfaced as
  // `pool_too_small` by validateSpawnPool — same actionable failure as
  // a literally-too-small pool.
  const tasksById = new Map<string, Task>(tasks.map((t) => [t.id, t]));
  const orderedPool: Task[] = template.seedTaskIds
    .map((id) => tasksById.get(id))
    .filter((t): t is Task => t !== undefined);

  if (orderedPool.length === 0) {
    return { ok: false, templateId: template.id, reason: 'no_pool_tasks_resolved' };
  }

  const validation = validateSpawnPool(template, orderedPool);
  if (!validation.ok) {
    return { ok: false, templateId: template.id, reason: validation.reason };
  }

  const placement = buildSpawnPlacement({
    template,
    poolTasks: orderedPool,
  });

  const boardId = generateUUID();
  const now = currentTimestamp();

  // Pre-build the rows + sync queue items so the transaction body is
  // synchronous (Dexie txns can host async work but keeping it tight
  // reduces transaction-stuck-open hazards on Firefox).
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
    centerSquareCustomName: template.centerSquareCustomName,
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
  };

  // For odd-sized boards, the center cell index is `floor(N²/2)`; for
  // even-sized, no center exists. `placement` already encodes FREE /
  // CUSTOM_FREE as `null` at the center, so we just check `t === null`
  // below — no separate branch needed.
  const centerCellIndex =
    template.boardSize % 2 === 1
      ? Math.floor((template.boardSize * template.boardSize) / 2)
      : -1;

  const boardTasks: BoardTask[] = [];
  for (let cell = 0; cell < placement.length; cell++) {
    const t = placement[cell];
    if (t === null) continue; // auto-completed FREE / CUSTOM_FREE center
    const row = Math.floor(cell / template.boardSize);
    const col = cell % template.boardSize;
    boardTasks.push({
      id: generateUUID(),
      boardId,
      taskId: t.id,
      row,
      col,
      isCenter: cell === centerCellIndex,
      isAchievementSquare: false,
      createdAt: now,
      updatedAt: now,
      version: 1,
    });
  }

  const updatedTemplate: RecurringBoardTemplate = {
    ...template,
    lastSpawnedWindowKey: windowStart,
    updatedAt: now,
    version: (template.version ?? 0) + 1,
  };

  const queueItems: SyncQueueItem[] = [
    buildSyncItem('boards', board.id, SyncOperationType.CREATE, board),
    ...boardTasks.map((bt) =>
      buildSyncItem('boardTasks', bt.id, SyncOperationType.CREATE, bt),
    ),
    buildSyncItem(
      'recurringBoardTemplates',
      updatedTemplate.id,
      SyncOperationType.UPDATE,
      updatedTemplate,
    ),
  ];

  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.recurringBoardTemplates, db.syncQueue],
    async () => {
      await db.boards.add(board);
      if (boardTasks.length > 0) await db.boardTasks.bulkAdd(boardTasks);
      await db.recurringBoardTemplates.put(updatedTemplate);
      await db.syncQueue.bulkAdd(queueItems);
    },
  );

  return { ok: true, boardId, templateId: template.id, windowStart };
}

function buildSyncItem(
  entityType: string,
  entityId: string,
  operationType: SyncOperationType,
  payload: unknown,
): SyncQueueItem {
  return {
    id: generateUUID(),
    entityType,
    entityId,
    operationType,
    payload: JSON.stringify(payload),
    status: SyncStatus.PENDING,
    retryCount: 0,
    createdAt: currentTimestamp(),
    priority: 0,
  };
}

// Note: Dexie `bulkAdd` with the manually-shaped queue items above
// bypasses `addToSyncQueue`'s playground-user short-circuit. There is
// no runtime assertion here that `template.userId !== 'playground-user-1'`
// — this is a documented assumption, NOT an enforced invariant. The
// spawn path is only invoked by signed-in users from the real Boards
// tab, so the assumption holds today. If a future refactor extends the
// playground to host the recurring-template surface, replicate the
// guard or convert this comment into an explicit dev-only check.
