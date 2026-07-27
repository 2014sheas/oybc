import { afterEach, describe, expect, it } from 'vitest';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  addBoardTaskToBoard,
  removeBoardTaskFromBoard,
  reorderBoardTasks,
  updateBoardTaskAndCascade,
} from '../boardTasks';
import { updateBoardAndCascade, type UpdateActiveBoardPatch } from '../boards';

/**
 * bugfix/edit-preserves-board-window — the full edit x completion x bingo
 * interaction matrix.
 *
 * The window-preservation fix (see `boardEditWindowPreservation.test.ts`)
 * only covers the metadata-patch date bug in isolation. This file exercises
 * the composed edit surface (replace / rearrange / remove / center-toggle)
 * against a board carrying REAL windowed completions, proving that:
 *   - untouched cells' completion state survives structural edits,
 *   - bingo lines recompute correctly from POSITION after a rearrange while
 *     the underlying per-task completion travels with the task,
 *   - removing a completed cell drops exactly that cell from the stats,
 *   - center-square type toggles affect only the center auto-fill,
 *   - achievement cells (cross-board watchers) are untouched by unrelated
 *     edits on their own board.
 *
 * All fixtures place completion events safely INSIDE the board's window
 * (board opened 5 days ago; events 2 days ago) so every assertion is about
 * the edit operation, not accidentally about window boundaries (that's the
 * sibling file's job).
 */

function daysAgoISO(days: number): string {
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
}

function daysFromNowISO(days: number): string {
  return new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
}

const WINDOW_START = daysAgoISO(5);
const IN_WINDOW = daysAgoISO(2);

