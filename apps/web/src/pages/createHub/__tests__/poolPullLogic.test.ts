import { describe, expect, it } from 'vitest';
import { CenterSquareType, Timeframe, TaskType, type Pool, type Task } from '@oybc/shared';
import {
  applyCoreBoardDefaultPrefill,
  applyManualBookkeepingOnDeselect,
  applyManualBookkeepingOnSelect,
  applyPullPool,
  applyUntogglePool,
  classifyChipProvenance,
  computeCoreFloorGate,
  deriveTaskProvenance,
  isCorePoolDefaultSaved,
  resolveRepeatsChange,
} from '../poolPullLogic';

/**
 * P3 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 5 "Wizard step 2") — covers the wizard-side wiring around
 * `@oybc/shared`'s `poolMix` functions. Uses the SAME worked-example
 * fixtures as `packages/shared/tests/algorithms/poolMix.test.ts` (pools
 * A{x,y}, B{y,z}) so the vectors visibly match across layers:
 * `resolveMix`'s formula is exercised there; this file exercises the
 * wizard's `selectedTaskIds` / `pulledPoolIds` / `manualTaskIds` /
 * `removedTaskIds` bookkeeping that sits on top of it.
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

describe('applyPullPool', () => {
  it('pulling A into an empty selection unions its full supply and appends the pool id', () => {
    const result = applyPullPool('A', new Set(), [], new Set(), poolsById, tasksById);
    expect(result.selectedTaskIds).toEqual(new Set(['x', 'y']));
    expect(result.pulledPoolIds).toEqual(['A']);
  });

  it('pulling B after A unions on top of the existing selection (union rule)', () => {
    const afterA = applyPullPool('A', new Set(), [], new Set(), poolsById, tasksById);
    const afterB = applyPullPool(
      'B',
      afterA.selectedTaskIds,
      afterA.pulledPoolIds,
      new Set(),
      poolsById,
      tasksById,
    );
    expect(afterB.selectedTaskIds).toEqual(new Set(['x', 'y', 'z']));
    expect(afterB.pulledPoolIds).toEqual(['A', 'B']);
  });

  it('a removed task stays suppressed across a fresh pull', () => {
    const result = applyPullPool('A', new Set(), [], new Set(['y']), poolsById, tasksById);
    expect(result.selectedTaskIds).toEqual(new Set(['x']));
  });

  it('is a no-op (same references) when the pool is already pulled', () => {
    const selected = new Set(['x', 'y']);
    const pulled = ['A'];
    const result = applyPullPool('A', selected, pulled, new Set(), poolsById, tasksById);
    expect(result.selectedTaskIds).toBe(selected);
    expect(result.pulledPoolIds).toBe(pulled);
  });

  it('is a no-op when the pool is missing or soft-deleted', () => {
    const selected = new Set<string>();
    const pulled: string[] = [];
    expect(applyPullPool('ghost', selected, pulled, new Set(), poolsById, tasksById)).toEqual({
      selectedTaskIds: selected,
      pulledPoolIds: pulled,
    });
    const deletedPoolsById = byId([{ ...poolA, isDeleted: true }, poolB]);
    expect(applyPullPool('A', selected, pulled, new Set(), deletedPoolsById, tasksById)).toEqual({
      selectedTaskIds: selected,
      pulledPoolIds: pulled,
    });
  });

  it('never touches an existing manually-added selection outside the pool', () => {
    const result = applyPullPool('A', new Set(['w']), [], new Set(), poolsById, tasksById);
    expect(result.selectedTaskIds).toEqual(new Set(['w', 'x', 'y']));
  });
});

describe('applyUntogglePool', () => {
  it('untoggling the only pulled pool removes its whole non-manual selection', () => {
    const result = applyUntogglePool(
      'A',
      new Set(['x', 'y']),
      ['A'],
      new Set(),
      new Set(),
      poolsById,
      tasksById,
    );
    expect(result.selectedTaskIds).toEqual(new Set());
    expect(result.pulledPoolIds).toEqual([]);
    expect(result.removedIds.sort()).toEqual(['x', 'y']);
  });

  it('manual-wins: a manually-added task in the pool is never removed', () => {
    const result = applyUntogglePool(
      'A',
      new Set(['x', 'y']),
      ['A'],
      new Set(['x']),
      new Set(),
      poolsById,
      tasksById,
    );
    expect(result.selectedTaskIds).toEqual(new Set(['x']));
    expect(result.removedIds).toEqual(['y']);
  });

  it('a task still supplied by a remaining pulled pool is not removed, and its removal bookkeeping persists', () => {
    // A+B pulled, removed=[y] per the doc's worked example step 1 →
    // mix would be {x,z}; untoggling B leaves y still supplied by A.
    const result = applyUntogglePool(
      'B',
      new Set(['x', 'z']),
      ['A', 'B'],
      new Set(),
      new Set(['y']),
      poolsById,
      tasksById,
    );
    expect(result.pulledPoolIds).toEqual(['A']);
    // z (B-only) is removed; y was never in the selection to begin with.
    expect(result.removedIds).toEqual(['z']);
    expect(result.selectedTaskIds).toEqual(new Set(['x']));
    // y's removal entry persists — still supplied by remaining pool A.
    expect(result.removedTaskIds).toEqual(new Set(['y']));
  });

  it('untoggling the last pool supplying a removed task clears that removal entry (worked example step 3)', () => {
    const result = applyUntogglePool(
      'A',
      new Set(['x']),
      ['A'],
      new Set(['w']),
      new Set(['y']),
      poolsById,
      tasksById,
    );
    expect(result.pulledPoolIds).toEqual([]);
    expect(result.removedTaskIds).toEqual(new Set());
  });
});

describe('applyManualBookkeepingOnSelect / applyManualBookkeepingOnDeselect', () => {
  it('selecting a task marks it manual and clears a stale removal entry for it', () => {
    const result = applyManualBookkeepingOnSelect('y', new Set(), new Set(['y']));
    expect(result.manualTaskIds).toEqual(new Set(['y']));
    expect(result.removedTaskIds).toEqual(new Set());
  });

  it('deselecting a task still supplied by a pulled pool records an explicit removal', () => {
    const result = applyManualBookkeepingOnDeselect(
      'y',
      new Set(['y']),
      new Set(),
      ['A'],
      poolsById,
      tasksById,
    );
    expect(result.manualTaskIds).toEqual(new Set());
    expect(result.removedTaskIds).toEqual(new Set(['y']));
  });

  it('deselecting a task not supplied by any pulled pool needs no removal entry', () => {
    const result = applyManualBookkeepingOnDeselect(
      'w',
      new Set(['w']),
      new Set(),
      ['A'],
      poolsById,
      tasksById,
    );
    expect(result.manualTaskIds).toEqual(new Set());
    expect(result.removedTaskIds).toEqual(new Set());
  });

  it('deselecting when the supplying pool is soft-deleted needs no removal entry (derived detachment)', () => {
    const deletedPoolsById = byId([{ ...poolA, isDeleted: true }]);
    const result = applyManualBookkeepingOnDeselect(
      'y',
      new Set(['y']),
      new Set(),
      ['A'],
      deletedPoolsById,
      tasksById,
    );
    expect(result.removedTaskIds).toEqual(new Set());
  });
});

describe('deriveTaskProvenance', () => {
  it('labels a manual task "added by hand" even if a pool also supplies it', () => {
    const provenance = deriveTaskProvenance(new Set(['x']), new Set(['x']), ['A'], poolsById, tasksById);
    expect(provenance.get('x')).toBe('added by hand');
  });

  it('labels a pool-sourced task "from <pool name>", using the FIRST pulled pool that supplies it', () => {
    const provenance = deriveTaskProvenance(new Set(['y']), new Set(), ['A', 'B'], poolsById, tasksById);
    expect(provenance.get('y')).toBe('from Pool A');
  });

  it('falls back to "added by hand" when no pulled pool supplies the task (e.g. legacy DefaultPool prefill)', () => {
    const provenance = deriveTaskProvenance(new Set(['w']), new Set(), [], poolsById, tasksById);
    expect(provenance.get('w')).toBe('added by hand');
  });

  it('only populates entries for ids in selectedTaskIds', () => {
    const provenance = deriveTaskProvenance(new Set(['x']), new Set(), ['A'], poolsById, tasksById);
    expect(provenance.has('y')).toBe(false);
    expect(provenance.get('x')).toBe('from Pool A');
  });
});

/**
 * P4 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 4 "Wizard step 1") — the "Repeats" segmented is now the
 * SINGLE entry point for recurrence (the separate "Create a recurring
 * board" CTA + `?newRecurring=1` retire alongside it). These tests cover
 * `resolveRepeatsChange`, the pure function `useBoardWizard.setRepeats`
 * delegates to.
 */
