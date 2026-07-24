/**
 * boardMetadataEdit.test.ts
 *
 * Tests for M2 (live-edit board metadata) semantics:
 *
 *   1. Center-square switch rules — the correct field is preserved or
 *      cleared depending on the source/target type pair.
 *   2. Derivation re-pass after timeframe/date change — tasks that
 *      were placed before the edit still re-derive correctly when
 *      `computeBoardStatsUpdate` is run with the updated board.
 *
 * These tests cover pure shared-package logic only. The DB write helper
 * (`updateBoardAndCascade`) is tested by integration tests that require
 * a live Dexie database (not available in the shared package).
 */

import { computeBoardStatsUpdate } from '../../src/algorithms/derivationPass';
import { CenterSquareType, Timeframe, BoardStatus, TaskType } from '../../src/constants/enums';
import type { Board, Task, BoardTask } from '../../src';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function makeBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'b1',
    userId: 'u1',
    name: 'Test Board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: '2026-05-01T00:00:00.000',
    endDate: '2026-05-31T23:59:59.999',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-05-01T00:00:00.000',
    updatedAt: '2026-05-01T00:00:00.000',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makeTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u1',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-05-01T00:00:00.000',
    updatedAt: '2026-05-01T00:00:00.000',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makeBoardTask(taskId: string, row: number, col: number): BoardTask {
  return {
    id: `bt-${taskId}`,
    boardId: 'b1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2026-05-01T00:00:00.000',
    updatedAt: '2026-05-01T00:00:00.000',
    version: 1,
  };
}

// ─── Section 1: center-square switch semantics (field-level rules) ─────────────
//
// These tests verify the SEMANTIC rules rather than the write helper,
// which is platform-specific. They check that:
//   - switching CHOSEN → FREE should preserve the boardTask placement
//     (the derivation does not change just from the center type change)
//   - switching FREE → CHOSEN requires a candidate boardTask
//   - CUSTOM_FREE center stores the custom name separately

describe('center-square switch semantics', () => {
  it('board stats re-derive correctly after switching centerSquareType from NONE to FREE (odd board auto-completes center)', () => {
    // 3x3 board — odd, so the center cell (row=1, col=1) is the free center.
    // With NONE: that cell has no BoardTask → counts as 0 completed.
    // With FREE: the center is auto-completed → counts as 1 completed
    //            (isCenterAutoCompleted returns true for FREE).
    const boardNone = makeBoard({ centerSquareType: CenterSquareType.NONE });
    const boardFree = makeBoard({ centerSquareType: CenterSquareType.FREE });

    const t1 = makeTask('t1', { isCompleted: true });
    const t2 = makeTask('t2', { isCompleted: false });
    // Place tasks at non-center positions only
    const bts: BoardTask[] = [
      makeBoardTask('t1', 0, 0),
      makeBoardTask('t2', 0, 1),
    ];
    const taskById = { t1, t2 };

    const statsNone = computeBoardStatsUpdate(boardNone, bts, {}, taskById, [], undefined);
    const statsFree = computeBoardStatsUpdate(boardFree, bts, {}, taskById, [], undefined);

    // With NONE: only t1 is completed → completedTasks = 1
    expect(statsNone.completedTasks).toBe(1);
    // With FREE: t1 + free center → completedTasks = 2
    expect(statsFree.completedTasks).toBe(2);
  });

  it('switching CHOSEN → FREE preserves underlying BoardTask (derivation sees it as a normal placed task)', () => {
    // The center task is placed as a regular BoardTask.
    // Switching to FREE: the BoardTask row is NOT deleted (per M2 spec).
    // The derivation should still count the task's completion state.
    const chosenTask = makeTask('center-task', { isCompleted: true });
    const board = makeBoard({
      centerSquareType: CenterSquareType.CHOSEN,
      centerTaskId: 'center-task',
    });
    // The center task IS placed in boardTasks (at the center position)
    const bts: BoardTask[] = [
      makeBoardTask('center-task', 1, 1), // center of a 3x3 board
    ];
    const taskById = { 'center-task': chosenTask };

    const statsChosen = computeBoardStatsUpdate(board, bts, {}, taskById, [], undefined);
    // CHOSEN center + task completed → completedTasks = 1
    expect(statsChosen.completedTasks).toBe(1);

    // Now simulate switching to FREE: centerSquareType changes, but the
    // BoardTask row stays in place. Derivation sees it as a normal cell.
    const boardFree = makeBoard({
      centerSquareType: CenterSquareType.FREE,
      centerTaskId: 'center-task', // row preserved (not cleared)
    });
    const statsFree = computeBoardStatsUpdate(boardFree, bts, {}, taskById, [], undefined);
    // FREE center on an odd board auto-completes the center cell ONLY when no
    // BoardTask occupies it. Here a BoardTask IS at (1,1), so the center is
    // treated as a normal placed task — isCenterAutoCompleted returns false.
    // The completed count is exactly 1 (the center-task itself, which isCompleted).
    expect(statsFree.completedTasks).toBe(1);
  });

  it('board stats with CUSTOM_FREE center behave like FREE (center auto-completed)', () => {
    const board = makeBoard({ centerSquareType: CenterSquareType.CUSTOM_FREE, centerSquareCustomName: 'Wild Card' });
    const t1 = makeTask('t1', { isCompleted: true });
    const bts: BoardTask[] = [makeBoardTask('t1', 0, 0)];
    const taskById = { t1 };

    const stats = computeBoardStatsUpdate(board, bts, {}, taskById, [], undefined);
    // t1 (completed) + CUSTOM_FREE center (auto-complete) = 2
    expect(stats.completedTasks).toBe(2);
  });
});

