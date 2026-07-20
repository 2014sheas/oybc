import { describe, expect, it } from 'vitest';
import { CenterSquareType, TaskType, Timeframe } from '@oybc/shared';
import type { Pool, RecurringBoardTemplate, Task } from '@oybc/shared';
import { computePoolHealthByPoolId } from '../poolHealthBatch';

/**
 * poolHealthBatch.test.ts — Pools browse batching helper (P2 Task 2).
 *
 * Covers the perf-critical invariant this repo has been burned on twice:
 * pool-card health must come from ONE pass over already-loaded
 * pools/templates/tasks, never a per-card lookup. Since
 * `computePoolHealthByPoolId` takes plain arrays/records (no DB access),
 * these assertions exercise the batching + per-pool correctness together.
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

describe('computePoolHealthByPoolId', () => {
  it('returns one result per pool, keyed by id', () => {
    const t1 = buildTask('t1');
    const poolA = buildPool('pA', ['t1']);
    const poolB = buildPool('pB', []);
    const tasksById = { t1 };

    const result = computePoolHealthByPoolId([poolA, poolB], [], tasksById);

    expect(Object.keys(result).sort()).toEqual(['pA', 'pB']);
    expect(result.pA.taskCount).toBe(1);
    expect(result.pB.taskCount).toBe(0);
  });

  it('resolves each pool independently against a shared template list (no cross-talk)', () => {
    const tasks = Array.from({ length: 8 }, (_, i) => buildTask(`t${i}`));
    const tasksById = Object.fromEntries(tasks.map((t) => [t.id, t]));

    // poolA is well-supplied (8 tasks); poolB is short (1 task).
    const poolA = buildPool('pA', tasks.map((t) => t.id));
    const poolB = buildPool('pB', ['t0']);

    const tplA = buildTemplate('tplA', { poolIds: ['pA'], name: 'Feeds A' });
    const tplB = buildTemplate('tplB', { poolIds: ['pB'], name: 'Feeds B' });

    const result = computePoolHealthByPoolId([poolA, poolB], [tplA, tplB], tasksById);

    expect(result.pA.consumers).toEqual([]);
    expect(result.pB.consumers).toEqual([
      { templateId: 'tplB', templateName: 'Feeds B', timeframe: Timeframe.WEEKLY, shortBy: 7 },
    ]);
  });

  it('a pool with no consumers or no templates at all reports empty consumers', () => {
    const pool = buildPool('pA', []);
    expect(computePoolHealthByPoolId([pool], [], {}).pA.consumers).toEqual([]);
  });

  it('returns {} for an empty pools list', () => {
    expect(computePoolHealthByPoolId([], [], {})).toEqual({});
  });
});