describe('resolveRepeatsChange', () => {
  it('Once → a cadence: flips isRecurring on, sets timeframe to the cadence, and remembers the prior one-off timeframe', () => {
    const result = resolveRepeatsChange({
      cadence: Timeframe.WEEKLY,
      isRecurring: false,
      timeframe: Timeframe.MONTHLY,
      centerType: CenterSquareType.FREE,
      centerTaskId: null,
      rememberedOneOffTimeframe: null,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.isRecurring).toBe(true);
    expect(result.timeframe).toBe(Timeframe.WEEKLY);
    expect(result.rememberedOneOffTimeframe).toBe(Timeframe.MONTHLY);
  });

  it('Once → a cadence coerces a CUSTOM one-off timeframe to INDEFINITE before remembering it (mirrors reset())', () => {
    const result = resolveRepeatsChange({
      cadence: Timeframe.DAILY,
      isRecurring: false,
      timeframe: Timeframe.CUSTOM,
      centerType: CenterSquareType.FREE,
      centerTaskId: null,
      rememberedOneOffTimeframe: null,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.rememberedOneOffTimeframe).toBe(Timeframe.INDEFINITE);
  });

  it('cadence → a different cadence (already recurring): leaves the remembered one-off timeframe untouched', () => {
    const result = resolveRepeatsChange({
      cadence: Timeframe.MONTHLY,
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      centerType: CenterSquareType.FREE,
      centerTaskId: null,
      rememberedOneOffTimeframe: Timeframe.YEARLY,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.isRecurring).toBe(true);
    expect(result.timeframe).toBe(Timeframe.MONTHLY);
    expect(result.rememberedOneOffTimeframe).toBe(Timeframe.YEARLY);
  });

  it('a cadence coerces CHOSEN center away to FREE and clears centerTaskId', () => {
    const result = resolveRepeatsChange({
      cadence: Timeframe.DAILY,
      isRecurring: false,
      timeframe: Timeframe.DAILY,
      centerType: CenterSquareType.CHOSEN,
      centerTaskId: 'task-1',
      rememberedOneOffTimeframe: null,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.centerType).toBe(CenterSquareType.FREE);
    expect(result.centerTaskId).toBeNull();
  });

  it('a cadence leaves a non-CHOSEN center type untouched', () => {
    const result = resolveRepeatsChange({
      cadence: Timeframe.DAILY,
      isRecurring: false,
      timeframe: Timeframe.DAILY,
      centerType: CenterSquareType.NONE,
      centerTaskId: null,
      rememberedOneOffTimeframe: null,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.centerType).toBe(CenterSquareType.NONE);
  });

  it('back to Once: restores the remembered one-off timeframe and flips isRecurring off', () => {
    const result = resolveRepeatsChange({
      cadence: null,
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      centerType: CenterSquareType.FREE,
      centerTaskId: null,
      rememberedOneOffTimeframe: Timeframe.MONTHLY,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.isRecurring).toBe(false);
    expect(result.timeframe).toBe(Timeframe.MONTHLY);
  });

  it('back to Once with nothing remembered yet: falls back to the coerced default one-off timeframe', () => {
    const result = resolveRepeatsChange({
      cadence: null,
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      centerType: CenterSquareType.FREE,
      centerTaskId: null,
      rememberedOneOffTimeframe: null,
      defaultOneOffTimeframe: Timeframe.CUSTOM,
    });
    expect(result.timeframe).toBe(Timeframe.INDEFINITE);
  });

  it('back to Once does not touch center type/taskId — CHOSEN becomes selectable again but nothing forces it', () => {
    const result = resolveRepeatsChange({
      cadence: null,
      isRecurring: true,
      timeframe: Timeframe.WEEKLY,
      centerType: CenterSquareType.FREE,
      centerTaskId: null,
      rememberedOneOffTimeframe: Timeframe.DAILY,
      defaultOneOffTimeframe: Timeframe.DAILY,
    });
    expect(result.centerType).toBe(CenterSquareType.FREE);
    expect(result.centerTaskId).toBeNull();
  });
});

/**
 * P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 6 "Core-board setup") — the CoreBoardDefault prefill,
 * the "Start every <Timeframe> board with 'X'" checkbox's derived checked
 * state, the fillable-floor gate math, and the chip-strip provenance
 * classification. Reuses this file's shared `x`/`y`/`z`/`w` /
 * `poolA`{x,y}/`poolB`{y,z} / `tasksById` / `poolsById` fixtures.
 */
describe('applyCoreBoardDefaultPrefill', () => {
  it('unions a single pool\'s resolvable supply and records it as pulled', () => {
    const result = applyCoreBoardDefaultPrefill(['A'], [], poolsById, tasksById);
    expect(result.selectedTaskIds).toEqual(new Set(['x', 'y']));
    expect(result.pulledPoolIds).toEqual(['A']);
  });

  it('folds multiple pools (union, not last-write-wins) — proves the fold, not a loop over the stateful callback', () => {
    const result = applyCoreBoardDefaultPrefill(['A', 'B'], [], poolsById, tasksById);
    expect(result.selectedTaskIds).toEqual(new Set(['x', 'y', 'z']));
    expect(result.pulledPoolIds).toEqual(['A', 'B']);
  });

  it('unions coreDefaultTaskIds on top of the pool supply, skipping deleted/missing ids', () => {
    const result = applyCoreBoardDefaultPrefill(
      ['A'],
      ['w', 'ghost', 'z'],
      poolsById,
      { ...tasksById, z: { ...tasksById.z, isDeleted: true } },
    );
    // w resolves and is added; ghost doesn't exist; z is soft-deleted.
    expect(result.selectedTaskIds).toEqual(new Set(['x', 'y', 'w']));
    expect(result.pulledPoolIds).toEqual(['A']);
  });

  it('is a pure resolution — never mentions or implies manualTaskIds (caller decides that)', () => {
    const result = applyCoreBoardDefaultPrefill(['A'], ['w'], poolsById, tasksById);
    expect(result).not.toHaveProperty('manualTaskIds');
    expect(Object.keys(result).sort()).toEqual(['pulledPoolIds', 'selectedTaskIds']);
  });

  it('with no corePoolIds and no coreDefaultTaskIds, resolves to an empty prefill', () => {
    const result = applyCoreBoardDefaultPrefill([], [], poolsById, tasksById);
    expect(result.selectedTaskIds).toEqual(new Set());
    expect(result.pulledPoolIds).toEqual([]);
  });
});

describe('isCorePoolDefaultSaved', () => {
  it('is true when both sets are non-empty and match regardless of order', () => {
    expect(isCorePoolDefaultSaved(['A', 'B'], ['B', 'A'])).toBe(true);
  });

  it('is false when the sets differ', () => {
    expect(isCorePoolDefaultSaved(['A', 'B'], ['A'])).toBe(false);
    expect(isCorePoolDefaultSaved(['A'], ['A', 'B'])).toBe(false);
    expect(isCorePoolDefaultSaved(['A'], ['B'])).toBe(false);
  });

  it('is false when either side is empty', () => {
    expect(isCorePoolDefaultSaved([], [])).toBe(false);
    expect(isCorePoolDefaultSaved(['A'], [])).toBe(false);
    expect(isCorePoolDefaultSaved([], ['A'])).toBe(false);
  });
});

describe('computeCoreFloorGate', () => {
  it('is satisfied with a zero remaining + empty message when selection meets the floor', () => {
    expect(computeCoreFloorGate(8, 8)).toEqual({
      remaining: 0,
      isSatisfied: true,
      message: '',
    });
    expect(computeCoreFloorGate(10, 8)).toEqual({
      remaining: 0,
      isSatisfied: true,
      message: '',
    });
  });

  it('reports the exact "Add N more" copy when short, for a 3x3+FREE floor (8)', () => {
    expect(computeCoreFloorGate(5, 8)).toEqual({
      remaining: 3,
      isSatisfied: false,
      message: 'Add 3 more',
    });
  });

  it('is symmetric for a DIFFERENT geometry (4x4 = 16), proving the floor is never hardcoded to 8', () => {
    expect(computeCoreFloorGate(10, 16)).toEqual({
      remaining: 6,
      isSatisfied: false,
      message: 'Add 6 more',
    });
  });
});

describe('classifyChipProvenance', () => {
  it('classifies a manually-added id as "manual"', () => {
    expect(classifyChipProvenance('x', new Set(['x']))).toBe('manual');
  });

  it('classifies a pool-/default-sourced id (not in manualTaskIds) as "plain"', () => {
    expect(classifyChipProvenance('y', new Set(['x']))).toBe('plain');
    expect(classifyChipProvenance('y', new Set())).toBe('plain');
  });
});
