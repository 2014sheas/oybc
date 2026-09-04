import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
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

describe('spawnTemplateBoard — Board Sources P1 (stamped sources)', () => {
  it('honors a sources-stamped record: numeric max caps a pool, mins/all fill the rest', async () => {
    // Pool A: 5 tasks capped at max 2. Pool B: 5 tasks at [0, all].
    // Manual: 2 tasks outside both pools. 3×3 NONE = 9 cells; feasible
    // only with exactly 2 from A + all 5 from B + both manual.
    const poolATaskIds = ['a1', 'a2', 'a3', 'a4', 'a5'];
    const poolBTaskIds = ['b1', 'b2', 'b3', 'b4', 'b5'];
    for (const id of [...poolATaskIds, ...poolBTaskIds, 'm1', 'm2']) {
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
      id: 'tmpl-sources',
      userId: 'user-1',
      name: 'Sources Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      seedTaskIds: [],
      // Legacy trio deliberately ABSENT — the stamped `sources` array is
      // authoritative and the spawn path must read it, not the trio.
      manualTaskIds: ['m1', 'm2'],
      sources: [
        {
          sourceId: 'pool-a',
          kind: 'pool',
          min: 0,
          max: 2,
          excludedTaskIds: [],
          filter: 'all',
        },
        {
          sourceId: 'pool-b',
          kind: 'pool',
          min: 0,
          max: null,
          excludedTaskIds: [],
          filter: 'all',
        },
      ],
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
      suggestedName: 'Sources Board — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const boardTasks = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    expect(boardTasks).toHaveLength(9);
    const placed = new Set(boardTasks.map((bt) => bt.taskId));
    expect(placed.size).toBe(9);
    const fromA = poolATaskIds.filter((id) => placed.has(id)).length;
    expect(fromA).toBe(2); // the numeric max, exactly (9 cells force it)
    for (const id of [...poolBTaskIds, 'm1', 'm2']) expect(placed.has(id)).toBe(true);
  });

  it('a LIVE board source with everything excluded contributes nothing and never blocks (empty-source rule)', async () => {
    const poolTaskIds = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8'];
    for (const id of poolTaskIds) await seedTask(id);
    const pool: Pool = {
      id: 'pool-1',
      userId: 'user-1',
      name: 'Pool',
      taskIds: poolTaskIds,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.add(pool);

    await seedTask('x1');
    await db.boards.add({
      id: 'live-src-board',
      userId: 'user-1',
      name: 'Live Source',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: NOW,
      endDate: WINDOW_END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: true,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });
    await db.boardTasks.add({
      id: 'bt-live-x1',
      boardId: 'live-src-board',
      taskId: 'x1',
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });

    const template: RecurringBoardTemplate = {
      id: 'tmpl-board-src',
      userId: 'user-1',
      name: 'Board Source Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE, // 8 fillable
      isRandomized: false,
      seedTaskIds: [],
      manualTaskIds: [],
      sources: [
        {
          sourceId: 'pool-1',
          kind: 'pool',
          min: 0,
          max: null,
          excludedTaskIds: [],
          filter: 'all',
        },
        {
          // A LIVE board whose entire supply is excluded — the design's
          // "source with nothing left" case: contributes nothing, never
          // blocks. (A MISSING/deleted/archived board now blocks with
          // the P3 ask instead — covered below.)
          sourceId: 'live-src-board',
          kind: 'board',
          min: 0,
          max: null,
          excludedTaskIds: ['x1'],
          filter: 'all',
        },
      ],
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
      suggestedName: 'Board Source — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const boardTasks = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    expect(boardTasks).toHaveLength(8);
    expect(new Set(boardTasks.map((bt) => bt.taskId))).toEqual(new Set(poolTaskIds));
  });
});

describe('spawnTemplateBoard — isRandomized: false determinism (review-caught regression lock)', () => {
  it('an overfilled non-randomized template keeps its stable first-N subset AND order across spawns', async () => {
    // 12-task pool on a 3×3 NONE board (9 cells). Pre-sources behavior:
    // placeBoard received the deterministic resolveMix order verbatim and
    // truncated — same first-9 subset, same cell order, every spawn.
    const ids = Array.from({ length: 12 }, (_, i) => `t${String(i).padStart(2, '0')}`);
    for (const id of ids) await seedTask(id);
    await db.pools.add({
      id: 'big-pool',
      userId: 'user-1',
      name: 'Big Pool',
      taskIds: ids,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });

    const template: RecurringBoardTemplate = {
      id: 'tmpl-det',
      userId: 'user-1',
      name: 'Deterministic Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      seedTaskIds: [],
      poolIds: ['big-pool'],
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

    const spawnOnce = async (windowStart: string, windowEnd: string) => {
      const result = await spawnTemplateBoard({
        template: (await db.recurringBoardTemplates.get('tmpl-det'))!,
        windowStart,
        windowEnd,
        suggestedName: `Deterministic — ${windowStart.slice(0, 10)}`,
      });
      expect(result.ok).toBe(true);
      if (!result.ok) throw new Error('spawn failed');
      const rows = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
      return rows
        .sort((a, b) => a.row - b.row || a.col - b.col)
        .map((bt) => bt.taskId);
    };

    const first = await spawnOnce(WINDOW_START, WINDOW_END);
    const second = await spawnOnce('2026-07-20T00:00:00.000Z', '2026-07-20T23:59:59.999Z');

    // Deterministic first-9 slice in pool order, identical layout both spawns.
    expect(first).toEqual(ids.slice(0, 9));
    expect(second).toEqual(first);
  });
});

describe('spawnTemplateBoard — Board Sources P3 (deleted-source ask trigger)', () => {
  const seedSourceBoard = async (
    boardId: string,
    taskIds: string[],
    opts: { status?: BoardStatus; isDeleted?: boolean } = {},
  ) => {
    await db.boards.add({
      id: boardId,
      userId: 'user-1',
      name: `Source ${boardId}`,
      status: opts.status ?? BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: NOW,
      endDate: WINDOW_END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: true,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: opts.isDeleted ?? false,
    });
    await db.boardTasks.bulkAdd(
      taskIds.map((taskId, i) => ({
        id: `bt-${boardId}-${taskId}`,
        boardId,
        taskId,
        row: Math.floor(i / 3),
        col: i % 3,
        isCenter: false,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      })),
    );
  };

  const askTemplate = (manualTaskIds: string[]): RecurringBoardTemplate => ({
    id: 'tmpl-ask',
    userId: 'user-1',
    name: 'Ask Board',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: true,
    seedTaskIds: [],
    manualTaskIds,
    sources: [
      {
        sourceId: 'b-gone',
        kind: 'board',
        min: 0,
        max: null,
        excludedTaskIds: [],
        filter: 'all',
      },
    ],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  });

  it.each([
    ['soft-deleted', { isDeleted: true }],
    ['archived', { status: BoardStatus.ARCHIVED }],
  ] as const)(
    'a %s source board skips the window with source_board_missing',
    async (_label, opts) => {
      const manual = Array.from({ length: 9 }, (_, i) => `m${i}`);
      for (const id of manual) await seedTask(id);
      await seedSourceBoard('b-gone', ['m0'], opts);
      const template = askTemplate(manual);
      await db.recurringBoardTemplates.add(template);

      const result = await spawnTemplateBoard({
        template,
        windowStart: WINDOW_START,
        windowEnd: WINDOW_END,
        suggestedName: 'Ask Board — July 19',
      });
      expect(result).toEqual({
        ok: false,
        templateId: 'tmpl-ask',
        reason: 'source_board_missing',
      });
      // Nothing was written — the window waits for the user's answer
      // (the only board is the seeded source board itself).
      expect((await db.boards.toArray()).map((b) => b.id)).toEqual(['b-gone']);
    },
  );

  it('a missing source-board row also triggers the ask', async () => {
    const manual = Array.from({ length: 9 }, (_, i) => `m${i}`);
    for (const id of manual) await seedTask(id);
    const template = askTemplate(manual);
    await db.recurringBoardTemplates.add(template);

    const result = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Ask Board — July 19',
    });
    expect(result).toEqual({
      ok: false,
      templateId: 'tmpl-ask',
      reason: 'source_board_missing',
    });
  });
});
