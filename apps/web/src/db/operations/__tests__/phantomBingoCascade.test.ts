import { afterEach, describe, expect, it } from 'vitest';
import {
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
import { addBoardTaskToBoard } from '../boardTasks';
import { reDeriveActiveBoards } from '../sealing';

/**
 * Windowed Completion — phantom-bingo regression (edit/structure cascades).
 *
 * Root cause: the edit/structure cascades (`addBoardTaskToBoard`,
 * `removeBoardTaskFromBoard`, `reorderBoardTasks`, `updateBoardTaskAndCascade`,
 * `updateBoardAndCascade`) recomputed `board.completedLineIds` WITHOUT a window
 * context, so `computeBoardStatsUpdate` fell back to the lifetime
 * `Task.isCompleted` cache. A cell holding a task that is lifetime-complete but
 * has NO in-window completion event was counted into a bingo line while the grid
 * rendered it un-green — a phantom bingo. The fix threads a real window context
 * into every live cascade (and `reDeriveActiveBoards` self-heals stale rows).
 *
 * Fixture: a 3×3 board, center NONE (no FREE auto-fill), with row 0 holding
 *   - task-A @ (0,0): lifetime-complete (`isCompleted: true`) but NO in-window
 *     event (its only event predates the board's window) → windowed = grey.
 *   - task-B @ (0,1) and task-C @ (0,2): genuinely windowed-complete (a
 *     completion event inside the window).
 * Under the OLD lifetime path all three read complete → phantom `row_0`.
 * Under the windowed fix, task-A is grey → `row_0` must NOT be a bingo.
 */

const WINDOW_START = '2026-06-01T00:00:00.000Z';
const PRE_WINDOW = '2026-05-15T12:00:00.000Z'; // before the board window
const IN_WINDOW = '2026-06-02T12:00:00.000Z'; // inside the board window

async function seedTask(id: string, occurredAt: string | null): Promise<void> {
  const task: Task = {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    // Lifetime cache says COMPLETE for every task in this fixture — exactly the
    // stale bit the phantom-bingo bug read.
    isCompleted: true,
    completedAt: occurredAt ?? PRE_WINDOW,
    totalCompletions: 1,
    totalInstances: 1,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: occurredAt ?? PRE_WINDOW,
    version: 2,
    isDeleted: false,
  };
  await db.tasks.add(task);
  const event: TaskEvent = {
    id: `evt-${id}`,
    userId: 'user-1',
    taskId: id,
    kind: 'completion',
    occurredAt: occurredAt ?? PRE_WINDOW,
    createdAt: occurredAt ?? PRE_WINDOW,
    updatedAt: occurredAt ?? PRE_WINDOW,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
}

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Phantom board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: WINDOW_START,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedPlacement(id: string, taskId: string, row: number, col: number): Promise<void> {
  const bt: BoardTask = {
    id,
    boardId: 'board-1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
  };
  await db.boardTasks.add(bt);
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('Windowed Completion — phantom-bingo cascade regression', () => {
  it('addBoardTaskToBoard does NOT count a lifetime-only cell into a bingo line', async () => {
    await seedBoard();
    // A: lifetime-complete but its event predates the window → windowed grey.
    await seedTask('task-A', PRE_WINDOW);
    // B / C: genuinely windowed-complete.
    await seedTask('task-B', IN_WINDOW);
    await seedTask('task-C', IN_WINDOW);

    await seedPlacement('bt-A', 'task-A', 0, 0);
    await seedPlacement('bt-B', 'task-B', 0, 1);

    // Structure edit: place task-C at (0,2), completing row 0 IF the lifetime
    // cache is (wrongly) consulted for task-A.
    await addBoardTaskToBoard('board-1', 'task-C', 0, 2);

    const board = await db.boards.get('board-1');
    expect(board).toBeDefined();
    // The phantom line must NOT appear — task-A has no in-window event.
    expect(board!.completedLineIds ?? []).not.toContain('row_0');
    // Only the two windowed-complete squares count.
    expect(board!.completedTasks).toBe(2);
    expect(board!.linesCompleted).toBe(0);
  });

  it('reDeriveActiveBoards clears a pre-seeded phantom completedLineIds', async () => {
    // Board carries stale lifetime-derived state from the pre-fix cascade.
    await seedBoard({ completedLineIds: ['row_0'], linesCompleted: 1, completedTasks: 3, version: 5 });
    await seedTask('task-A', PRE_WINDOW); // lifetime-only
    await seedTask('task-B', IN_WINDOW);
    await seedTask('task-C', IN_WINDOW);
    await seedPlacement('bt-A', 'task-A', 0, 0);
    await seedPlacement('bt-B', 'task-B', 0, 1);
    await seedPlacement('bt-C', 'task-C', 0, 2);

    const healed = await reDeriveActiveBoards('user-1');
    expect(healed).toContain('board-1');

    const board = await db.boards.get('board-1');
    expect(board!.completedLineIds ?? []).not.toContain('row_0');
    expect(board!.linesCompleted).toBe(0);
    expect(board!.completedTasks).toBe(2);
    // Corrected write bumps version + enqueues a board sync entry.
    expect(board!.version).toBe(6);

    // Idempotent: a second pass is a no-op (already converged).
    const secondPass = await reDeriveActiveBoards('user-1');
    expect(secondPass).not.toContain('board-1');
  });
});
