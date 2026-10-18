import { db } from '../internal';
import {
  BoardStatus,
  SyncOperationType,
  planPlacementSweep,
  withNormalizedPlacementFields,
  type Board,
  type BoardTask,
  type SweepBoardOutcome,
  type SweepRepoint,
  type Task,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue, stampTransactionSyncOwner } from './syncQueue';
import { runBoardCascadeForBoardId } from './orchestration';
import { reDeriveSealedBoardsByIds } from './sealing';
import { softDeleteWindowStampedDerived } from './derivedCounters';
import { rekeyDraftMix, rekeyPool, rekeyTemplate } from './placementSweepRekey';

/**
 * placementSweep.ts — the web applier of the migration sweep
 * (docs/TASK_WINDOW_REWORK.md §Migration sweep, slice 4a: derived counters).
 * The plan is `planPlacementSweep` (shared, pure, equivalence-gated); this
 * module writes it as authored rows in ONE transaction and re-derives the
 * touched boards. State-based and idempotent: it exits without a write when
 * no marked row exists.
 */

export interface PlacementSweepSummary {
  repoints: number;
  strips: number;
  orphans: number;
  rekeyedTemplates: number;
  rekeyedPools: number;
  rekeyedDrafts: number;
  refused: SweepBoardOutcome[];
}

const EMPTY_SUMMARY: PlacementSweepSummary = {
  repoints: 0,
  strips: 0,
  orphans: 0,
  rekeyedTemplates: 0,
  rekeyedPools: 0,
  rekeyedDrafts: 0,
  refused: [],
};

/** The placement as the repoint writes it: new task, carried parameters, others cleared. */
async function writeRepoint(bt: BoardTask, r: SweepRepoint, now: string): Promise<void> {
  const { targetOverride: _t, targetKind: _k, titleOverride: _o, childTargets: _c, ...base } = bt;
  const patched: BoardTask = withNormalizedPlacementFields({
    ...base,
    taskId: r.toTaskId,
    ...(r.targetOverride !== undefined ? { targetOverride: r.targetOverride, targetKind: r.targetKind } : {}),
    ...(r.childTargets !== undefined ? { childTargets: r.childTargets } : {}),
    ...(r.titleOverride !== undefined ? { titleOverride: r.titleOverride } : {}),
    updatedAt: now,
    version: (bt.version ?? 0) + 1,
  } as BoardTask);
  await db.boardTasks.put(patched);
  await addToSyncQueue('boardTasks', bt.id, SyncOperationType.UPDATE, patched, 0);
}

/**
 * Repoint a placement on a SEALED board — the documented exception to
 * "sealed boards never mutate": the same write as a live repoint, followed by
 * the deterministic sealed re-derivation (done once per board by the caller).
 * Must run inside the sweep's transaction.
 *
 * @param boardTaskId - The placement to repoint.
 * @param repoint - The planned repoint.
 * @param now - ISO8601 write instant.
 */
export async function repointSealedPlacement(
  boardTaskId: string,
  repoint: SweepRepoint,
  now: string,
): Promise<void> {
  const bt = await db.boardTasks.get(boardTaskId);
  if (!bt || bt.isDeleted || bt.taskId !== repoint.fromTaskId) return;
  await writeRepoint(bt, repoint, now);
}

async function repointLivePlacement(boardTaskId: string, repoint: SweepRepoint, now: string): Promise<void> {
  const bt = await db.boardTasks.get(boardTaskId);
  if (!bt || bt.isDeleted || bt.taskId !== repoint.fromTaskId) return;
  await writeRepoint(bt, repoint, now);
}

/** Clear a marked row's window fields (ABSENT, so the clearable sync carries them) and its baseline. */
async function stripWindowMarks(taskId: string, now: string): Promise<boolean> {
  const t = await db.tasks.get(taskId);
  if (!t || t.isDeleted) return false;
  const { timeframe: _tf, startDate: _s, endDate: _e, ...rest } = t;
  const stripped: Task = { ...rest, baseline: 0, updatedAt: now, version: (t.version ?? 0) + 1 };
  await db.tasks.put(stripped);
  await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, stripped, 0);
  return true;
}

/**
 * Run the migration sweep for one user (derived counters). Safe at every app
 * open and after every clean pull; a workspace with no marked row writes
 * nothing.
 *
 * @param userId - The signed-in user's uid.
 * @param now - ISO8601 write instant.
 * @returns What the run wrote and which boards the gate refused.
 */
