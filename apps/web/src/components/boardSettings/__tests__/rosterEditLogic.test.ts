import { describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import {
  addManualTaskToRoster,
  classifyRosterChip,
  hydrateRosterMix,
  pullPoolIntoRoster,
  removeResolvedTaskFromRoster,
  resolveRosterTaskIds,
  untogglePoolFromRoster,
  type RosterMix,
} from '../rosterEditLogic';

/**
 * P7 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 9 "roster edit sheet") — mirrors the worked-example
 * vectors in `pages/createHub/__tests__/poolPullLogic.test.ts` and
 * `packages/shared/tests/algorithms/poolMix.test.ts` (pools A{x,y},
 * B{y,z}) so the three extractions can't silently drift on behavior
 * despite operating on different state shapes.
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

function buildPool(id: string, name: string, taskIds: string[], overrides: Partial<Pool> = {}): Pool {
  return {
    id,
    userId: 'u1',
    name,
    taskIds,
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function buildTemplate(overrides: Partial<RecurringBoardTemplate> = {}): RecurringBoardTemplate {
  return {
    id: 't1',
    userId: 'u1',
    name: 'Morning routine',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: [],
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

const x = buildTask('x');
const y = buildTask('y');
const z = buildTask('z');
const w = buildTask('w');
const poolA = buildPool('A', 'Pool A', ['x', 'y']);
const poolB = buildPool('B', 'Pool B', ['y', 'z']);
const tasksById = byId([x, y, z, w]);
const poolsById = byId([poolA, poolB]);

describe('hydrateRosterMix', () => {
  it('reads poolIds/manualTaskIds/removedTaskIds verbatim for a migrated record', () => {
    const template = buildTemplate({
      poolIds: ['A'],
      manualTaskIds: ['w'],
      removedTaskIds: ['y'],
    });
    expect(hydrateRosterMix(template)).toEqual({
      poolIds: ['A'],
      manualTaskIds: ['w'],
      removedTaskIds: ['y'],
    });
  });

  it('flattens seedTaskIds into the manual layer for a genuinely un-migrated record', () => {
    const template = buildTemplate({ seedTaskIds: ['x', 'y'], poolIds: undefined });
    expect(hydrateRosterMix(template)).toEqual({
      poolIds: [],
      manualTaskIds: ['x', 'y'],
      removedTaskIds: [],
    });
  });

  it('defaults absent manualTaskIds/removedTaskIds to empty arrays', () => {
    const template = buildTemplate({ poolIds: ['A'] });
    expect(hydrateRosterMix(template)).toEqual({
      poolIds: ['A'],
      manualTaskIds: [],
      removedTaskIds: [],
    });
  });
});

describe('pullPoolIntoRoster', () => {
  it('appends the pool id; the union shows up via resolveRosterTaskIds', () => {
    const empty: RosterMix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    const afterA = pullPoolIntoRoster('A', empty, poolsById);
    expect(afterA.poolIds).toEqual(['A']);
    expect(resolveRosterTaskIds(afterA, poolsById, tasksById)).toEqual(['x', 'y']);
  });

  it('pulling B after A unions on top of the existing mix (union rule)', () => {
    const empty: RosterMix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    const afterA = pullPoolIntoRoster('A', empty, poolsById);
    const afterB = pullPoolIntoRoster('B', afterA, poolsById);
    expect(afterB.poolIds).toEqual(['A', 'B']);
    expect(resolveRosterTaskIds(afterB, poolsById, tasksById)).toEqual(['x', 'y', 'z']);
  });

  it('is a no-op (same reference) when the pool is already pulled', () => {
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] };
    expect(pullPoolIntoRoster('A', mix, poolsById)).toBe(mix);
  });

  it('is a no-op when the pool is missing or soft-deleted', () => {
    const mix: RosterMix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    expect(pullPoolIntoRoster('ghost', mix, poolsById)).toBe(mix);
    const deletedPoolsById = byId([{ ...poolA, isDeleted: true }, poolB]);
    expect(pullPoolIntoRoster('A', mix, deletedPoolsById)).toBe(mix);
  });
});

describe('untogglePoolFromRoster', () => {
  it('drops the pool id; the removed supply disappears via resolveRosterTaskIds', () => {
    const mix: RosterMix = { poolIds: ['A', 'B'], manualTaskIds: [], removedTaskIds: [] };
    const next = untogglePoolFromRoster('A', mix, poolsById);
    expect(next.poolIds).toEqual(['B']);
    expect(resolveRosterTaskIds(next, poolsById, tasksById)).toEqual(['y', 'z']);
  });

  it('the manual layer is never touched by a pool untoggle', () => {
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: ['w'], removedTaskIds: [] };
    const next = untogglePoolFromRoster('A', mix, poolsById);
    expect(next.manualTaskIds).toEqual(['w']);
  });

  it('worked example: removal persists while still supplied, clears once unsupplied', () => {
    // pools A{x,y} and B{y,z} pulled, removedTaskIds:[y], manualTaskIds:[w]
    // → mix = ({x,y,z} − {y}) + {w} = {x,z,w}
    const start: RosterMix = { poolIds: ['A', 'B'], manualTaskIds: ['w'], removedTaskIds: ['y'] };
    expect(resolveRosterTaskIds(start, poolsById, tasksById)).toEqual(['x', 'z', 'w']);

    // Untoggle B → y still supplied by A → removal persists → mix = {x,w}
    const afterUntoggleB = untogglePoolFromRoster('B', start, poolsById);
    expect(afterUntoggleB.removedTaskIds).toEqual(['y']);
    expect(resolveRosterTaskIds(afterUntoggleB, poolsById, tasksById)).toEqual(['x', 'w']);

    // Untoggle A too → y no longer supplied → removal cleared → mix = {w}
    const afterUntoggleA = untogglePoolFromRoster('A', afterUntoggleB, poolsById);
    expect(afterUntoggleA.removedTaskIds).toEqual([]);
    expect(resolveRosterTaskIds(afterUntoggleA, poolsById, tasksById)).toEqual(['w']);

    // Re-pull A later → y is back in the mix (its removal was cleared, not remembered).
    const afterRepullA = pullPoolIntoRoster('A', afterUntoggleA, poolsById);
    expect(resolveRosterTaskIds(afterRepullA, poolsById, tasksById)).toEqual(['x', 'y', 'w']);
  });

  it('is a no-op when the pool is not currently pulled', () => {
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] };
    expect(untogglePoolFromRoster('B', mix, poolsById)).toBe(mix);
  });
});

describe('addManualTaskToRoster', () => {
  it('adds the id to manualTaskIds', () => {
    const mix: RosterMix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    expect(addManualTaskToRoster('w', mix).manualTaskIds).toEqual(['w']);
  });

  it('clears a stale removal for the same id (manual wins)', () => {
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: [], removedTaskIds: ['y'] };
    const next = addManualTaskToRoster('y', mix);
    expect(next.manualTaskIds).toEqual(['y']);
    expect(next.removedTaskIds).toEqual([]);
  });

  it('is a no-op when already manual', () => {
    const mix: RosterMix = { poolIds: [], manualTaskIds: ['w'], removedTaskIds: [] };
    expect(addManualTaskToRoster('w', mix)).toBe(mix);
  });
});

describe('removeResolvedTaskFromRoster', () => {
  it('drops a manual-sourced chip from manualTaskIds', () => {
    const mix: RosterMix = { poolIds: [], manualTaskIds: ['w'], removedTaskIds: [] };
    expect(removeResolvedTaskFromRoster('w', mix, poolsById).manualTaskIds).toEqual([]);
  });

  it('records a removal for a pool-sourced chip still supplied by a pulled pool', () => {
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] };
    const next = removeResolvedTaskFromRoster('x', mix, poolsById);
    expect(next.removedTaskIds).toEqual(['x']);
    expect(resolveRosterTaskIds(next, poolsById, tasksById)).toEqual(['y']);
  });

  it('is a no-op for an id supplied by nothing pulled or manual', () => {
    const mix: RosterMix = { poolIds: [], manualTaskIds: [], removedTaskIds: [] };
    expect(removeResolvedTaskFromRoster('x', mix, poolsById)).toBe(mix);
  });

  it('dual-sourced (manual AND still supplied by a pulled pool): drops manual AND records the removal, so resolveMix excludes it', () => {
    // Regression test: the prior implementation early-returned after
    // dropping a manual-sourced id, so a task that was ALSO supplied by
    // an attached pool was never added to removedTaskIds — resolveMix's
    // union re-included it and the ✕ chip no-oped. Mirrors
    // `applyManualBookkeepingOnDeselect` / iOS `removeTaskFromMix`, which
    // both run the manual-drop and the pool-supply check unconditionally.
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: ['x'], removedTaskIds: [] };
    const next = removeResolvedTaskFromRoster('x', mix, poolsById);
    expect(next.manualTaskIds).toEqual([]);
    expect(next.removedTaskIds).toEqual(['x']);
    expect(resolveRosterTaskIds(next, poolsById, tasksById)).toEqual(['y']);
  });
});

describe('classifyRosterChip', () => {
  it('classifies a manual id as manual', () => {
    const mix: RosterMix = { poolIds: [], manualTaskIds: ['w'], removedTaskIds: [] };
    expect(classifyRosterChip('w', mix)).toBe('manual');
  });

  it('classifies a non-manual id as pool', () => {
    const mix: RosterMix = { poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] };
    expect(classifyRosterChip('x', mix)).toBe('pool');
  });
});
