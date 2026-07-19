import {
  resolveMix,
  clearRemovalsForUntoggle,
  isLegacyShapedRecord,
} from '../../src/algorithms/poolMix';
import { TaskType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';
import type { Pool } from '../../src/types/pool';

/**
 * poolMix.test.ts — Task Pools + Recurring Boards Rework (P1)
 *
 * The doc's worked example (docs/POOLS_RECURRING.md §Changed: the spawn
 * record) IS the required test-vector set: pools A{x,y} and B{y,z} pulled,
 * `removedTaskIds:[y]`, `manualTaskIds:[w]` → mix = {x,z,w} (y suppressed
 * from BOTH supplies at once). Untoggle B → y still supplied by A → removal
 * persists → mix = {x,w}. Untoggle A too → y unsupplied → removal cleared →
 * mix = {w}. Re-pull A → y is back in the mix (its removal was cleared, not
 * remembered) → mix = {x,y,w}.
 *
 * This has a Swift twin: apps/ios/OYBCTests/PoolMixTests.swift (Task 3),
 * mirroring these cases case-for-case, including the worked example.
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

function byId<T extends { id: string }>(items: T[]): Record<string, T> {
  const out: Record<string, T> = {};
  for (const item of items) out[item.id] = item;
  return out;
}

// ─── The worked example (docs §Changed: the spawn record) ────────────────────

describe('resolveMix — worked example', () => {
  const x = buildTask('x');
  const y = buildTask('y');
  const z = buildTask('z');
  const w = buildTask('w');
  const poolA = buildPool('A', ['x', 'y']);
  const poolB = buildPool('B', ['y', 'z']);
  const tasksById = byId([x, y, z, w]);
  const poolsById = byId([poolA, poolB]);

  it('step 1: A+B pulled, removed=[y], manual=[w] → {x,z,w}', () => {
    const result = resolveMix(
      { poolIds: ['A', 'B'], manualTaskIds: ['w'], removedTaskIds: ['y'] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x', 'z', 'w']);
  });

  it('step 2: untoggle B → removal of y persists (still supplied by A) → {x,w}', () => {
    const clearedRemovals = clearRemovalsForUntoggle(
      { poolIds: ['A', 'B'], manualTaskIds: ['w'], removedTaskIds: ['y'] },
      'B',
      poolsById,
    );
    expect(clearedRemovals).toEqual(['y']);

    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: ['w'], removedTaskIds: clearedRemovals },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x', 'w']);
  });

  it('step 3: untoggle A too → y now unsupplied → removal cleared → {w}', () => {
    const clearedRemovals = clearRemovalsForUntoggle(
      { poolIds: ['A'], manualTaskIds: ['w'], removedTaskIds: ['y'] },
      'A',
      poolsById,
    );
    expect(clearedRemovals).toEqual([]);

    const result = resolveMix(
      { poolIds: [], manualTaskIds: ['w'], removedTaskIds: clearedRemovals },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['w']);
  });

  it('step 4: re-pull A → removal was cleared (not remembered) → {x,y,w}', () => {
    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: ['w'], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x', 'y', 'w']);
  });

  it('suppliedByPool reflects each pulled pool\'s resolvable supply', () => {
    const result = resolveMix(
      { poolIds: ['A', 'B'], manualTaskIds: ['w'], removedTaskIds: ['y'] },
      poolsById,
      tasksById,
    );
    expect(result.suppliedByPool).toEqual({ A: ['x', 'y'], B: ['y', 'z'] });
  });
});

// ─── Manual wins over removal ─────────────────────────────────────────────────

describe('resolveMix — manual wins over removal', () => {
  it('a task both manually added and removed IS in the mix, with no duplicate', () => {
    const poolA = buildPool('A', ['y']);
    const tasksById = byId([buildTask('y')]);
    const poolsById = byId([poolA]);

    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: ['y'], removedTaskIds: ['y'] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['y']);
  });

  it('a manual-only task (no pool supplies it) is appended after pool-sourced ids', () => {
    const poolA = buildPool('A', ['x']);
    const tasksById = byId([buildTask('x'), buildTask('m')]);
    const poolsById = byId([poolA]);

    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: ['m'], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x', 'm']);
  });
});

// ─── Stale-inert removal entries ──────────────────────────────────────────────

describe('resolveMix — stale-inert removals', () => {
  it('a removal entry for a task not supplied by any pulled pool is a harmless no-op', () => {
    const poolA = buildPool('A', ['x']);
    const tasksById = byId([buildTask('x'), buildTask('never-pulled')]);
    const poolsById = byId([poolA]);

    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: [], removedTaskIds: ['never-pulled'] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x']);
  });
});

// ─── Deleted-pool skip (derived detachment) ───────────────────────────────────

describe('resolveMix — deleted-pool skip', () => {
  it('a soft-deleted pulled pool contributes nothing and has no suppliedByPool entry', () => {
    const poolA = buildPool('A', ['x']);
    const poolB = buildPool('B', ['y'], { isDeleted: true });
    const tasksById = byId([buildTask('x'), buildTask('y')]);
    const poolsById = byId([poolA, poolB]);

    const result = resolveMix(
      { poolIds: ['A', 'B'], manualTaskIds: [], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x']);
    expect(result.suppliedByPool).toEqual({ A: ['x'] });
  });

  it('a pulled poolId with no matching pool record (missing) is skipped, not an error', () => {
    const poolA = buildPool('A', ['x']);
    const tasksById = byId([buildTask('x')]);
    const poolsById = byId([poolA]);

    expect(() =>
      resolveMix(
        { poolIds: ['A', 'ghost-pool'], manualTaskIds: [], removedTaskIds: [] },
        poolsById,
        tasksById,
      ),
    ).not.toThrow();

    const result = resolveMix(
      { poolIds: ['A', 'ghost-pool'], manualTaskIds: [], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x']);
    expect(result.suppliedByPool).toEqual({ A: ['x'] });
  });
});

// ─── Deleted-task skip (resolvable filtering) ─────────────────────────────────

describe('resolveMix — deleted-task skip', () => {
  it('a soft-deleted task referenced by a pool is excluded from the resolved supply', () => {
    const poolA = buildPool('A', ['x', 'y']);
    const tasksById = byId([buildTask('x'), buildTask('y', { isDeleted: true })]);
    const poolsById = byId([poolA]);

    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x']);
    expect(result.suppliedByPool).toEqual({ A: ['x'] });
  });

  it('a task id in a pool with no matching Task record (missing) is excluded, not an error', () => {
    const poolA = buildPool('A', ['x', 'ghost-task']);
    const tasksById = byId([buildTask('x')]);
    const poolsById = byId([poolA]);

    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x']);
  });

  it('a manually-added task that is itself soft-deleted is still included verbatim (manual is not filtered by task existence)', () => {
    // resolveMix resolves POOL supply against non-deleted tasks; the manual
    // layer is caller-curated (the wizard/roster UI only lets a user pick
    // live tasks) and is passed through as-is — mirrors buildSpawnPlacement's
    // "caller must filter" contract for poolTasks.
    const tasksById = byId([buildTask('m', { isDeleted: true })]);
    const poolsById: Record<string, Pool> = {};

    const result = resolveMix(
      { poolIds: [], manualTaskIds: ['m'], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['m']);
  });
});

// ─── Duplicate poolIds / empty inputs ─────────────────────────────────────────

describe('resolveMix — edge inputs', () => {
  it('empty poolIds + empty manual → empty mix', () => {
    const result = resolveMix(
      { poolIds: [], manualTaskIds: [], removedTaskIds: [] },
      {},
      {},
    );
    expect(result.taskIds).toEqual([]);
    expect(result.suppliedByPool).toEqual({});
  });

  it('a duplicate poolId in poolIds does not duplicate its supply in the union', () => {
    const poolA = buildPool('A', ['x']);
    const tasksById = byId([buildTask('x')]);
    const poolsById = byId([poolA]);

    const result = resolveMix(
      { poolIds: ['A', 'A'], manualTaskIds: [], removedTaskIds: [] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x']);
  });
});

// ─── clearRemovalsForUntoggle — additional cases ──────────────────────────────

describe('clearRemovalsForUntoggle', () => {
  it('untoggling a pool that was never the sole supplier leaves unrelated removals untouched', () => {
    const poolA = buildPool('A', ['x']);
    const poolB = buildPool('B', ['y']);
    const poolsById = byId([poolA, poolB]);

    const cleared = clearRemovalsForUntoggle(
      { poolIds: ['A', 'B'], manualTaskIds: [], removedTaskIds: ['x'] },
      'B',
      poolsById,
    );
    // x is still supplied by A (untouched by B's untoggle) → persists.
    expect(cleared).toEqual(['x']);
  });

  it('a deleted remaining pool does not count as supply for clearing purposes', () => {
    const poolA = buildPool('A', ['x'], { isDeleted: true });
    const poolB = buildPool('B', ['y']);
    const poolsById = byId([poolA, poolB]);

    const cleared = clearRemovalsForUntoggle(
      { poolIds: ['A', 'B'], manualTaskIds: [], removedTaskIds: ['x'] },
      'B',
      poolsById,
    );
    // A is soft-deleted, so it no longer counts as supply — x's removal clears.
    expect(cleared).toEqual([]);
  });
});

// ─── isLegacyShapedRecord — truth table ───────────────────────────────────────

describe('isLegacyShapedRecord', () => {
  it('true: all three fields absent (genuinely un-migrated record)', () => {
    expect(isLegacyShapedRecord({})).toBe(true);
  });

  it('true: migration/legacy-create-minted shape (exactly one pool, empty manual+removed)', () => {
    expect(
      isLegacyShapedRecord({ poolIds: ['A'], manualTaskIds: [], removedTaskIds: [] }),
    ).toBe(true);
  });

  it('true: zero pools, empty manual+removed (explicit empty arrays, not absent)', () => {
    expect(
      isLegacyShapedRecord({ poolIds: [], manualTaskIds: [], removedTaskIds: [] }),
    ).toBe(true);
  });

  it('false: two or more pools (richer shape)', () => {
    expect(
      isLegacyShapedRecord({ poolIds: ['A', 'B'], manualTaskIds: [], removedTaskIds: [] }),
    ).toBe(false);
  });

  it('false: any manual additions', () => {
    expect(
      isLegacyShapedRecord({ poolIds: ['A'], manualTaskIds: ['m'], removedTaskIds: [] }),
    ).toBe(false);
  });

  it('false: any removals', () => {
    expect(
      isLegacyShapedRecord({ poolIds: ['A'], manualTaskIds: [], removedTaskIds: ['r'] }),
    ).toBe(false);
  });
});
