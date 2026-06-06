/**
 * placementAddRemove.test.ts — Unit tests for placement add/remove cascade logic (live-edit M4).
 *
 * Tests verify that:
 *   - Removing a BoardTask affects only the target board (not other boards sharing the same Task).
 *   - Adding a Task already completed elsewhere reflects shared-task semantics (completion is global).
 *   - Cascade union correctly covers all affected boards across all paths (direct + compound).
 *   - Bingo line membership tracks correctly after remove/add changes the board's grid.
 *
 * Uses the shared `findAffectedBoardIds` + `findTransitiveParentCompounds` +
 * `computeBoardStatsUpdate` helpers that the production cascade wrappers call.
 * No DB or platform code is imported.
 */

import {
  findAffectedBoardIds,
  findTransitiveParentCompounds,
  computeBoardStatsUpdate,
} from '../../src/algorithms/derivationPass';
import type { Board, BoardTask, CompoundChild, Task } from '../../src/types';
import { BoardStatus, TaskType, Timeframe, CenterSquareType } from '../../src/constants';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function makeBoardTask(
  id: string,
  boardId: string,
  taskId: string,
  row = 0,
  col = 0,
): BoardTask {
  return {
    id,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
  };
}

function makeCompoundChild(
  id: string,
  compoundTaskId: string,
  childTaskId: string,
  childIndex = 0,
): CompoundChild {
  return {
    id,
    compoundTaskId,
    childTaskId,
    childIndex,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

function makeTask(id: string, opts: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...opts,
  };
}

function makeBoard(id: string, opts: Partial<Board> = {}): Board {
  return {
    id,
    userId: 'user-1',
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.CUSTOM,
    startDate: '2024-01-01',
    endDate: '2024-12-31',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    isCore: false,
    ...opts,
  };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe('placement add/remove — affected board computation', () => {

  // 1. Remove a placed task: only THIS board loses the placement
  it('remove affects only the board holding the removed BoardTask, not other boards sharing the Task', () => {
    // task-A is placed on board-1 (removed cell) AND board-2 (kept)
    const boardTasksBeforeRemove = [
      makeBoardTask('bt1', 'board-1', 'task-A'),
      makeBoardTask('bt2', 'board-2', 'task-A'),
    ];

    // After remove: bt1 is gone — only board-2 still places task-A
    const boardTasksAfterRemove = [
      makeBoardTask('bt2', 'board-2', 'task-A'),
    ];

    // Boards affected by the task removal (based on pre-remove state, since that
    // is what needs to re-derive — both boards still reference task-A at remove time)
    const parents = findTransitiveParentCompounds('task-A', []);
    const affected = findAffectedBoardIds('task-A', parents, boardTasksBeforeRemove);

    expect(affected.has('board-1')).toBe(true);
    expect(affected.has('board-2')).toBe(true);

    // After the cascade, board-2 still has task-A in its grid (task-A.isCompleted unchanged)
    const taskById = { 'task-A': makeTask('task-A') };
    const board2tasks = boardTasksAfterRemove.filter((bt) => bt.boardId === 'board-2');
    const stats = computeBoardStatsUpdate(
      makeBoard('board-2', { boardSize: 3, totalTasks: 1 }),
      board2tasks,
      {},
      taskById,
      [],
    );
    // board-2 still has 1 placement, task not completed → completedTasks stays 0
    expect(stats.completedTasks).toBe(0);
  });

  // 2. Remove the completed task cell: board.completedTasks decrements
  it('removing a completed task decrements board.completedTasks', () => {
    const boardTasks = [
      makeBoardTask('bt1', 'board-1', 'task-done', 0, 0),
      makeBoardTask('bt2', 'board-1', 'task-todo', 0, 1),
    ];
    const taskById = {
      'task-done': makeTask('task-done', { isCompleted: true }),
      'task-todo': makeTask('task-todo'),
    };

    // Board before remove: completedTasks = 1
    const board = makeBoard('board-1', { boardSize: 3, totalTasks: 2, completedTasks: 1 });
    const statsBefore = computeBoardStatsUpdate(board, boardTasks, {}, taskById, []);
    expect(statsBefore.completedTasks).toBe(1);

    // After removing the completed task placement:
    const afterRemove = [makeBoardTask('bt2', 'board-1', 'task-todo', 0, 1)];
    const statsAfter = computeBoardStatsUpdate(board, afterRemove, {}, taskById, []);
    expect(statsAfter.completedTasks).toBe(0);
  });

  // 3. Remove the only task in a winning bingo line: the line breaks
  it('removing a task from a completed bingo line causes that line to be lost', () => {
    // 3×3 board. Row 0 is complete (all 3 tasks complete). Remove bt at col=0 of row 0.
    // After remove, row 0 is incomplete.
    const row0tasks = [
      makeBoardTask('bt1', 'board-1', 'task-r0c0', 0, 0),
      makeBoardTask('bt2', 'board-1', 'task-r0c1', 0, 1),
      makeBoardTask('bt3', 'board-1', 'task-r0c2', 0, 2),
    ];
    const otherTasks = [
      makeBoardTask('bt4', 'board-1', 'task-r1c0', 1, 0),
      makeBoardTask('bt5', 'board-1', 'task-r1c1', 1, 1),
      makeBoardTask('bt6', 'board-1', 'task-r1c2', 1, 2),
      makeBoardTask('bt7', 'board-1', 'task-r2c0', 2, 0),
      makeBoardTask('bt8', 'board-1', 'task-r2c1', 2, 1),
      makeBoardTask('bt9', 'board-1', 'task-r2c2', 2, 2),
    ];
    const allBoardTasks = [...row0tasks, ...otherTasks];

    const taskById: Record<string, Task> = {
      'task-r0c0': makeTask('task-r0c0', { isCompleted: true }),
      'task-r0c1': makeTask('task-r0c1', { isCompleted: true }),
      'task-r0c2': makeTask('task-r0c2', { isCompleted: true }),
      'task-r1c0': makeTask('task-r1c0'),
      'task-r1c1': makeTask('task-r1c1'),
      'task-r1c2': makeTask('task-r1c2'),
      'task-r2c0': makeTask('task-r2c0'),
      'task-r2c1': makeTask('task-r2c1'),
      'task-r2c2': makeTask('task-r2c2'),
    };

    const board = makeBoard('board-1', { boardSize: 3, totalTasks: 9, linesCompleted: 1, completedLineIds: ['row-0'] });

    // Before remove: row 0 is a bingo
    const statsBefore = computeBoardStatsUpdate(board, allBoardTasks, {}, taskById, []);
    expect(statsBefore.linesCompleted).toBe(1);

    // After removing bt1 (task-r0c0 at row=0, col=0):
    const afterRemove = allBoardTasks.filter((bt) => bt.id !== 'bt1');
    const statsAfter = computeBoardStatsUpdate(board, afterRemove, {}, taskById, []);
    // Row 0 is now missing col=0, so the line is broken
    expect(statsAfter.linesCompleted).toBe(0);
  });

  // 4. Add a task that is already globally completed: board.completedTasks increments
  it('adding a globally-completed task increments board.completedTasks (shared-task semantics)', () => {
    const existingBoardTasks = [
      makeBoardTask('bt1', 'board-1', 'task-todo', 0, 0),
    ];
    const newPlacement = makeBoardTask('bt2', 'board-1', 'task-done', 0, 1);
    const taskById = {
      'task-todo': makeTask('task-todo'),
      'task-done': makeTask('task-done', { isCompleted: true }),
    };

    const board = makeBoard('board-1', { boardSize: 3, totalTasks: 2 });

    // Before add: completedTasks = 0
    const statsBefore = computeBoardStatsUpdate(board, existingBoardTasks, {}, taskById, []);
    expect(statsBefore.completedTasks).toBe(0);

    // After adding the completed task placement:
    const afterAdd = [...existingBoardTasks, newPlacement];
    const statsAfter = computeBoardStatsUpdate(board, afterAdd, {}, taskById, []);
    expect(statsAfter.completedTasks).toBe(1);
  });

  // 5. Add a task that was just removed (same Task, same cell): idempotent result
  it('adding the same task back to the same cell produces the same stats as before removal', () => {
    const original = [
      makeBoardTask('bt-new', 'board-1', 'task-A', 0, 0),
      makeBoardTask('bt2', 'board-1', 'task-B', 0, 1),
    ];
    const taskById = {
      'task-A': makeTask('task-A'),
      'task-B': makeTask('task-B'),
    };
    const board = makeBoard('board-1', { boardSize: 3, totalTasks: 2 });

    const statsOriginal = computeBoardStatsUpdate(board, original, {}, taskById, []);

    // Remove task-A, then add it back (new BoardTask id, same taskId + position)
    const afterRemove = original.filter((bt) => bt.taskId !== 'task-A');
    const afterAdd = [
      ...afterRemove,
      makeBoardTask('bt-new-2', 'board-1', 'task-A', 0, 0),
    ];
    const statsAfterRoundTrip = computeBoardStatsUpdate(board, afterAdd, {}, taskById, []);

    expect(statsAfterRoundTrip.completedTasks).toBe(statsOriginal.completedTasks);
    expect(statsAfterRoundTrip.linesCompleted).toBe(statsOriginal.linesCompleted);
  });

  // 6. Add a task never previously on this board: cascade fires for new board
  it('adding a task never placed before correctly initialises cascade for its new board', () => {
    // board-2 only has task-B. We add task-C (which is already on board-1).
    const workspaceBoardTasks = [
      makeBoardTask('bt1', 'board-1', 'task-C'),
      makeBoardTask('bt2', 'board-2', 'task-B'),
    ];

    const parents = findTransitiveParentCompounds('task-C', []);
    const affectedBefore = findAffectedBoardIds('task-C', parents, workspaceBoardTasks);
    // Before add: only board-1 is affected
    expect(affectedBefore.has('board-1')).toBe(true);
    expect(affectedBefore.has('board-2')).toBe(false);

    // After adding task-C to board-2:
    const afterAdd = [
      ...workspaceBoardTasks,
      makeBoardTask('bt3', 'board-2', 'task-C'),
    ];
    const affectedAfter = findAffectedBoardIds('task-C', parents, afterAdd);
    expect(affectedAfter.has('board-1')).toBe(true);
    expect(affectedAfter.has('board-2')).toBe(true);
  });

  // 7. Concurrent remove + add: each independently computes its own affected boards
  it('remove and add affect disjoint boards when tasks are independent', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-remove', 'task-X'),
      makeBoardTask('bt2', 'board-add', 'task-Y'),
    ];

    // Remove task-X from board-remove
    const removeParents = findTransitiveParentCompounds('task-X', []);
    const removeAffected = findAffectedBoardIds('task-X', removeParents, allBoardTasks);
    expect(removeAffected.has('board-remove')).toBe(true);
    expect(removeAffected.has('board-add')).toBe(false);

    // Add task-Y to board-remove
    const addedState = [...allBoardTasks, makeBoardTask('bt3', 'board-remove', 'task-Y')];
    const addParents = findTransitiveParentCompounds('task-Y', []);
    const addAffected = findAffectedBoardIds('task-Y', addParents, addedState);
    expect(addAffected.has('board-add')).toBe(true);
    expect(addAffected.has('board-remove')).toBe(true); // now also placed there
  });

  // 8. Cascade union covers all affected boards across remove + add paths
  it('union of remove + add affected boards covers all impacted boards', () => {
    // Setup: compound-C contains task-leaf. Boards: A places compound-C, B places task-leaf.
    // We remove task-leaf from B and add task-other to B.
    const compoundChildren = [
      makeCompoundChild('cc1', 'compound-C', 'task-leaf'),
    ];
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-A', 'compound-C'),
      makeBoardTask('bt2', 'board-B', 'task-leaf'),
      makeBoardTask('bt3', 'board-C', 'task-other'),
    ];

    // Remove task-leaf from board-B: board-A (compound parent) + board-B are affected
    const removeParents = findTransitiveParentCompounds('task-leaf', compoundChildren);
    const removeAffected = findAffectedBoardIds('task-leaf', removeParents, allBoardTasks);
    expect(removeAffected.has('board-A')).toBe(true); // compound parent
    expect(removeAffected.has('board-B')).toBe(true); // direct placement

    // Add task-other to board-B: board-B + board-C are affected
    const afterAdd = [...allBoardTasks, makeBoardTask('bt4', 'board-B', 'task-other')];
    const addParents = findTransitiveParentCompounds('task-other', compoundChildren);
    const addAffected = findAffectedBoardIds('task-other', addParents, afterAdd);
    expect(addAffected.has('board-B')).toBe(true);
    expect(addAffected.has('board-C')).toBe(true);

    // Union covers all four boards involved
    const union = new Set([...removeAffected, ...addAffected]);
    expect(union.has('board-A')).toBe(true);
    expect(union.has('board-B')).toBe(true);
    expect(union.has('board-C')).toBe(true);
  });
});
