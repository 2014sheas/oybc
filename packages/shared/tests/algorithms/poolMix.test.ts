import {
  resolveMix,
  clearRemovalsForUntoggle,
  isLegacyShapedRecord,
  mergeLegacyPoolTaskIds,
  clampMintedPoolName,
  resolvePoolPullAdditions,
  resolvePoolUntoggleRemovals,
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

// ─── resolvePoolPullAdditions / resolvePoolUntoggleRemovals (P3 wizard actions) ──
//
// Both operate on the SAME worked-example fixtures as `resolveMix` above,
// but drive the wizard's flat `selectedTaskIds` mutation directly (rather
// than recomputing the whole mix) — see docs/POOLS_RECURRING.md §Surfaces
// item 5 (Wizard step 2) + §Data model "Union rule".

describe('resolvePoolPullAdditions', () => {
  const x = buildTask('x');
  const y = buildTask('y');
  const z = buildTask('z');
  const poolA = buildPool('A', ['x', 'y']);
  const poolB = buildPool('B', ['y', 'z']);
  const tasksById = byId([x, y, z]);
  const poolsById = byId([poolA, poolB]);

  it('pulling a fresh pool returns its full resolvable supply', () => {
    expect(resolvePoolPullAdditions('A', [], poolsById, tasksById)).toEqual(['x', 'y']);
  });

  it('a removed task stays suppressed across a pull (removal persists until untoggle clears it)', () => {
    expect(resolvePoolPullAdditions('A', ['y'], poolsById, tasksById)).toEqual(['x']);
  });

  it('re-pulling after the removal was cleared (empty removedTaskIds) returns the full supply again', () => {
    expect(resolvePoolPullAdditions('A', [], poolsById, tasksById)).toEqual(['x', 'y']);
  });

  it('a soft-deleted task in the pool is excluded from the additions', () => {
    const tasksWithDeleted = byId([x, buildTask('y', { isDeleted: true })]);
    expect(resolvePoolPullAdditions('A', [], poolsById, tasksWithDeleted)).toEqual(['x']);
  });

  it('a missing or soft-deleted pool contributes no additions, not an error', () => {
    expect(resolvePoolPullAdditions('ghost', [], poolsById, tasksById)).toEqual([]);
    const deletedPoolsById = byId([{ ...poolA, isDeleted: true }, poolB]);
    expect(resolvePoolPullAdditions('A', [], deletedPoolsById, tasksById)).toEqual([]);
  });
});

describe('resolvePoolUntoggleRemovals', () => {
  const x = buildTask('x');
  const y = buildTask('y');
  const z = buildTask('z');
  const w = buildTask('w');
  const poolA = buildPool('A', ['x', 'y']);
  const poolB = buildPool('B', ['y', 'z']);
  const tasksById = byId([x, y, z, w]);
  const poolsById = byId([poolA, poolB]);

  it('untoggling the only pulled pool removes its whole non-manual supply', () => {
    expect(resolvePoolUntoggleRemovals('A', [], [], poolsById, tasksById)).toEqual(['x', 'y']);
  });

  it('manual-wins: a manually-added task is never in the removal set', () => {
    expect(resolvePoolUntoggleRemovals('A', [], ['x'], poolsById, tasksById)).toEqual(['y']);
  });

  it('a task still supplied by a REMAINING pulled pool is not removed', () => {
    // Untoggling A while B stays pulled: y is also supplied by B → keep it.
    expect(resolvePoolUntoggleRemovals('A', ['B'], [], poolsById, tasksById)).toEqual(['x']);
  });

  it('untoggling B (with A remaining) removes only z — y stays (A still supplies it)', () => {
    expect(resolvePoolUntoggleRemovals('B', ['A'], [], poolsById, tasksById)).toEqual(['z']);
  });

  it('"remaining supply" is checked structurally (raw taskIds), even if the task is soft-deleted', () => {
    const deletedY = byId([x, buildTask('y', { isDeleted: true }), z, w]);
    // y is soft-deleted (unresolvable) but B's RAW taskIds still list it, so
    // it still counts as "remaining supply" and is not removed by A's untoggle.
    expect(resolvePoolUntoggleRemovals('A', ['B'], [], poolsById, deletedY)).toEqual(['x']);
  });

  it('a soft-deleted remaining pool contributes no supply — its previously-shared task is removed', () => {
    const deletedB = byId([{ ...poolB, isDeleted: true }]);
    const poolsWithDeletedB = { A: poolA, ...deletedB };
    expect(
      resolvePoolUntoggleRemovals('A', ['B'], [], poolsWithDeletedB, tasksById),
    ).toEqual(['x', 'y']);
  });

  it('a missing or soft-deleted target pool contributes no removals, not an error', () => {
    expect(resolvePoolUntoggleRemovals('ghost', ['A'], [], poolsById, tasksById)).toEqual([]);
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

// ─── clampMintedPoolName (review finding I1) ──────────────────────────────

describe('clampMintedPoolName', () => {
  it('leaves a short source name untouched', () => {
    expect(clampMintedPoolName('Daily', 'default')).toBe('Daily default');
    expect(clampMintedPoolName('Morning Kickstart', 'pool')).toBe('Morning Kickstart pool');
  });

  it('boundary: a 120-char template name mints exactly a 120-char Pool name', () => {
    // PoolSchema.name is z.string().min(1).max(120) — the schema this
    // guards. Also matches RecurringBoardTemplate.name's own 120-char max,
    // so this is a realistic worst-case source, not a contrived one.
    const name120 = 'x'.repeat(120);
    const minted = clampMintedPoolName(name120, 'pool');
    expect(minted.length).toBe(120);
    expect(minted).toBe(`${'x'.repeat(115)} pool`);
  });

  it('a name at exactly the boundary (115 chars + " pool" = 120) is untouched', () => {
    const name115 = 'y'.repeat(115);
    expect(clampMintedPoolName(name115, 'pool')).toBe(`${name115} pool`);
    expect(clampMintedPoolName(name115, 'pool').length).toBe(120);
  });

  it('a longer suffix (" default") clamps the source to a shorter budget', () => {
    const name120 = 'z'.repeat(120);
    const minted = clampMintedPoolName(name120, 'default');
    expect(minted.length).toBe(120);
    expect(minted).toBe(`${'z'.repeat(112)} default`);
  });

  it('respects a custom maxLen', () => {
    expect(clampMintedPoolName('abcdefghij', 'pool', 10)).toBe('abcde pool');
  });

  // Cross-platform clamp-unit parity (P1 #336 review M-1): the clamp must
  // measure the SAME unit as PoolSchema's z.string().max(120) — UTF-16 code
  // units — so iOS (Swift twin) and web agree on validity for a non-BMP name.
  // A non-BMP char (🎯, 2 UTF-16 units) near the boundary must not overflow.
  it('clamps by UTF-16 units, never splitting a non-BMP surrogate pair', () => {
    // 57 × 🎯 = 114 UTF-16 units; + " pool" (5) = 119 ≤ 120 → unclamped.
    const name57targets = '🎯'.repeat(57);
    const under = clampMintedPoolName(name57targets, 'pool');
    expect(under).toBe(`${name57targets} pool`);
    expect(under.length).toBe(119);

    // 58 × 🎯 = 116 units; source budget is 115 → must drop the last whole
    // 🎯 (not split it), landing at 57 🎯 (114) + " pool" = 119 ≤ 120.
    const name58targets = '🎯'.repeat(58);
    const clamped = clampMintedPoolName(name58targets, 'pool');
    expect(clamped).toBe(`${'🎯'.repeat(57)} pool`);
    expect(clamped.length).toBeLessThanOrEqual(120);
    // No lone surrogate: round-trips through UTF-16 unchanged.
    expect([...clamped].every((cp) => cp.codePointAt(0)! <= 0x10ffff)).toBe(true);
  });
});

// ─── F5: legacy-template edit preserves soft-deleted-but-not-removed refs ─────

describe('mergeLegacyPoolTaskIds', () => {
  it('preserves a soft-deleted-but-not-removed pool ref the resolved selection dropped', () => {
    // Pool has [live, gone] where `gone` is soft-deleted. `resolveMix` would
    // hydrate the wizard selection to just [live] (deleted filtered out), so a
    // plain write of the selection would PRUNE `gone` — the contract breach.
    const live = buildTask('live');
    const gone = buildTask('gone', { isDeleted: true });
    const tasksById = byId([live, gone]);
    const merged = mergeLegacyPoolTaskIds(['live', 'gone'], ['live'], tasksById);
    // `gone` survives (never shown to the user → can't have been removed).
    expect(merged).toEqual(['live', 'gone']);
  });

  it('drops a resolvable ref the user explicitly removed from the selection', () => {
    const a = buildTask('a');
    const b = buildTask('b');
    const tasksById = byId([a, b]);
    // Both resolvable; user removed `b` (selection is just [a]) → `b` drops.
    const merged = mergeLegacyPoolTaskIds(['a', 'b'], ['a'], tasksById);
    expect(merged).toEqual(['a']);
  });

  it('appends newly-selected ids after the preserved existing order, deduped', () => {
    const a = buildTask('a');
    const gone = buildTask('gone', { isDeleted: true });
    const added = buildTask('added');
    const tasksById = byId([a, gone, added]);
    // existing [a, gone] (gone soft-deleted, preserved); selection adds `added`.
    const merged = mergeLegacyPoolTaskIds(['a', 'gone'], ['a', 'added'], tasksById);
    expect(merged).toEqual(['a', 'gone', 'added']);
  });

  it('preserves a ref whose task is entirely missing from the library', () => {
    const a = buildTask('a');
    const tasksById = byId([a]); // `orphan` resolves to nothing
    const merged = mergeLegacyPoolTaskIds(['a', 'orphan'], ['a'], tasksById);
    expect(merged).toEqual(['a', 'orphan']);
  });
});
