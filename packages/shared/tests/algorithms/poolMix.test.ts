import {
  resolveMix,
  clampMintedPoolName,
  resolvePoolPullAdditions,
  summarizeSpawnProvenanceFromSupplies,
  formatSpawnProvenanceNote,
} from '../../src/algorithms/poolMix';
import {
  NO_BOARD_FOR_WINDOW_NOTE,
  type BoardSourceSupply,
} from '../../src/algorithms/boardSources';
import type { BoardSource } from '../../src/types/boardSource';
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

  it('step 2: B untoggled, removal of y kept (still supplied by A) → {x,w}', () => {
    const result = resolveMix(
      { poolIds: ['A'], manualTaskIds: ['w'], removedTaskIds: ['y'] },
      poolsById,
      tasksById,
    );
    expect(result.taskIds).toEqual(['x', 'w']);
  });

  it('step 3: A untoggled too, y unsupplied so its removal is cleared → {w}', () => {
    const result = resolveMix(
      { poolIds: [], manualTaskIds: ['w'], removedTaskIds: [] },
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

// ─── resolvePoolPullAdditions (P3 wizard action) ─────────────────────────────
//
// Operates on the SAME worked-example fixtures as `resolveMix` above, but
// drives the wizard's flat `selectedTaskIds` mutation directly (rather
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

// ─── summarizeSpawnProvenanceFromSupplies + formatSpawnProvenanceNote (P6) ────
//
// docs/POOLS_RECURRING.md §Surfaces item 7 — the board-screen spawn-success
// provenance note, e.g. "Picked 8 of 10 — 7 from the pool, 1 added today".
// Locked decision C: generic "pulled in" wording (not the doc's
// "defaults"-specific example text), since this note also covers a
// "repeat this board" spawn with zero pool involvement. Same vectors the
// retired pool-trio overload used, now fed as resolved source supplies.

function poolSupply(sourceId: string, supplyTaskIds: string[]): BoardSourceSupply {
  const source: BoardSource = {
    sourceId,
    kind: 'pool',
    min: 0,
    max: null,
    excludedTaskIds: [],
    filter: 'all',
  };
  return { source, supplyTaskIds };
}

describe('summarizeSpawnProvenanceFromSupplies + formatSpawnProvenanceNote', () => {
  it('pure-pool spawn: manualSourcedCount is 0, note reads "N pulled in" only', () => {
    const supply = poolSupply('pool-a', ['t1', 't2', 't3', 't4', 't5', 't6', 't7', 't8', 't9', 't10']);
    // Board only fit 8 of the 10-task mix (loose-fit overfill).
    const dealtTaskIds = ['t1', 't2', 't3', 't4', 't5', 't6', 't7', 't8'];

    const summary = summarizeSpawnProvenanceFromSupplies([supply], [], {}, dealtTaskIds);
    expect(summary).toEqual({
      dealt: 8,
      mixSize: 10,
      poolSourcedCount: 8,
      manualSourcedCount: 0,
    });
    expect(formatSpawnProvenanceNote(summary)).toBe('Picked 8 of 10 — 8 pulled in');
  });

  it('pure-manual spawn (e.g. "repeat this board", zero pools): poolSourcedCount is 0, note reads "N added today" only', () => {
    const manual = ['m1', 'm2', 'm3', 'm4', 'm5'];

    const summary = summarizeSpawnProvenanceFromSupplies([], manual, {}, manual);
    expect(summary).toEqual({
      dealt: 5,
      mixSize: 5,
      poolSourcedCount: 0,
      manualSourcedCount: 5,
    });
    expect(formatSpawnProvenanceNote(summary)).toBe('Picked 5 of 5 — 5 added today');
  });

  it("mixed spawn: pool + manual both present, counts match the doc's numeric structure", () => {
    const poolTaskIds = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7'];
    // Mix size = 7 pool + 1 manual = 8; board dealt all 8 (exact fit).
    const dealtTaskIds = [...poolTaskIds, 'm1'];

    const summary = summarizeSpawnProvenanceFromSupplies(
      [poolSupply('pool-a', poolTaskIds)],
      ['m1'],
      {},
      dealtTaskIds,
    );
    expect(summary).toEqual({
      dealt: 8,
      mixSize: 8,
      poolSourcedCount: 7,
      manualSourcedCount: 1,
    });
    expect(formatSpawnProvenanceNote(summary)).toBe('Picked 8 of 8 — 7 pulled in, 1 added today');
  });

  it('zero-dealt edge case: note reads "Picked 0 of N" with no breakdown clause', () => {
    const summary = summarizeSpawnProvenanceFromSupplies([], [], {}, []);
    expect(summary).toEqual({ dealt: 0, mixSize: 0, poolSourcedCount: 0, manualSourcedCount: 0 });
    expect(formatSpawnProvenanceNote(summary)).toBe('Picked 0 of 0');
  });

  // Owner ruling 2026-09-24 — a board source with no board for the spawned
  // window (a series whose instance doesn't exist yet, an ended one-off)
  // deals nothing; the provenance note says so.
  it('a board source with no board for this window appends the note', () => {
    const summary = summarizeSpawnProvenanceFromSupplies(
      [poolSupply('pool-a', ['p1', 'p2'])],
      ['m1'],
      {},
      ['p1', 'p2', 'm1'],
      1,
    );
    expect(summary).toEqual({
      dealt: 3,
      mixSize: 3,
      poolSourcedCount: 2,
      manualSourcedCount: 1,
      noBoardForWindowCount: 1,
    });
    expect(formatSpawnProvenanceNote(summary)).toBe(
      `Picked 3 of 3 — 2 pulled in, 1 added today · ${NO_BOARD_FOR_WINDOW_NOTE}`,
    );
  });

  it('a zero windowless count leaves the summary and the note unchanged', () => {
    const summary = summarizeSpawnProvenanceFromSupplies([], ['m1'], {}, ['m1'], 0);
    expect(summary).toEqual({ dealt: 1, mixSize: 1, poolSourcedCount: 0, manualSourcedCount: 1 });
    expect(formatSpawnProvenanceNote(summary)).toBe('Picked 1 of 1 — 1 added today');
  });
});
