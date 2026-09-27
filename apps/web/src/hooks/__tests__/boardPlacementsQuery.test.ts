import { describe, expect, it } from 'vitest';
import type { BoardTask } from '@oybc/shared';
import { resolveBoardPlacementsQuery } from '../boardPlacementsQuery';

/**
 * Zero-placement boards (docs/BOARD_EDIT_REDESIGN.md, independent bugfix
 * list) — a board whose every square was removed rendered "Loading board
 * tasks…" forever on web, because the play surface read "no placements
 * yet" off `sortedBoardTasks.length === 0`, which conflates the live query
 * still loading (`undefined`) with a LOADED board that has no rows (`[]`).
 * These tests pin the tri-state: only `undefined` means loading.
 */

function placement(id: string, row: number, col: number): BoardTask {
  return {
    id,
    boardId: 'board-1',
    taskId: `task-${id}`,
    row,
    col,
    isCenter: false,
    isLocked: false,
    isDeleted: false,
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
  } as unknown as BoardTask;
}

describe('resolveBoardPlacementsQuery', () => {
  it('reports NOT loaded while the live query is unresolved', () => {
    const result = resolveBoardPlacementsQuery(undefined, 3);
    expect(result.loaded).toBe(false);
    expect(result.boardTasks).toEqual([]);
  });

  it('reports loaded for a board with zero placements (the Loading-forever bug)', () => {
    const result = resolveBoardPlacementsQuery([], 3);
    expect(result.loaded).toBe(true);
    expect(result.boardTasks).toEqual([]);
  });

  it('reports loaded and resolves placements through the winner rule', () => {
    const inBounds = placement('a', 0, 0);
    const outOfBounds = placement('b', 7, 7);
    const result = resolveBoardPlacementsQuery([inBounds, outOfBounds], 3);
    expect(result.loaded).toBe(true);
    expect(result.boardTasks.map((bt) => bt.id)).toEqual(['a']);
  });
});