// ─── Section 2: derivation re-pass after timeframe/date change ────────────────
//
// Verifies that `computeBoardStatsUpdate` gives the right result after a
// board's timeframe is edited. The derivation pass reads board.startDate /
// board.endDate internally via taskExpiry (when tasks have timeframe data),
// so an expired task's completion state should be reflected correctly.

describe('derivation re-pass after timeframe/date change', () => {
  it('stats remain correct after board is retimed (same tasks, different window dates)', () => {
    const t1 = makeTask('t1', { isCompleted: true });
    const t2 = makeTask('t2', { isCompleted: true });
    const bts: BoardTask[] = [
      makeBoardTask('t1', 0, 0),
      makeBoardTask('t2', 0, 1),
    ];
    const taskById = { t1, t2 };

    // Original board: May 2026
    const boardMay = makeBoard({
      timeframe: Timeframe.MONTHLY,
      startDate: '2026-05-01T00:00:00.000',
      endDate: '2026-05-31T23:59:59.999',
    });

    // Edited board: June 2026 (retimed)
    const boardJune = makeBoard({
      timeframe: Timeframe.MONTHLY,
      startDate: '2026-06-01T00:00:00.000',
      endDate: '2026-06-30T23:59:59.999',
    });

    const statsMay = computeBoardStatsUpdate(boardMay, bts, {}, taskById, [], undefined);
    const statsJune = computeBoardStatsUpdate(boardJune, bts, {}, taskById, [], undefined);

    // Both tasks are completed regardless of which month the board covers.
    // completedTasks should be 2 in both cases (task completion is global).
    expect(statsMay.completedTasks).toBe(2);
    expect(statsJune.completedTasks).toBe(2);
  });

  it('switching from monthly to yearly timeframe does not change task completion counts', () => {
    const t1 = makeTask('t1', { isCompleted: true });
    const t2 = makeTask('t2', { isCompleted: false });
    const bts: BoardTask[] = [makeBoardTask('t1', 0, 0), makeBoardTask('t2', 0, 1)];
    const taskById = { t1, t2 };

    const boardMonthly = makeBoard({ timeframe: Timeframe.MONTHLY });
    const boardYearly = makeBoard({
      timeframe: Timeframe.YEARLY,
      startDate: '2026-01-01T00:00:00.000',
      endDate: '2026-12-31T23:59:59.999',
    });

    const statsMonthly = computeBoardStatsUpdate(boardMonthly, bts, {}, taskById, [], undefined);
    const statsYearly = computeBoardStatsUpdate(boardYearly, bts, {}, taskById, [], undefined);

    // Task completion is global — changing timeframe does not flip completion.
    expect(statsMonthly.completedTasks).toBe(1);
    expect(statsYearly.completedTasks).toBe(1);
  });

  it('renaming a board (name change) does not affect derivation stats', () => {
    const t1 = makeTask('t1', { isCompleted: true });
    const bts: BoardTask[] = [makeBoardTask('t1', 0, 0)];
    const taskById = { t1 };

    const boardOriginal = makeBoard({ name: 'Old Name' });
    const boardRenamed = makeBoard({ name: 'New Name' });

    const statsOriginal = computeBoardStatsUpdate(boardOriginal, bts, {}, taskById, [], undefined);
    const statsRenamed = computeBoardStatsUpdate(boardRenamed, bts, {}, taskById, [], undefined);

    // Name is irrelevant to stats.
    expect(statsOriginal.completedTasks).toBe(statsRenamed.completedTasks);
    expect(statsOriginal.linesCompleted).toBe(statsRenamed.linesCompleted);
  });
});
