import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  TaskType,
  resolveMix,
  varyRange,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { spawnTemplateBoard } from '../recurringBoardSpawn';
import { legacyDerivedTaskId } from './legacyDerivedIds';

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

// Owner ruling 2026-09-24 — an ENDED board is never a source, judged
// against the wall clock. These fixtures live in July 2026, so the clock is
// pinned inside the spawned window (the spawn runs while its sources are open).
beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-07-19T12:00:00.000'));
});

afterEach(async () => {
  vi.useRealTimers();
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

    // Independent expectation via the legacy `resolveMix` formula — the
    // spawn itself goes through `sourcesForRecord` → `selectBoardTasks`, so
    // this pins that the sources path reproduces the legacy-trio mix.
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
    // A repeating board's instance never takes the core slot (owner bug 2026-10-13).
    const spawned = await db.boards.get(result.boardId);
    expect(spawned?.isCore).toBe(false);
    expect(spawned?.spawnedFromTemplateId).toBe(template.id);
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

describe('spawnTemplateBoard — achievements banned from source supply (owner decision 2026-09-10)', () => {
  it('a watcher in a pool AND on a pulled board never reaches the spawned board', async () => {
    // Pool: 5 normals + 1 achievement. Pulled board: 4 normals + 1
    // achievement placement. Eligible supply = 9 normals = exactly the
    // 3×3 NONE cell count, so the deal is deterministic: the board fills
    // completely and both watchers are excluded — proving the ban holds
    // at BOTH supply resolvers (`poolSourceSupplyById` and
    // `resolveBoardSourceSupply`), not just in the pickers.
    const poolNormals = ['pn1', 'pn2', 'pn3', 'pn4', 'pn5'];
    const boardNormals = ['bn1', 'bn2', 'bn3', 'bn4'];
    for (const id of [...poolNormals, ...boardNormals]) await seedTask(id);
    const watcher = (id: string): Task =>
      ({
        id,
        userId: 'user-1',
        title: id,
        type: TaskType.ACHIEVEMENT,
        referencedBoardId: 'some-other-board',
        isCompleted: false,
        totalCompletions: 0,
        totalInstances: 0,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      }) as Task;
    await db.tasks.bulkAdd([watcher('watch-pool'), watcher('watch-board')]);

    await db.pools.add({
      id: 'pool-ach',
      userId: 'user-1',
      name: 'Pool With Watcher',
      taskIds: [...poolNormals, 'watch-pool'],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });

    await db.boards.add({
      id: 'src-board-ach',
      userId: 'user-1',
      name: 'Source With Watcher',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: NOW,
      endDate: WINDOW_END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: true,
      totalTasks: 5,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });
    const placements = [...boardNormals, 'watch-board'].map((taskId, i) => ({
      id: `bt-src-${taskId}`,
      boardId: 'src-board-ach',
      taskId,
      row: Math.floor(i / 3),
      col: i % 3,
      isCenter: false,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }));
    await db.boardTasks.bulkAdd(placements);

    const template: RecurringBoardTemplate = {
      id: 'tmpl-no-watchers',
      userId: 'user-1',
      name: 'No Watchers Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE, // 9 cells
      isRandomized: false,
      seedTaskIds: [],
      manualTaskIds: [],
      sources: [
        { sourceId: 'pool-ach', kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all' },
        { sourceId: 'src-board-ach', kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all' },
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
      suggestedName: 'No Watchers — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const boardTasks = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    const placed = new Set(
      boardTasks.filter((bt) => bt.boardId === result.boardId).map((bt) => bt.taskId),
    );
    expect(placed.has('watch-pool')).toBe(false);
    expect(placed.has('watch-board')).toBe(false);
    expect(placed).toEqual(new Set([...poolNormals, ...boardNormals]));
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

describe('spawnTemplateBoard — counter-family exclusivity (2026-09-08)', () => {
  it('places at most ONE member of a shared-counter family per spawned board', async () => {
    // A counting root + its derived version share a family; both sit in
    // the pool alongside 8 fillers so the 3×3 NONE board (9 cells) has to
    // choose — exactly one family member may land.
    const root: Task = {
      id: 'counter-root',
      userId: 'user-1',
      title: 'Read 50 pages',
      type: TaskType.COUNTING,
      action: 'Read',
      unit: 'pages',
      maxCount: 50,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    const derived: Task = {
      ...root,
      id: 'counter-derived',
      title: 'Read 20 pages',
      maxCount: 20,
      sharedCounterId: 'counter-root',
    };
    await db.tasks.bulkAdd([root, derived]);
    const fillerIds: string[] = [];
    for (let i = 0; i < 8; i += 1) {
      const id = `fam-filler-${i}`;
      fillerIds.push(id);
      await seedTask(id);
    }

    const pool: Pool = {
      id: 'pool-fam',
      userId: 'user-1',
      name: 'Family Pool',
      taskIds: ['counter-root', 'counter-derived', ...fillerIds],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.add(pool);

    const template: RecurringBoardTemplate = {
      id: 'tmpl-fam',
      userId: 'user-1',
      name: 'Family Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: true,
      seedTaskIds: [],
      poolIds: ['pool-fam'],
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
      suggestedName: 'Family Board — today',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const placements = await db.boardTasks
      .where('boardId')
      .equals(result.boardId)
      .toArray();
    expect(placements).toHaveLength(9);
    const famPlaced = placements.filter(
      (bt) => bt.taskId === 'counter-root' || bt.taskId === 'counter-derived',
    );
    expect(famPlaced).toHaveLength(1);
  });

  it('a hand-added family member wins over the pool-supplied mate at spawn', async () => {
    const root: Task = {
      id: 'win-root',
      userId: 'user-1',
      title: 'Walk 10 km',
      type: TaskType.COUNTING,
      action: 'Walk',
      unit: 'km',
      maxCount: 10,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    const derived: Task = {
      ...root,
      id: 'win-derived',
      title: 'Walk 4 km',
      maxCount: 4,
      sharedCounterId: 'win-root',
    };
    await db.tasks.bulkAdd([root, derived]);
    const fillerIds: string[] = [];
    for (let i = 0; i < 8; i += 1) {
      const id = `win-filler-${i}`;
      fillerIds.push(id);
      await seedTask(id);
    }
    await db.pools.add({
      id: 'pool-win',
      userId: 'user-1',
      name: 'Win Pool',
      taskIds: ['win-root', ...fillerIds],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });
    const template: RecurringBoardTemplate = {
      id: 'tmpl-win',
      userId: 'user-1',
      name: 'Win Board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: true,
      seedTaskIds: [],
      poolIds: ['pool-win'],
      manualTaskIds: ['win-derived'],
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
      suggestedName: 'Win Board — today',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const placements = await db.boardTasks
      .where('boardId')
      .equals(result.boardId)
      .toArray();
    const placedIds = new Set(placements.map((bt) => bt.taskId));
    // The hand-added family member wins the family slot and is placed as
    // ITSELF (slice 3b: nothing is minted; the kernel reads a linked square
    // over the host board's window). The pool-supplied root never lands.
    expect(placedIds.has('win-derived')).toBe(true);
    expect(placedIds.has('win-root')).toBe(false);
    expect(await db.tasks.get(legacyDerivedTaskId(result.boardId, 'win-root'))).toBeUndefined();
    const placed = placements.find((bt) => bt.taskId === 'win-derived');
    expect(placed?.targetOverride).toBeUndefined(); // its own goal (4) stands
  });
});

describe('spawnTemplateBoard — member-rule placement parameters (slice 3b)', () => {
  const ROOT = 'root-counter';
  const SRC = 'src-weekly-board';
  const PRE_WINDOW = '2026-07-10T00:00:00.000Z';

  async function seedWeeklySourceBoard(): Promise<void> {
    // A weekly board carrying a 35-unit counting goal plus 7 fillers, so a
    // 3×3 FREE-centre daily board (8 fillable cells) is exactly filled.
    const root: Task = {
      id: ROOT,
      userId: 'user-1',
      title: 'Run 35 km',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 35,
      currentCount: 9,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as Task;
    await db.tasks.add(root);
    await db.taskEvents.add({
      id: 'ev-pre',
      userId: 'user-1',
      taskId: ROOT,
      kind: 'increment',
      delta: 9,
      occurredAt: PRE_WINDOW,
      createdAt: PRE_WINDOW,
      updatedAt: PRE_WINDOW,
      version: 1,
      isDeleted: false,
    });
    const fillers = ['f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7'];
    for (const id of fillers) await seedTask(id);

    await db.boards.add({
      id: SRC,
      userId: 'user-1',
      name: 'Weekly source',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.WEEKLY,
      startDate: '2026-07-13T00:00:00.000',
      endDate: '2026-07-19T23:59:59.999',
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });
    await db.boardTasks.bulkAdd(
      [ROOT, ...fillers].map((taskId, i) => ({
        id: `bt-${SRC}-${taskId}`,
        boardId: SRC,
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
  }

  const dailyTemplate = (): RecurringBoardTemplate => ({
    id: 'tmpl-member-rules',
    userId: 'user-1',
    name: 'Daily from weekly',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE, // 8 fillable cells
    isRandomized: false,
    seedTaskIds: [],
    manualTaskIds: [],
    sources: [
      {
        sourceId: SRC,
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

  it('pro-rates the weekly 35 goal onto a daily board (5) as the placement override — no row is minted', async () => {
    await seedWeeklySourceBoard();
    const template = dailyTemplate();
    await db.recurringBoardTemplates.add(template);
    const taskCount = await db.tasks.count();

    const result = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Daily — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    expect(await db.tasks.count()).toBe(taskCount);
    expect(await db.tasks.get(legacyDerivedTaskId(result.boardId, ROOT))).toBeUndefined();

    const placed = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    expect(placed).toHaveLength(8);
    // The root itself lands, carrying ceil(35 × 1 day / 7 days) = 5.
    const rootRow = placed.find((bt) => bt.taskId === ROOT);
    expect(rootRow).toMatchObject({ targetOverride: 5, targetKind: 'discrete' });
    // The root keeps its own goal; its lifetime cache is not touched.
    expect((await db.tasks.get(ROOT))?.maxCount).toBe(35);
  });

  it('a second window carries its own parameters; the first board\'s placement is never rewritten', async () => {
    await seedWeeklySourceBoard();
    const template = dailyTemplate();
    await db.recurringBoardTemplates.add(template);

    const first = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Daily — July 19',
    });
    expect(first.ok).toBe(true);
    if (!first.ok) return;
    const firstRow = (await db.boardTasks.where('boardId').equals(first.boardId).toArray()).find(
      (bt) => bt.taskId === ROOT,
    );

    const second = await spawnTemplateBoard({
      template: { ...template, lastSpawnedWindowKey: WINDOW_START },
      windowStart: '2026-07-20T00:00:00.000Z',
      windowEnd: '2026-07-20T23:59:59.999Z',
      suggestedName: 'Daily — July 20',
    });
    expect(second.ok).toBe(true);
    if (!second.ok) return;

    const secondRow = (await db.boardTasks.where('boardId').equals(second.boardId).toArray()).find(
      (bt) => bt.taskId === ROOT,
    );
    expect(secondRow?.id).not.toBe(firstRow?.id);
    expect(secondRow).toMatchObject({ targetOverride: 5 });
    const firstAfter = await db.boardTasks.get(firstRow!.id);
    expect(firstAfter?.version).toBe(firstRow?.version);
    expect(firstAfter?.updatedAt).toBe(firstRow?.updatedAt);
    // No task row was ever created for either window.
    expect(await db.tasks.where('sharedCounterId').equals(ROOT).count()).toBe(0);
  });

  it('manualTaskTargets: a frozen override lands on the HAND-ADDED member and wins over the planner; a sourced member re-plans', async () => {
    await seedWeeklySourceBoard();
    // A second counter hand-added with a frozen override of 9 (own goal 20).
    await db.tasks.add({
      id: 'hand', userId: 'user-1', title: 'Read 20 pages', type: TaskType.COUNTING, action: 'Read', unit: 'pages',
      maxCount: 20, currentCount: 0, isCompleted: false, totalCompletions: 0, totalInstances: 0,
      createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    } as Task);
    const template: RecurringBoardTemplate = {
      ...dailyTemplate(),
      id: 'tmpl-frozen',
      manualTaskIds: ['hand'],
      sources: dailyTemplate().sources!.map((src) => ({ ...src, max: 7 })),
      // An entry for a SOURCED member is ignored: sourced members re-plan.
      manualTaskTargets: {
        hand: { target: 9, kind: 'discrete', title: 'Nine pages' },
        [ROOT]: { target: 99, kind: 'discrete' },
      },
    };
    await db.recurringBoardTemplates.add(template);

    const result = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Daily — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const placed = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    expect(placed.find((bt) => bt.taskId === 'hand')).toMatchObject({
      targetOverride: 9,
      targetKind: 'discrete',
      titleOverride: 'Nine pages',
    });
    expect(placed.find((bt) => bt.taskId === ROOT)).toMatchObject({ targetOverride: 5 });
  });
});

/**
 * Board Sources §Member rules — spec step 1 at the spawn path: Split-up
 * expansion happens BEFORE validation and selection, so a `split: true`
 * compound contributes its parts as selectable squares and never itself.
 */
describe('spawnTemplateBoard — Split up expands the selectable supply', () => {
  const SRC = 'src-split-board';
  const COMPOUND = 'compound-split';
  const PART_A = 'part-a';
  const PART_B = 'part-b';

  it('places the compound’s parts as separate squares, never the compound', async () => {
    // 6 fillers + the compound's 2 parts = exactly the 8 fillable cells of a
    // 3×3 FREE-centre board, so the fill is forced and the assertion is not
    // a lucky draw.
    const fillers = ['sf1', 'sf2', 'sf3', 'sf4', 'sf5', 'sf6'];
    for (const id of [...fillers, PART_A, PART_B]) await seedTask(id);
    await db.tasks.add({
      id: COMPOUND,
      userId: 'user-1',
      title: 'Morning set',
      type: TaskType.COMPOUND,
      operator: 'AND',
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await db.compoundChildren.bulkAdd([
      {
        id: 'cc-a',
        compoundTaskId: COMPOUND,
        childTaskId: PART_A,
        childIndex: 0,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      },
      {
        id: 'cc-b',
        compoundTaskId: COMPOUND,
        childTaskId: PART_B,
        childIndex: 1,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      },
    ]);

    await db.boards.add({
      id: SRC,
      userId: 'user-1',
      name: 'Split source',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: NOW,
      endDate: WINDOW_END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });
    await db.boardTasks.bulkAdd(
      [COMPOUND, ...fillers].map((taskId, i) => ({
        id: `bt-${SRC}-${taskId}`,
        boardId: SRC,
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

    const template: RecurringBoardTemplate = {
      id: 'tmpl-split',
      userId: 'user-1',
      name: 'Split board',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE, // 8 fillable cells
      isRandomized: false,
      seedTaskIds: [],
      manualTaskIds: [],
      sources: [
        {
          sourceId: SRC,
          kind: 'board',
          min: 0,
          max: null,
          excludedTaskIds: [],
          filter: 'all',
          memberRules: { [COMPOUND]: { split: true } },
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
      suggestedName: 'Split — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    const placed = (await db.boardTasks.where('boardId').equals(result.boardId).toArray()).map(
      (bt) => bt.taskId,
    );
    expect(placed).toHaveLength(8);
    expect(new Set(placed)).toEqual(new Set([...fillers, PART_A, PART_B]));
    expect(placed).not.toContain(COMPOUND);
  });
});

/**
 * Pool-level default dice (2026-10-06, docs/BOARD_SOURCES.md §Member rules →
 * Pool-level defaults): a pool source's member whose stored rule carries no
 * `vary` inherits the POOL's default at spawn time (`withEffectiveMemberRules`
 * in the supply builder), so a repeating board authored before the pool
 * gained a default — or a member added to the pool later — varies at its
 * next window without a template write. A stored source `vary` always wins.
 */
describe('spawnTemplateBoard — pool-level default dice (2026-10-06)', () => {
  const ROOT = 'pool-root-counter';
  const POOL = 'pool-with-dice';
  const GOAL = 10;
  const FILLERS = ['pf1', 'pf2', 'pf3', 'pf4', 'pf5', 'pf6', 'pf7'];

  async function seedPool(memberVary: Pool['memberVary']): Promise<void> {
    await db.tasks.add({
      id: ROOT,
      userId: 'user-1',
      title: 'Do 10 reps',
      type: TaskType.COUNTING,
      action: 'Do',
      unit: 'reps',
      maxCount: GOAL,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as Task);
    for (const id of FILLERS) await seedTask(id);
    const pool: Pool = {
      id: POOL,
      userId: 'user-1',
      name: 'Dice pool',
      taskIds: [ROOT, ...FILLERS],
      ...(memberVary ? { memberVary } : {}),
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    };
    await db.pools.add(pool);
  }

  const poolTemplate = (memberRules?: Record<string, { vary: 0 | 1 | 2 }>): RecurringBoardTemplate => ({
    id: 'tmpl-pool-dice',
    userId: 'user-1',
    name: 'Daily from pool',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE, // 8 fillable cells = the pool's 8 members
    isRandomized: false,
    seedTaskIds: [],
    manualTaskIds: [],
    sources: [
      {
        sourceId: POOL,
        kind: 'pool',
        min: 0,
        max: null,
        excludedTaskIds: [],
        filter: 'all',
        ...(memberRules ? { memberRules } : {}),
      },
    ],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  });

  async function spawnOnce(template: RecurringBoardTemplate): Promise<string> {
    await db.recurringBoardTemplates.add(template);
    const result = await spawnTemplateBoard({
      template,
      windowStart: WINDOW_START,
      windowEnd: WINDOW_END,
      suggestedName: 'Daily — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error('spawn failed');
    return result.boardId;
  }

  async function placedIds(boardId: string): Promise<string[]> {
    return (await db.boardTasks.where('boardId').equals(boardId).toArray()).map((bt) => bt.taskId);
  }

  it('a member with no stored rule inherits the pool default: the spawned placement is ROLLED inside varyRange', async () => {
    await seedPool({ [ROOT]: 2 });
    const boardId = await spawnOnce(poolTemplate());

    const [lo, hi] = varyRange(GOAL, 2, GOAL);
    expect(lo).toBeLessThan(hi); // the range is real, not collapsed
    expect(await db.tasks.get(legacyDerivedTaskId(boardId, ROOT))).toBeUndefined();
    const row = (await db.boardTasks.where('boardId').equals(boardId).toArray()).find((bt) => bt.taskId === ROOT);
    expect(row).toBeDefined();
    // A roll that lands on the task's own goal stores no override (it would be redundant).
    const target = row?.targetOverride ?? GOAL;
    expect(target).toBeGreaterThanOrEqual(lo);
    expect(target).toBeLessThanOrEqual(hi);
  });

  it('a stored source vary wins over the pool default (seeded platform rng pins the level)', async () => {
    // The spawn path has no rng seam, so the platform rng is pinned at 0:
    // `varyRange(10, 1, 10)` bottoms at 8 while the pool's level 2 bottoms
    // at 5 — only the stored level-1 rule can produce 8.
    const random = vi.spyOn(Math, 'random').mockReturnValue(0);
    try {
      await seedPool({ [ROOT]: 2 });
      const boardId = await spawnOnce(poolTemplate({ [ROOT]: { vary: 1 } }));

      const [loOverride] = varyRange(GOAL, 1, GOAL);
      const [loDefault] = varyRange(GOAL, 2, GOAL);
      expect(loOverride).not.toBe(loDefault); // the assertion discriminates
      const row = (await db.boardTasks.where('boardId').equals(boardId).toArray()).find((bt) => bt.taskId === ROOT);
      expect(row).toMatchObject({ targetOverride: loOverride });
    } finally {
      random.mockRestore();
    }
  });

  it('control: without a pool default the member is placed as-is and nothing is minted', async () => {
    await seedPool(undefined);
    const boardId = await spawnOnce(poolTemplate());

    expect(await db.tasks.get(legacyDerivedTaskId(boardId, ROOT))).toBeUndefined();
    expect(await placedIds(boardId)).toContain(ROOT);
  });
});

describe('spawnTemplateBoard — slice 3a (a board member\'s goal is the supplying placement\'s)', () => {
  it('pulls a root placed at targetOverride 70 on a weekly board into a daily spawn at ceil(70/7) = 10', async () => {
    const poolTaskIds = ['f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7'];
    for (const id of poolTaskIds) await seedTask(id);
    await db.pools.add({
      id: 'pool-1', userId: 'user-1', name: 'Pool', taskIds: poolTaskIds,
      createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    });
    await db.tasks.add({
      id: 'r1', userId: 'user-1', title: 'Run 35 km', type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 35,
      isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    });
    await db.boards.add({
      id: 'weekly-src', userId: 'user-1', name: 'Weekly', status: BoardStatus.ACTIVE, boardSize: 3,
      timeframe: Timeframe.WEEKLY, startDate: '2026-07-13T00:00:00.000', endDate: '2026-07-19T23:59:59.999',
      centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9, completedTasks: 0,
      linesCompleted: 0, completedLineIds: [], createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    });
    await db.boardTasks.add({
      id: 'bt-r1', boardId: 'weekly-src', taskId: 'r1', row: 0, col: 0, isCenter: false,
      targetOverride: 70, targetKind: 'discrete', createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    });
    const template: RecurringBoardTemplate = {
      id: 'tmpl-3a', userId: 'user-1', name: 'Daily', timeframe: Timeframe.DAILY, boardSize: 3,
      centerSquareType: CenterSquareType.FREE, isRandomized: false, seedTaskIds: [], manualTaskIds: [],
      sources: [
        { sourceId: 'weekly-src', kind: 'board', min: 1, max: null, excludedTaskIds: [], filter: 'all' },
        { sourceId: 'pool-1', kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all' },
      ],
      lastSpawnedWindowKey: null, isActive: true, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    const result = await spawnTemplateBoard({
      template, windowStart: WINDOW_START, windowEnd: WINDOW_END, suggestedName: 'Daily — July 19',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const row = (await db.boardTasks.where('boardId').equals(result.boardId).toArray()).find((bt) => bt.taskId === 'r1');
    expect(row).toMatchObject({ targetOverride: 10, targetKind: 'discrete' });
    expect(await db.tasks.get(legacyDerivedTaskId(result.boardId, 'r1'))).toBeUndefined();
  });
});