async function seedTask(
  id: string,
  overrides: Partial<Task> = {},
): Promise<void> {
  const task: Task = {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: daysAgoISO(30),
    updatedAt: daysAgoISO(30),
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.tasks.add(task);
}

/** Seed a NORMAL task with a completion event INSIDE the board's window. */
async function seedCompletedTask(id: string): Promise<void> {
  await seedTask(id, { isCompleted: true, completedAt: IN_WINDOW, totalCompletions: 1 });
  const event: TaskEvent = {
    id: `evt-${id}`,
    userId: 'user-1',
    taskId: id,
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
}

async function seedBoard(id: string, overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: 'user-1',
    name: `Board ${id}`,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: WINDOW_START,
    endDate: daysFromNowISO(2),
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedPlacement(
  id: string,
  boardId: string,
  taskId: string,
  row: number,
  col: number,
): Promise<void> {
  const bt: BoardTask = {
    id,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('Board-Edit: completion + bingo matrix', () => {
  it('replacing one cell preserves the windowed completion of untouched cells', async () => {
    await seedBoard('board-1');
    await seedCompletedTask('task-A'); // stays put, complete
    await seedCompletedTask('task-B'); // stays put, complete
    await seedTask('task-C'); // will be swapped in, incomplete
    await seedTask('task-D'); // occupies the cell being replaced, incomplete

    await seedPlacement('bt-A', 'board-1', 'task-A', 0, 0);
    await seedPlacement('bt-B', 'board-1', 'task-B', 0, 1);
    await seedPlacement('bt-D', 'board-1', 'task-D', 1, 1);

    // Replace the (1,1) cell's task: D -> C.
    await updateBoardTaskAndCascade('bt-D', 'task-C');

    const board = await db.boards.get('board-1');
    // A and B remain complete; the replaced cell (task-C) is incomplete.
    expect(board!.completedTasks).toBe(2);
    const btD = await db.boardTasks.get('bt-D');
    expect(btD!.taskId).toBe('task-C');
  });

  it('rearrange: moving a completed cell OFF a bingo line breaks that line but the cell stays green at its new position', async () => {
    await seedBoard('board-1');
    await seedCompletedTask('task-A');
    await seedCompletedTask('task-B');
    await seedCompletedTask('task-C');
    await seedTask('task-D'); // incomplete filler so (2,2) starts occupied

    await seedPlacement('bt-A', 'board-1', 'task-A', 0, 0);
    await seedPlacement('bt-B', 'board-1', 'task-B', 0, 1);
    await seedPlacement('bt-C', 'board-1', 'task-C', 0, 2);

    // Establish row_0 as a real, derived bingo via a cascade-triggering op
    // (placing the incomplete filler at (2,2) doesn't touch row 0, but its
    // derivation pass computes completedLineIds for the FIRST time from the
    // current placement set).
    await addBoardTaskToBoard('board-1', 'task-D', 2, 2);
    let board = await db.boards.get('board-1');
    expect(board!.completedLineIds ?? []).toContain('row_0');
    expect(board!.completedTasks).toBe(3); // A, B, C — D is incomplete

    // Move task-C (a completed cell) from (0,2) to (2,2)'s row — swap it
    // with the filler's row-2 slot instead: move C to (2,0), off row 0.
    await reorderBoardTasks('board-1', [{ boardTaskId: 'bt-C', row: 2, col: 0 }]);

    board = await db.boards.get('board-1');
    // row_0 is broken — only A and B remain in row 0 now.
    expect(board!.completedLineIds ?? []).not.toContain('row_0');
    // task-C is still individually complete, just relocated — completedTasks
    // (a per-task, not per-line, tally) is unchanged.
    expect(board!.completedTasks).toBe(3);

    // Move task-C back to (0,2) — row_0 reforms from the SAME underlying
    // completion state, proving the line recompute is purely positional.
    await reorderBoardTasks('board-1', [{ boardTaskId: 'bt-C', row: 0, col: 2 }]);
    board = await db.boards.get('board-1');
    expect(board!.completedLineIds ?? []).toContain('row_0');
    expect(board!.completedTasks).toBe(3);
  });

  it('removing a completed cell drops it from stats but other completions survive', async () => {
    await seedBoard('board-1');
    await seedCompletedTask('task-A');
    await seedCompletedTask('task-B');

    await seedPlacement('bt-A', 'board-1', 'task-A', 0, 0);
    await seedPlacement('bt-B', 'board-1', 'task-B', 0, 1);

    // Establish baseline via a real cascade (addBoardTaskToBoard triggers
    // derivation) — add a third, incomplete task, then remove it again to
    // avoid changing the count, purely to run one real derivation pass first.
    await seedTask('task-C');
    await addBoardTaskToBoard('board-1', 'task-C', 0, 2);
    let board = await db.boards.get('board-1');
    expect(board!.completedTasks).toBe(2);

    // Remove the COMPLETED cell (task-A at 0,0).
    await removeBoardTaskFromBoard('bt-A');

    board = await db.boards.get('board-1');
    expect(board!.completedTasks).toBe(1); // only task-B remains complete
    const btA = await db.boardTasks.get('bt-A');
    expect(btA!.isDeleted).toBe(true);
  });

  it('center-square type toggle: NONE -> FREE adds the auto-fill cell; FREE -> NONE removes it; unrelated completions are untouched', async () => {
    await seedBoard('board-1', { boardSize: 3, centerSquareType: CenterSquareType.NONE });
    await seedCompletedTask('task-A');
    await seedPlacement('bt-A', 'board-1', 'task-A', 0, 0);
    // Center (1,1) is left unoccupied.

    await updateBoardAndCascade('board-1', {
      name: 'Board board-1',
      centerSquareType: CenterSquareType.FREE,
      timeframe: Timeframe.WEEKLY,
    } as UpdateActiveBoardPatch);

    let board = await db.boards.get('board-1');
    // task-A + the FREE center auto-fill.
    expect(board!.completedTasks).toBe(2);

    await updateBoardAndCascade('board-1', {
      name: 'Board board-1',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.WEEKLY,
    } as UpdateActiveBoardPatch);

    board = await db.boards.get('board-1');
    // Auto-fill withdrawn; task-A's own completion is untouched.
    expect(board!.completedTasks).toBe(1);
  });

  it('achievement cells (cross-board watchers) are unaffected by an unrelated metadata edit on their own board', async () => {
    // Board A is the WATCHED board — already greenlogged.
    await seedBoard('board-A', {
      status: BoardStatus.COMPLETED,
      completedTasks: 9,
      linesCompleted: 8,
      completedAt: IN_WINDOW,
    });

    // Board B places an ACHIEVEMENT task watching board A's greenlog.
    await seedBoard('board-B');
    await seedTask('task-watch', {
      type: TaskType.ACHIEVEMENT,
      referencedBoardId: 'board-A',
      achievementTrigger: AchievementTrigger.GREENLOG,
    });
    await seedPlacement('bt-watch', 'board-B', 'task-watch', 0, 0);

    // Establish the achievement cell's state via a real cascade first.
    await seedTask('task-filler');
    await addBoardTaskToBoard('board-B', 'task-filler', 0, 1);
    let boardB = await db.boards.get('board-B');
    // The achievement cell reads complete (board A is greenlogged) + the
    // filler cell is incomplete.
    expect(boardB!.completedTasks).toBe(1);

    // A completely unrelated metadata-only edit on board B (rename) must
    // not change the achievement cell's resolution — it depends only on
    // board A's state.
    await updateBoardAndCascade('board-B', {
      name: 'Renamed board B',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.WEEKLY,
    });

    boardB = await db.boards.get('board-B');
    expect(boardB!.name).toBe('Renamed board B');
    expect(boardB!.completedTasks).toBe(1);
  });
});
