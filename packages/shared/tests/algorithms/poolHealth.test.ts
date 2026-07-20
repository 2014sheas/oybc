import {
  computePoolHealth,
  formatPoolShortSummary,
} from '../../src/algorithms/poolHealth';
import { TaskType, Timeframe, CenterSquareType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';
import type { Pool } from '../../src/types/pool';
import type { RecurringBoardTemplate } from '../../src/types/recurringBoardTemplate';

/**
 * poolHealth.test.ts — Task Pools + Recurring Boards Rework (P2)
 *
 * Covers the named cases from the P2 Task 1 brief: consumer detection
 * (active-only; deleted templates skipped), shortBy math across sizes/
 * centers, the exact warning-string format, a pool consumed by multiple
 * templates, and a healthy pool (no consumers).
 */

// ─── Fixtures ─────────────────────────────────────────────────────────────────

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

function byId<T extends { id: string }>(items: T[]): Record<string, T> {
  const out: Record<string, T> = {};
  for (const item of items) out[item.id] = item;
  return out;
}

// ─── computePoolHealth: taskCount ──────────────────────────────────────────────

describe('computePoolHealth — taskCount', () => {
  it('counts resolvable non-deleted taskIds, skipping deleted/missing tasks', () => {
    const t1 = buildTask('t1');
    const t2 = buildTask('t2', { isDeleted: true });
    const pool = buildPool('p1', ['t1', 't2', 't3']); // t3 missing from tasksById
    const tasksById = byId([t1, t2]);

    const result = computePoolHealth(pool, {
      templates: [],
      poolsById: byId([pool]),
      tasksById,
    });

    expect(result.taskCount).toBe(1);
    expect(result.consumers).toEqual([]);
  });
});

// ─── computePoolHealth: consumer detection ─────────────────────────────────────

describe('computePoolHealth — consumer detection', () => {
  const t1 = buildTask('t1');
  const t2 = buildTask('t2');
  const pool = buildPool('p1', ['t1', 't2']);
  const tasksById = byId([t1, t2]);
  const poolsById = byId([pool]);

  it('includes an active template short on this pool as a consumer', () => {
    // 3x3 FREE floor is 8; mix supplies only 2 -> shortBy 6.
    const template = buildTemplate('tpl1', { poolIds: ['p1'] });

    const result = computePoolHealth(pool, {
      templates: [template],
      poolsById,
      tasksById,
    });

    expect(result.consumers).toEqual([
      {
        templateId: 'tpl1',
        templateName: 'Template tpl1',
        timeframe: Timeframe.WEEKLY,
        boardSize: 3,
        shortBy: 6,
      },
    ]);
  });

  it('skips a soft-deleted template even if it references the pool', () => {
    const template = buildTemplate('tpl1', { poolIds: ['p1'], isDeleted: true });

    const result = computePoolHealth(pool, {
      templates: [template],
      poolsById,
      tasksById,
    });

    expect(result.consumers).toEqual([]);
  });

  it('skips a paused (isActive: false) template', () => {
    const template = buildTemplate('tpl1', { poolIds: ['p1'], isActive: false });

    const result = computePoolHealth(pool, {
      templates: [template],
      poolsById,
      tasksById,
    });

    expect(result.consumers).toEqual([]);
  });

  it('skips a template that does not reference this pool', () => {
    const template = buildTemplate('tpl1', { poolIds: ['other-pool'] });

    const result = computePoolHealth(pool, {
      templates: [template],
      poolsById,
      tasksById,
    });

    expect(result.consumers).toEqual([]);
  });
});

// ─── computePoolHealth: shortBy math across sizes/centers ──────────────────────

describe('computePoolHealth — shortBy math across sizes/centers', () => {
  const t1 = buildTask('t1');
  const t2 = buildTask('t2');
  const pool = buildPool('p1', ['t1', 't2']); // supplies 2 resolvable tasks
  const tasksById = byId([t1, t2]);
  const poolsById = byId([pool]);

  it('3x3 FREE center: floor 8, mix 2 -> shortBy 6', () => {
    const template = buildTemplate('tpl1', {
      poolIds: ['p1'],
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
    });

    const result = computePoolHealth(pool, { templates: [template], poolsById, tasksById });

    expect(result.consumers[0].shortBy).toBe(6);
  });

  it('3x3 NONE center: floor 9, mix 2 -> shortBy 7', () => {
    const template = buildTemplate('tpl1', {
      poolIds: ['p1'],
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
    });

    const result = computePoolHealth(pool, { templates: [template], poolsById, tasksById });

    expect(result.consumers[0].shortBy).toBe(7);
  });

  it('4x4: floor 16, mix 2 -> shortBy 14, and threads the consuming template\'s boardSize', () => {
    const template = buildTemplate('tpl1', {
      poolIds: ['p1'],
      boardSize: 4,
      centerSquareType: CenterSquareType.FREE,
    });

    const result = computePoolHealth(pool, { templates: [template], poolsById, tasksById });

    expect(result.consumers[0].shortBy).toBe(14);
    // P2 Task 2 review: boardSize is carried on the consumer itself for any
    // per-template rendering, even though the combined card summary line
    // (`formatPoolShortSummary`) only counts consumers.
    expect(result.consumers[0].boardSize).toBe(4);
  });

  it('a template with enough mix to fill is NOT a consumer (shortBy 0 excluded)', () => {
    const wideTasks = Array.from({ length: 8 }, (_, i) => buildTask(`w${i}`));
    const widePool = buildPool('p2', wideTasks.map((task) => task.id));
    const template = buildTemplate('tpl1', {
      poolIds: ['p2'],
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
    });

    const result = computePoolHealth(widePool, {
      templates: [template],
      poolsById: byId([widePool]),
      tasksById: byId(wideTasks),
    });

    expect(result.consumers).toEqual([]);
  });
});

// ─── computePoolHealth: multiple consumers ─────────────────────────────────────

describe('computePoolHealth — pool consumed by multiple templates', () => {
  it('returns a consumer entry per short template that pulls the pool', () => {
    const t1 = buildTask('t1');
    const pool = buildPool('p1', ['t1']);
    const tasksById = byId([t1]);
    const poolsById = byId([pool]);
    const tplA = buildTemplate('tplA', {
      name: 'Morning Kickstart',
      poolIds: ['p1'],
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
    });
    const tplB = buildTemplate('tplB', {
      name: 'Weekly Reset',
      poolIds: ['p1'],
      timeframe: Timeframe.WEEKLY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
    });

    const result = computePoolHealth(pool, {
      templates: [tplA, tplB],
      poolsById,
      tasksById,
    });

    expect(result.consumers).toEqual([
      {
        templateId: 'tplA',
        templateName: 'Morning Kickstart',
        timeframe: Timeframe.DAILY,
        boardSize: 3,
        shortBy: 7,
      },
      {
        templateId: 'tplB',
        templateName: 'Weekly Reset',
        timeframe: Timeframe.WEEKLY,
        boardSize: 3,
        shortBy: 8,
      },
    ]);
  });
});

// ─── computePoolHealth: healthy pool ───────────────────────────────────────────

describe('computePoolHealth — healthy pool (no consumers)', () => {
  it('returns empty consumers when no template references the pool', () => {
    const t1 = buildTask('t1');
    const pool = buildPool('p1', ['t1']);

    const result = computePoolHealth(pool, {
      templates: [],
      poolsById: byId([pool]),
      tasksById: byId([t1]),
    });

    expect(result.consumers).toEqual([]);
  });
});

// ─── formatPoolShortSummary ─────────────────────────────────────────────────────

describe('formatPoolShortSummary', () => {
  it('returns the empty string for zero consumers (render nothing)', () => {
    expect(formatPoolShortSummary([])).toBe('');
  });

  it('returns "Short on 1 board" for exactly one consumer', () => {
    const consumer = {
      templateId: 'tpl1',
      templateName: 'Template tpl1',
      timeframe: Timeframe.WEEKLY,
      boardSize: 3,
      shortBy: 6,
    };
    expect(formatPoolShortSummary([consumer])).toBe('Short on 1 board');
  });

  it('returns "Short on {N} boards" for two or more consumers', () => {
    const consumerA = {
      templateId: 'tplA',
      templateName: 'Morning Kickstart',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      shortBy: 7,
    };
    const consumerB = {
      templateId: 'tplB',
      templateName: 'Weekly Reset',
      timeframe: Timeframe.WEEKLY,
      boardSize: 3,
      shortBy: 8,
    };
    const consumerC = {
      templateId: 'tplC',
      templateName: 'Monthly Refresh',
      timeframe: Timeframe.MONTHLY,
      boardSize: 4,
      shortBy: 14,
    };
    expect(formatPoolShortSummary([consumerA, consumerB])).toBe('Short on 2 boards');
    expect(formatPoolShortSummary([consumerA, consumerB, consumerC])).toBe('Short on 3 boards');
  });
});
