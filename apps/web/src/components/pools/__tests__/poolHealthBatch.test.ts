import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  resolveMix,
  type Board,
  type BoardSource,
  type BoardTask,
  type Pool,
  type PoolHealthResult,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../../../db/internal';
import { fetchTemplateSupplyResolution } from '../../../db/operations/boardSources';
import { computeRosterHealth } from '../../recurringTemplates/templateHealth';
import { computePoolHealthByPoolId, isPoolHealthResolved } from '../poolHealthBatch';

/**
 * poolHealthBatch.test.ts — Pools browse batching helper (P2 Task 2).
 *
 * Covers the perf-critical invariant this repo has been burned on twice:
 * pool-card health must come from ONE pass over already-loaded
 * pools/templates/tasks, never a per-card lookup. Since
 * `computePoolHealthByPoolId` takes plain arrays/records (no DB access),
 * these assertions exercise the batching + per-pool correctness together.
 *
 * 2026-09 audit T2 — the second block runs the REAL resolution the Pools
 * surfaces use (`fetchTemplateSupplyResolution` → `computeRosterHealth`,
 * i.e. what `useTemplateRosterHealth` returns) against fake-indexeddb, on
 * the two shapes the old `poolIds` + `resolveMix` read got wrong.
 */

function buildTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function buildPool(id: string, taskIds: string[], overrides: Partial<Pool> = {}): Pool {
  return {
    id,
    userId: 'u1',
    name: `Pool ${id}`,
    taskIds,
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function buildTemplate(
  id: string,
  overrides: Partial<RecurringBoardTemplate> = {},
): RecurringBoardTemplate {
  return {
    id,
    userId: 'u1',
    name: `Template ${id}`,
    timeframe: Timeframe.WEEKLY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    seedTaskIds: [],
    poolIds: [],
    manualTaskIds: [],
    removedTaskIds: [],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function poolSource(sourceId: string, overrides: Partial<BoardSource> = {}): BoardSource {
  return { sourceId, kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all', ...overrides };
}

function boardSource(sourceId: string, overrides: Partial<BoardSource> = {}): BoardSource {
  return { sourceId, kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all', ...overrides };
}

describe('computePoolHealthByPoolId', () => {
  it('returns one result per pool, keyed by id', () => {
    const t1 = buildTask('t1');
    const poolA = buildPool('pA', ['t1']);
    const poolB = buildPool('pB', []);

    const result = computePoolHealthByPoolId([poolA, poolB], [], {}, { t1 });

    expect(Object.keys(result).sort()).toEqual(['pA', 'pB']);
    expect(result.pA.taskCount).toBe(1);
    expect(result.pB.taskCount).toBe(0);
  });

  it('resolves each pool independently against a shared template list (no cross-talk)', () => {
    const tasks = Array.from({ length: 8 }, (_, i) => buildTask(`t${i}`));
    const tasksById = Object.fromEntries(tasks.map((t) => [t.id, t]));
    const poolA = buildPool('pA', tasks.map((t) => t.id));
    const poolB = buildPool('pB', ['t0']);
    const tplA = buildTemplate('tplA', { sources: [poolSource('pA')], name: 'Feeds A' });
    const tplB = buildTemplate('tplB', { sources: [poolSource('pB')], name: 'Feeds B' });

    // tplA can deal 8 (= the 3x3 FREE floor); tplB only 1.
    const achievable = { tplA: tasks.map((t) => t.id), tplB: ['t0'] };
    const result = computePoolHealthByPoolId([poolA, poolB], [tplA, tplB], achievable, tasksById);

    expect(result.pA.consumers).toEqual([]);
    expect(result.pB.consumers).toEqual([
      {
        templateId: 'tplB',
        templateName: 'Feeds B',
        timeframe: Timeframe.WEEKLY,
        boardSize: 3,
        shortBy: 7,
      },
    ]);
  });

  it('flags nothing while the achievable picks are still loading (undefined map)', () => {
    const pool = buildPool('pA', ['t0']);
    const tpl = buildTemplate('tpl', { sources: [poolSource('pA')] });
    const result = computePoolHealthByPoolId([pool], [tpl], undefined, { t0: buildTask('t0') });
    expect(result.pA).toEqual({ taskCount: 1, consumers: [] });
  });

  it('a pool with no consumers or no templates at all reports empty consumers', () => {
    const pool = buildPool('pA', []);
    expect(computePoolHealthByPoolId([pool], [], {}, {}).pA.consumers).toEqual([]);
  });

  it('returns {} for an empty pools list', () => {
    expect(computePoolHealthByPoolId([], [], {}, {})).toEqual({});
  });
});

// ─── DB-backed: the real sources resolution (2026-09 audit T2) ────────────────

const LOCAL_NOW = '2026-09-01T00:00:00.000';

function buildBoard(id: string): Board {
  return {
    id,
    userId: 'u1',
    name: `Board ${id}`,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.CUSTOM,
    startDate: LOCAL_NOW,
    endDate: '2099-12-31T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 8,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: LOCAL_NOW,
    updatedAt: LOCAL_NOW,
    version: 1,
    isDeleted: false,
  } as Board;
}

/** Seeds an ACTIVE one-off source board with `taskIds` placed row-major. */
async function seedSourceBoard(id: string, taskIds: string[]): Promise<void> {
  await db.tasks.bulkAdd(taskIds.map((t) => buildTask(t)));
  await db.boards.add(buildBoard(id));
  await db.boardTasks.bulkAdd(
    taskIds.map((taskId, i): BoardTask => ({
      id: `${id}-bt-${i}`,
      boardId: id,
      taskId,
      row: Math.floor(i / 3),
      col: i % 3,
      isCenter: false,
      createdAt: LOCAL_NOW,
      updatedAt: LOCAL_NOW,
      version: 1,
      isDeleted: false,
    })),
  );
}

/** Exactly what `PoolsBrowse` computes: the roster hook's resolution,
 *  then the batch. */
async function healthFromDb(
  pools: Pool[],
  templates: RecurringBoardTemplate[],
): Promise<Record<string, PoolHealthResult>> {
  const { byTemplateId, tasksById } = await fetchTemplateSupplyResolution(templates);
  const roster = computeRosterHealth(templates, byTemplateId, tasksById);
  const allTasks = Object.fromEntries((await db.tasks.toArray()).map((t) => [t.id, t]));
  return computePoolHealthByPoolId(pools, templates, roster.mixByTemplateId, allTasks);
}

afterEach(async () => {
  await db.tasks.clear();
  await db.pools.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
});

describe('computePoolHealthByPoolId — sources-native resolution (DB)', () => {
  it('pool + board source: the pool alone is short, pool + board is not → NOT flagged (was flagged)', async () => {
    const poolIds = ['p1', 'p2', 'p3'];
    await db.tasks.bulkAdd(poolIds.map((id) => buildTask(id)));
    const pool = buildPool('pool-1', poolIds);
    await db.pools.add(pool);
    await seedSourceBoard('board-1', ['b1', 'b2', 'b3', 'b4', 'b5']);
    // 3x3 FREE → floor 8. The dual-write mirror lists the pool only.
    const template = buildTemplate('tpl', {
      sources: [poolSource('pool-1'), boardSource('board-1')],
      poolIds: ['pool-1'],
    });

    // The OLD read (poolIds → resolveMix) saw the pool's 3 tasks alone:
    // short by 5, so the card said "Short on 1 board".
    const tasksById = Object.fromEntries((await db.tasks.toArray()).map((t) => [t.id, t]));
    expect(resolveMix(template, { 'pool-1': pool }, tasksById).taskIds).toHaveLength(3);

    const result = await healthFromDb([pool], [template]);
    expect(result['pool-1']).toEqual({ taskCount: 3, consumers: [] });
  });

  it('pool source capped by max below the floor → flagged with the right shortBy (was not)', async () => {
    const ids = Array.from({ length: 10 }, (_, i) => `p${i}`);
    await db.tasks.bulkAdd(ids.map((id) => buildTask(id)));
    const pool = buildPool('pool-1', ids);
    await db.pools.add(pool);
    const template = buildTemplate('tpl', {
      name: 'Capped',
      sources: [poolSource('pool-1', { max: 3 })],
      poolIds: ['pool-1'],
    });

    // The OLD read ignored the range: all 10 ≥ the 8-cell floor, no warning.
    const tasksById = Object.fromEntries((await db.tasks.toArray()).map((t) => [t.id, t]));
    expect(resolveMix(template, { 'pool-1': pool }, tasksById).taskIds).toHaveLength(10);

    const result = await healthFromDb([pool], [template]);
    expect(result['pool-1'].taskCount).toBe(10);
    expect(result['pool-1'].consumers).toEqual([
      {
        templateId: 'tpl',
        templateName: 'Capped',
        timeframe: Timeframe.WEEKLY,
        boardSize: 3,
        shortBy: 5, // floor 8 − the 3 the range lets the spawn deal
      },
    ]);
  });

  it('a board-only record with a stale poolIds mirror is not a consumer of that pool', async () => {
    await db.tasks.bulkAdd([buildTask('p1')]);
    const pool = buildPool('pool-1', ['p1']);
    await db.pools.add(pool);
    await seedSourceBoard('board-1', ['b1', 'b2']);
    // Short (2 < 8), but it no longer pulls pool-1 — only the mirror says so.
    const template = buildTemplate('tpl', {
      sources: [boardSource('board-1')],
      poolIds: ['pool-1'],
    });

    const result = await healthFromDb([pool], [template]);
    expect(result['pool-1'].consumers).toEqual([]);
  });
});

describe('isPoolHealthResolved (first paint is final paint)', () => {
  const tpl = buildTemplate('tpl', { sources: [poolSource('pA')] });

  it('is false while the templates query is loading', () => {
    expect(isPoolHealthResolved(undefined, {})).toBe(false);
  });

  it('is false while the roster map is loading', () => {
    expect(isPoolHealthResolved([tpl], undefined)).toBe(false);
  });

  it('is false for a stale map that lacks a template', () => {
    expect(isPoolHealthResolved([tpl], { other: [] })).toBe(false);
  });

  it('is true once every template has an entry (an empty pick counts)', () => {
    expect(isPoolHealthResolved([tpl], { tpl: [] })).toBe(true);
  });

  it('is true for a resolved empty roster', () => {
    expect(isPoolHealthResolved([], {})).toBe(true);
  });
});
