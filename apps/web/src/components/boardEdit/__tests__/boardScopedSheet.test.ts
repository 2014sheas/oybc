import { afterEach, describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type BoardTask, type Task } from '@oybc/shared';
import { db } from '../../../db/internal';
import { fetchWouldForkOnBoard } from '../../../db/operations/boardScopedEdit';
import { FORK_CONFIRM_BODY, needsForkConfirm, sheetDoneLabel } from '../boardScopedSheet';

/**
 * Board-scoped task edits PR 2 — the Board Edit square sheet's scope control
 * (docs/BOARD_SCOPED_TASK_EDITS.md §8): "Save for this board" exactly when
 * the Save would fork, one confirm the first time per board per edit session.
 */

const T0 = '2026-10-01T00:00:00.000Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: 'u', title: id, type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0,
    totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}
function board(id: string, over: Partial<Board> = {}): Board {
  return {
    id, userId: 'u', name: id, status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
    startDate: T0, centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9,
    completedTasks: 0, linesCompleted: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  } as Board;
}
function placement(id: string, boardId: string, taskId: string): BoardTask {
  return { id, boardId, taskId, row: 0, col: 0, isCenter: false, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}

afterEach(async () => {
  await Promise.all([db.boards, db.boardTasks, db.tasks, db.compoundChildren].map((t) => t.clear()));
});

describe('board-scoped sheet model', () => {
  it('labels Done "Save for this board" only when the Save would fork', () => {
    expect(sheetDoneLabel(true)).toBe('Save for this board');
    expect(sheetDoneLabel(false)).toBe('Done');
  });

  it('confirms only a fork, and only until the board session has confirmed once', () => {
    expect(needsForkConfirm(true, false)).toBe(true);
    expect(needsForkConfirm(true, true)).toBe(false);
    expect(needsForkConfirm(false, false)).toBe(false);
  });

  it('carries the spec confirm body verbatim', () => {
    expect(FORK_CONFIRM_BODY).toBe('Applies to this board only. Other boards keep the original.');
  });
});

describe('fetchWouldForkOnBoard', () => {
  it('is true for a task also placed on another live board, false otherwise', async () => {
    await db.boards.bulkAdd([board('B1'), board('B2'), board('BX', { isDeleted: true })]);
    await db.tasks.bulkAdd([task('T'), task('S'), task('D')]);
    await db.boardTasks.bulkAdd([
      placement('p1', 'B1', 'T'), placement('p2', 'B2', 'T'),
      placement('p3', 'B1', 'S'),
      placement('p4', 'B1', 'D'), placement('p5', 'BX', 'D'),
    ]);
    expect(await fetchWouldForkOnBoard('T', 'B1')).toBe(true);
    expect(await fetchWouldForkOnBoard('S', 'B1')).toBe(false);
    expect(await fetchWouldForkOnBoard('D', 'B1')).toBe(false);
    expect(await fetchWouldForkOnBoard('pending-not-stored', 'B1')).toBe(false);
  });
});
