import { afterEach, describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  resolveMix,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { spawnTemplateBoard } from '../recurringBoardSpawn';

/**
 * P1 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Changed: the spawn record) — integration coverage that the SPAWN PATH
 * (not just `resolveMix` in isolation, already unit-tested in
 * `packages/shared/tests/algorithms/poolMix.test.ts`) correctly wires a
 * multi-pool + removals + manual-additions record through to the board it
 * places. Mirrors the doc's worked example shape (two overlapping pools,
 * a removal suppressing the overlap, a manual addition).
 */

const NOW = '2026-07-19T00:00:00.000Z';
const WINDOW_START = '2026-07-19T00:00:00.000Z';
const WINDOW_END = '2026-07-19T23:59:59.999Z';

async function seedTask(id: string): Promise<Task> {
  const task: Task = {
    id,
    userId: 'user-1',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
  return task;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.pools.clear();
  await db.recurringBoardTemplates.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('spawnTemplateBoard — P1 pool-mix resolution', () => {
  it('resolves (union(pools) - removals) + manual through to the placed board, matching resolveMix exactly', async () => {
    // Pool A: a1..a5. Pool B: a5, b1..b4. Overlap at a5. Union = 9 distinct
    // ids. removedTaskIds suppresses the overlapping a5; manualTaskIds adds
    // c1 (not in any pool) — mix size lands exactly at the 3×3 NONE-center
    // fillable floor (9).
    const poolATaskIds = ['a1', 'a2', 'a3', 'a4', 'a5'];
    const poolBTaskIds = ['a5', 'b1', 'b2', 'b3', 'b4'];
    for (const id of [...new Set([...poolATaskIds, ...poolBTaskIds, 'c1'])]) {
      await seedTask(id);
    }

    const poolA: Pool = {
      id: 'pool-a',
      userId: 'user-1',
      name: 'Pool A',
      taskIds: poolATaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    const poolB: Pool = {
      id: 'pool-b',
      userId: 'user-1',
      name: 'Pool B',
      taskIds: poolBTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.bulkAdd([poolA, poolB]);

    const template: RecurringBoardTemplate = {
      id: 'tmpl-mix',
      userId: 'user-1',
      name: 'Mix Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE, // 9 fillable cells, no auto center
      isRandomized: false,
      seedTaskIds: [], // never read post-P1 — deliberately left empty here
      poolIds: ['pool-a', 'pool-b'],
      manualTaskIds: ['c1'],
      removedTaskIds: ['a5'],
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    // Independent expectation computed directly via resolveMix (the same
    // pure function the spawn path calls internally).
    const tasksById: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) tasksById[t.id] = t;
    const expectedMix = resolveMix(template, { 'pool-a': poolA, 'pool-b': poolB }, tasksById);
    expect(new Set(expectedMix.taskIds)).toEqual(
      new Set(['a1', 'a2', 'a3', 'a4', 'b1', 'b2', 'b3', 'b4', 'c1']),
    );
    expect(expectedMix.taskIds).not.toContain('a5'); // removed, not manual-overridden

    const result = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Mix Board — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const boardTasks = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    expect(boardTasks).toHaveLength(9); // NONE center — all 9 cells filled
    expect(new Set(boardTasks.map((bt) => bt.taskId))).toEqual(new Set(expectedMix.taskIds));
  });

  it('a soft-deleted pool contributes nothing (derived detachment) — the mix falls below the fillable floor', async () => {
    const goneTaskIds = ['x1', 'x2', 'x3'];
    for (const id of goneTaskIds) await seedTask(id);
    const liveTaskIds = ['y1', 'y2'];
    for (const id of liveTaskIds) await seedTask(id);

    const deletedPool: Pool = {
      id: 'pool-gone',
      userId: 'user-1',
      name: 'Deleted Pool',
      taskIds: goneTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 2,
      isDeleted: true,
      deletedAt: NOW,
    };
    const livePool: Pool = {
      id: 'pool-live',
      userId: 'user-1',
      name: 'Live Pool',
      taskIds: liveTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.bulkAdd([deletedPool, livePool]);

    const template: RecurringBoardTemplate = {
      id: 'tmpl-detached',
      userId: 'user-1',
      name: 'Detached Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE, // 8 fillable
      isRandomized: false,
      seedTaskIds: [],
      // Deleted pool contributes NOTHING (derived detachment); only the
      // 2-task live pool's supply survives — 2 < the 8-cell floor.
      poolIds: ['pool-gone', 'pool-live'],
      manualTaskIds: [],
      removedTaskIds: [],
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    const result = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Detached Board — July 19',
    });

    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe('pool_too_small');
  });
});
