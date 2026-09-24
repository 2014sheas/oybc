import {
  computePoolHealth,
  formatPoolShortSummary,
  templateConsumesPool,
} from '../../src/algorithms/poolHealth';
import { TaskType, Timeframe, CenterSquareType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';
import type { Pool } from '../../src/types/pool';
import type { RecurringBoardTemplate } from '../../src/types/recurringBoardTemplate';
import type { BoardSource } from '../../src/types/boardSource';

/**
 * poolHealth.test.ts — Task Pools + Recurring Boards Rework (P2)
 *
 * Covers the named cases from the P2 Task 1 brief: consumer detection
 * (active-only; deleted templates skipped), shortBy math across sizes/
 * centers, the exact warning-string format, a pool consumed by multiple
 * templates, and a healthy pool (no consumers).
 *
 * 2026-09 audit T2: `computePoolHealth` now takes each template's
 * PRE-RESOLVED achievable size (the spawn's own number, resolved at the DB
 * layer from every source) and decides consumption from `sources`, never
 * the `poolIds` mirror. The end-to-end "old wrong answer" cases (pool +
 * board source; a capped pool source) live where the size is resolved:
 * web `components/pools/__tests__/poolHealthBatch.test.ts` and iOS
 * `PoolHealthBatchTests.swift`.
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

function poolSource(sourceId: string, overrides: Partial<BoardSource> = {}): BoardSource {
  return { sourceId, kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all', ...overrides };
}

function boardSource(sourceId: string, overrides: Partial<BoardSource> = {}): BoardSource {
  return { sourceId, kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all', ...overrides };
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

    const result = computePoolHealth(pool, { templates: [], tasksById: byId([t1, t2]) });

    expect(result.taskCount).toBe(1);
    expect(result.consumers).toEqual([]);
  });

  it('excludes achievements from the card count (supply ban, 2026-09-10)', () => {
    const normals = ['n1', 'n2', 'n3'].map((id) => buildTask(id));
    const watcher = buildTask('watch', {
      type: TaskType.ACHIEVEMENT,
      referencedBoardId: 'b-elsewhere',
    });
    const pool = buildPool('p1', ['n1', 'n2', 'n3', 'watch']);

    const result = computePoolHealth(pool, {
      templates: [],
      tasksById: byId([...normals, watcher]),
    });

    expect(result.taskCount).toBe(3);
  });
});

// ─── templateConsumesPool ──────────────────────────────────────────────────────

describe('templateConsumesPool — sources decide, never the poolIds mirror', () => {
  it('a pool-kind source naming the pool consumes it', () => {
    const template = buildTemplate('tpl', { sources: [poolSource('p1')], poolIds: [] });
    expect(templateConsumesPool(template, 'p1')).toBe(true);
  });

  it('a stale poolIds mirror naming the pool does NOT make a sources record a consumer', () => {
    // The old predicate read `poolIds.includes(pool.id)` and would have
    // said yes here.
    const template = buildTemplate('tpl', { sources: [poolSource('p2')], poolIds: ['p1'] });
    expect(templateConsumesPool(template, 'p1')).toBe(false);
  });

  it('a board-kind source whose id happens to equal the pool id is not a pool consumer', () => {
    const template = buildTemplate('tpl', { sources: [boardSource('p1')] });
    expect(templateConsumesPool(template, 'p1')).toBe(false);
  });

  it('an un-migrated v1 record (no sources) consumes its poolIds via the decode mapping', () => {
    const template = buildTemplate('tpl', { poolIds: ['p1'] });
    expect(template.sources).toBeUndefined();
    expect(templateConsumesPool(template, 'p1')).toBe(true);
    expect(templateConsumesPool(template, 'p2')).toBe(false);
  });
});

// ─── computePoolHealth: consumer detection ─────────────────────────────────────

describe('computePoolHealth — consumer detection', () => {
  const pool = buildPool('p1', ['t1', 't2']);
  const tasksById = byId([buildTask('t1'), buildTask('t2')]);

  it('includes an active template short on its achievable size as a consumer', () => {
    // 3x3 FREE floor is 8; achievable 2 -> shortBy 6.
    const template = buildTemplate('tpl1', { sources: [poolSource('p1')] });

    const result = computePoolHealth(pool, {
      templates: [{ template, achievableSize: 2 }],
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

  it('skips a soft-deleted template even if it pulls the pool', () => {
    const template = buildTemplate('tpl1', { sources: [poolSource('p1')], isDeleted: true });
    const result = computePoolHealth(pool, {
      templates: [{ template, achievableSize: 2 }],
      tasksById,
    });
    expect(result.consumers).toEqual([]);
  });

  it('skips a paused (isActive: false) template', () => {
    const template = buildTemplate('tpl1', { sources: [poolSource('p1')], isActive: false });
    const result = computePoolHealth(pool, {
      templates: [{ template, achievableSize: 2 }],
      tasksById,
    });
    expect(result.consumers).toEqual([]);
  });

  it('skips a short template that does not pull this pool', () => {
    const template = buildTemplate('tpl1', { sources: [poolSource('other-pool')] });
    const result = computePoolHealth(pool, {
      templates: [{ template, achievableSize: 2 }],
      tasksById,
    });
    expect(result.consumers).toEqual([]);
  });

  it('skips a short template whose only link to the pool is a stale poolIds mirror', () => {
    const template = buildTemplate('tpl1', {
      sources: [boardSource('b1')],
      poolIds: ['p1'],
    });
    const result = computePoolHealth(pool, {
      templates: [{ template, achievableSize: 2 }],
      tasksById,
    });
    expect(result.consumers).toEqual([]);
  });

  it('judges the template by its achievable size, not by this pool alone', () => {
    // The pool supplies 2, but the template's achievable size (pool +
    // other sources) is 8 = the 3x3 FREE floor -> not short.
    const template = buildTemplate('tpl1', {
      sources: [poolSource('p1'), boardSource('b1')],
    });
    const result = computePoolHealth(pool, {
      templates: [{ template, achievableSize: 8 }],
      tasksById,
    });
    expect(result.consumers).toEqual([]);
  });
});

// ─── computePoolHealth: shortBy math across sizes/centers ──────────────────────

describe('computePoolHealth — shortBy math across sizes/centers', () => {
  const pool = buildPool('p1', ['t1', 't2']);
  const tasksById = byId([buildTask('t1'), buildTask('t2')]);

  function shortByFor(boardSize: RecurringBoardTemplate['boardSize'], centerSquareType: CenterSquareType, size: number) {
    const template = buildTemplate('tpl1', {
      sources: [poolSource('p1')],
      boardSize,
      centerSquareType,
    });
    return computePoolHealth(pool, {
      templates: [{ template, achievableSize: size }],
      tasksById,
    }).consumers;
  }

  it('3x3 FREE center: floor 8, achievable 2 -> shortBy 6', () => {
    expect(shortByFor(3, CenterSquareType.FREE, 2)[0].shortBy).toBe(6);
  });

  it('3x3 NONE center: floor 9, achievable 2 -> shortBy 7', () => {
    expect(shortByFor(3, CenterSquareType.NONE, 2)[0].shortBy).toBe(7);
  });

  it("4x4: floor 16, achievable 2 -> shortBy 14, and threads the consuming template's boardSize", () => {
    const consumers = shortByFor(4, CenterSquareType.FREE, 2);
    expect(consumers[0].shortBy).toBe(14);
    expect(consumers[0].boardSize).toBe(4);
  });

  it('achievable exactly at the floor is NOT a consumer (shortBy 0 excluded)', () => {
    expect(shortByFor(3, CenterSquareType.FREE, 8)).toEqual([]);
  });

  it('achievable one below the floor is short by exactly 1', () => {
    expect(shortByFor(3, CenterSquareType.FREE, 7)[0].shortBy).toBe(1);
  });
});

// ─── computePoolHealth: multiple consumers ─────────────────────────────────────

describe('computePoolHealth — pool consumed by multiple templates', () => {
  it('returns a consumer entry per short template that pulls the pool, in input order', () => {
    const pool = buildPool('p1', ['t1']);
    const tplA = buildTemplate('tplA', {
      name: 'Morning Kickstart',
      sources: [poolSource('p1')],
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
    });
    const tplB = buildTemplate('tplB', {
      name: 'Weekly Reset',
      sources: [poolSource('p1')],
      timeframe: Timeframe.WEEKLY,
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE,
    });

    const result = computePoolHealth(pool, {
      templates: [
        { template: tplA, achievableSize: 1 },
        { template: tplB, achievableSize: 1 },
      ],
      tasksById: byId([buildTask('t1')]),
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