export async function runPlacementSweep(
  userId: string,
  now: string = currentTimestamp(),
): Promise<PlacementSweepSummary> {
  return db.transaction(
    'rw',
    [
      db.boards,
      db.boardTasks,
      db.tasks,
      db.compoundChildren,
      db.taskEvents,
      db.recurringBoardTemplates,
      db.pools,
      db.syncQueue,
    ],
    async () => {
      stampTransactionSyncOwner(userId);
      const tasks = (await db.tasks.toArray()).filter((t) => t.userId === userId);
      const boards = (await db.boards.toArray()).filter((b) => b.userId === userId);
      const boardIds = new Set(boards.map((b) => b.id));
      const taskIds = new Set(tasks.map((t) => t.id));
      const boardTasks = (await db.boardTasks.toArray()).filter((bt) => boardIds.has(bt.boardId));
      const compoundChildren = (await db.compoundChildren.toArray()).filter((c) => !c.isDeleted);
      const events = (await db.taskEvents.toArray()).filter((e) => !e.isDeleted && taskIds.has(e.taskId));

      const plan = planPlacementSweep({ tasks, boards, boardTasks, compoundChildren, events }, now);
      if (plan.repoints.length === 0 && plan.strips.length === 0 && plan.orphanTombstones.length === 0) {
        return { ...EMPTY_SUMMARY };
      }

      const boardById = new Map(boards.map((b) => [b.id, b]));
      for (const r of plan.repoints) {
        if (boardById.get(r.boardId)?.sealedAt) await repointSealedPlacement(r.boardTaskId, r, now);
        else await repointLivePlacement(r.boardTaskId, r, now);
      }

      let strips = 0;
      for (const id of plan.strips) if (await stripWindowMarks(id, now)) strips += 1;

      const orphans = await softDeleteWindowStampedDerived(plan.orphanTombstones, now);

      const rekeyed = await rekeyStoredRules(userId, tasks, boards, plan.rekey, now);

      const sealedTouched: string[] = [];
      for (const boardId of plan.touchedBoardIds) {
        if (boardById.get(boardId)?.sealedAt) sealedTouched.push(boardId);
        else await runBoardCascadeForBoardId(boardId);
      }
      await reDeriveSealedBoardsByIds(sealedTouched);

      return {
        repoints: plan.repoints.length,
        strips,
        orphans,
        ...rekeyed,
        refused: plan.outcomes.filter((o) => o.outcome === 'refused'),
      };
    },
  );
}

/** Re-key templates, pools and draft blobs; authors a row only when it changed. */
async function rekeyStoredRules(
  userId: string,
  tasks: Task[],
  boards: Board[],
  map: Record<string, string>,
  now: string,
): Promise<Pick<PlacementSweepSummary, 'rekeyedTemplates' | 'rekeyedPools' | 'rekeyedDrafts'>> {
  const out = { rekeyedTemplates: 0, rekeyedPools: 0, rekeyedDrafts: 0 };
  if (Object.keys(map).length === 0) return out;
  const tasksById = new Map(tasks.map((t) => [t.id, t]));

  for (const t of (await db.recurringBoardTemplates.toArray()).filter((x) => x.userId === userId)) {
    const patch = rekeyTemplate(t, map, tasksById);
    if (!patch) continue;
    const next = { ...t, ...patch, updatedAt: now, version: (t.version ?? 0) + 1 };
    await db.recurringBoardTemplates.put(next);
    await addToSyncQueue('recurringBoardTemplates', t.id, SyncOperationType.UPDATE, next, 0);
    out.rekeyedTemplates += 1;
  }
  for (const p of (await db.pools.toArray()).filter((x) => x.userId === userId)) {
    const patch = rekeyPool(p, map);
    if (!patch) continue;
    const next = { ...p, ...patch, updatedAt: now, version: (p.version ?? 0) + 1 };
    await db.pools.put(next);
    await addToSyncQueue('pools', p.id, SyncOperationType.UPDATE, next, 0);
    out.rekeyedPools += 1;
  }
  for (const b of boards) {
    if (b.isDeleted || b.status !== BoardStatus.DRAFT) continue;
    const blob = rekeyDraftMix(b.recurringDraftMix, map);
    if (blob === null) continue;
    const next: Board = { ...b, recurringDraftMix: blob, updatedAt: now, version: (b.version ?? 0) + 1 };
    await db.boards.put(next);
    await addToSyncQueue('boards', b.id, SyncOperationType.UPDATE, next, 0);
    out.rekeyedDrafts += 1;
  }
  return out;
}
