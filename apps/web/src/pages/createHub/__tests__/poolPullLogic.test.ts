import { describe, expect, it } from 'vitest';
import { TaskType, type Pool, type Task } from '@oybc/shared';
import {
  applyCoreBoardDefaultPrefill,
  computeCoreFloorGate,
} from '../poolPullLogic';

/**
 * Board Sources P5 cleanup — this file now covers only the SURVIVING
 * `poolPullLogic` exports (the Board-settings defaults summary's
 * `applyCoreBoardDefaultPrefill` + the Preview step's
 * `computeCoreFloorGate`). The retired P3 pull/untoggle/bookkeeping/
 * provenance suite went with its subjects; the sources-native
 * replacements are covered in `wizardSources.test.ts` (same worked-
 * example fixtures, pools A{x,y}, B{y,z}).
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

