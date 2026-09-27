import { describe, expect, it } from 'vitest';
import { deriveSquareEditCount, isSquareDirty, type SquareDraftCell } from '../squareEditCount';

/**
 * Board Edit redesign slice 3 (D11/D12) — the pure edit-count / dirty-chip
 * core. `squaresEditReducer.test.ts` (via `squaresEditDraft.test.ts`) covers
 * the higher-level draft-state transitions; this file pins the count/dirty
 * formula directly against hand-built cells.
 */

function cell(id: string, overrides: Partial<SquareDraftCell> = {}): SquareDraftCell {
  return {
    cellId: id,
    row: 0,
    col: 0,
    taskId: `task-${id}`,
    isLocked: false,
    originalTaskId: `task-${id}`,
    originalRow: 0,
    originalCol: 0,
    originalLocked: false,
    ...overrides,
  };
}

describe('deriveSquareEditCount', () => {
  it('counts a lock toggle as one edit and un-counts a toggle back', () => {
    expect(
      deriveSquareEditCount({
        cells: [cell('a', { isLocked: true })],
        taskOverrides: new Map(),
        removedCount: 0,
        centerChanged: false,
        shuffled: false,
      }),
    ).toBe(1);
    expect(
      deriveSquareEditCount({
        cells: [cell('a', { isLocked: true, originalLocked: true })],
        taskOverrides: new Map(),
        removedCount: 0,
        centerChanged: false,
        shuffled: false,
      }),
    ).toBe(0);
  });

  it('adds every term independently: lock + replace + move + override + removal + center', () => {
    const cells = [
      cell('a', { isLocked: true }), // lock
      cell('b', { taskId: 'task-x' }), // replace
      cell('c', { row: 1 }), // move
    ];
    const count = deriveSquareEditCount({
      cells,
      taskOverrides: new Map([['task-c', {}]]), // override
      removedCount: 1, // a 4th, removed placement
      centerChanged: true,
      shuffled: false,
    });
    expect(count).toBe(6);
  });

  it('a staged ADD (originalTaskId=null) counts once, never as a "replace" too', () => {
    const added = cell('new-1', { originalTaskId: null, originalRow: 0, originalCol: 0 });
    expect(
      deriveSquareEditCount({
        cells: [added],
        taskOverrides: new Map(),
        removedCount: 0,
        centerChanged: false,
        shuffled: false,
      }),
    ).toBe(1);
  });

  it('a Shuffle collapses however many cells moved into ONE position edit', () => {
    const cells = [cell('a', { row: 1, col: 2 }), cell('b', { row: 0, col: 1 })];
    expect(
      deriveSquareEditCount({ cells, taskOverrides: new Map(), removedCount: 0, centerChanged: false, shuffled: true }),
    ).toBe(1);
    // Without the shuffle flag the same moves count individually.
    expect(
      deriveSquareEditCount({ cells, taskOverrides: new Map(), removedCount: 0, centerChanged: false, shuffled: false }),
    ).toBe(2);
  });

  it('no moved cells is 0 position edits even when `shuffled` is stale-true', () => {
    expect(
      deriveSquareEditCount({ cells: [cell('a')], taskOverrides: new Map(), removedCount: 0, centerChanged: false, shuffled: true }),
    ).toBe(0);
  });
});

describe('isSquareDirty', () => {
  const none = new Map();

  it('is dirty for a lock toggle, a replace, an override, a move, or an ADD; clean otherwise', () => {
    expect(isSquareDirty(cell('a'), none)).toBe(false);
    expect(isSquareDirty(cell('a', { isLocked: true }), none)).toBe(true);
    expect(isSquareDirty(cell('a', { taskId: 'other' }), none)).toBe(true);
    expect(isSquareDirty(cell('a', { col: 2 }), none)).toBe(true);
    expect(isSquareDirty(cell('a'), new Map([['task-a', {}]]))).toBe(true);
    expect(isSquareDirty(cell('new', { originalTaskId: null }), none)).toBe(true);
  });
});
