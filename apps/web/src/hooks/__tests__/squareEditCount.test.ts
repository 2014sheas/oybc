import { describe, expect, it } from 'vitest';
import { CenterSquareType, type BoardTask } from '@oybc/shared';
import { deriveSquareEditCount, isDraftCellDirty } from '../squareEditCount';
import type { SquareDraftCell } from '../useBoardPlay';

function cell(id: string, overrides: Partial<SquareDraftCell> = {}): SquareDraftCell {
  return {
    boardTaskId: id, row: 0, col: 0, isCenter: false, taskId: `task-${id}`, originalTaskId: `task-${id}`,
    originalRow: 0, originalCol: 0, isLocked: false, originalLocked: false, ...overrides,
  };
}
const live = (ids: string[]): BoardTask[] => ids.map((id) => ({
  id, boardId: 'b', taskId: `task-${id}`, row: 0, col: 0, isCenter: false,
  createdAt: '', updatedAt: '', version: 1, isDeleted: false,
}));
const base = { taskOverrides: new Map<string, unknown>(), draftCenterType: CenterSquareType.NONE, editMode: true, draftSeeded: true };

describe('deriveSquareEditCount (Board Edit redesign slice 1)', () => {
  it('counts a lock toggle as one edit and un-counts a toggle back', () => {
    expect(deriveSquareEditCount({ ...base, squaresDraft: [cell('a', { isLocked: true })], boardTasks: live(['a']) })).toBe(1);
    expect(deriveSquareEditCount({ ...base, squaresDraft: [cell('a', { isLocked: true, originalLocked: true })], boardTasks: live(['a']) })).toBe(0);
  });

  it('adds lock toggles to the other terms', () => {
    const draft = [
      cell('a', { isLocked: true }),                // lock
      cell('b', { taskId: 'task-x' }),              // replace
      cell('c', { row: 1 }),                        // move
    ];
    const count = deriveSquareEditCount({
      ...base, squaresDraft: draft, boardTasks: live(['a', 'b', 'c', 'd']), // d removed
      taskOverrides: new Map([['task-c', {}]]),   // override
    });
    expect(count).toBe(5);
  });

  it('does not count removals before the draft is seeded', () => {
    expect(deriveSquareEditCount({ ...base, draftSeeded: false, squaresDraft: [], boardTasks: live(['a']) })).toBe(0);
  });
});

describe('isDraftCellDirty', () => {
  it('is dirty for a lock toggle, a replace, an override or a move; clean otherwise', () => {
    const none = new Map<string, unknown>();
    expect(isDraftCellDirty(cell('a'), none)).toBe(false);
    expect(isDraftCellDirty(cell('a', { isLocked: true }), none)).toBe(true);
    expect(isDraftCellDirty(cell('a', { taskId: 'other' }), none)).toBe(true);
    expect(isDraftCellDirty(cell('a', { col: 2 }), none)).toBe(true);
    expect(isDraftCellDirty(cell('a'), new Map([['task-a', {}]]))).toBe(true);
  });
});
