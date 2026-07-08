import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { handleTaskCompletion } from '../orchestration';

/**
 * Covers `handleTaskCompletion`'s `TaskCompletionResult.boardCompleted` vs
 * `isGreenlog` distinction (issue #272).
 *
 * `isGreenlog` is UNGATED — true whenever every square on the board is
 * currently complete, regardless of whether this write is what caused that.
 * `boardCompleted` is the actual not-complete→complete TRANSITION signal
 * (true only when the board's status flips ACTIVE → COMPLETED as a result of
 * this write) — the same semantics as iOS's `didAutoComplete` and as this
 * module's own `handleSharedCounterIncrement`-equivalent gating
 * (`wasActive && isNowCompleted && isGreenlogRaw`) in `useBoardPlay.ts`.
 *
 * `BoardPlaySurface.handleComplete` (via `useBoardPlay.ts`) must feed
 * `boardCompleted`, not `isGreenlog`, into `deriveFlashOutcome` — otherwise
 * completing an already-fully-complete board's square (e.g. overshooting a
 * counting task past its goal on a board that's already GREENLOG) re-fires
 * the GREENLOG celebration on every subsequent write, even though the board
 * never left COMPLETED status.
 */

async function seedTask(overrides: Partial<Task> = {}): Promise<Task> {
  const task: Task = {
    id: 'task-1',
    userId: 'user-1',
    title: 'Read a book',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.tasks.add(task);
  return task;
}

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Test board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: '2026-01-01T00:00:00.000Z',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedBoardTask(overrides: Partial<BoardTask> = {}): Promise<BoardTask> {
  const boardTask: BoardTask = {
    id: 'bt-1',
    boardId: 'board-1',
    taskId: 'task-1',
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    ...overrides,
  };
  await db.boardTasks.add(boardTask);
  return boardTask;
}

/** Fills the remaining 8 non-target cells of a 3x3 board with already-completed tasks. */
async function seedRemainingCompletedSquares(): Promise<void> {
  let n = 0;
  for (let row = 0; row < 3; row++) {
    for (let col = 0; col < 3; col++) {
      if (row === 0 && col === 0) continue; // reserved for the target BoardTask/Task
      n += 1;
      const taskId = `filler-task-${n}`;
      await db.tasks.add({
        id: taskId,
        userId: 'user-1',
        title: `Filler ${n}`,
        type: TaskType.NORMAL,
        isCompleted: true,
        completedAt: '2026-01-01T00:00:00.000Z',
        totalCompletions: 1,
        totalInstances: 1,
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-01-01T00:00:00.000Z',
        version: 1,
        isDeleted: false,
      });
      await db.boardTasks.add({
        id: `bt-filler-${n}`,
        boardId: 'board-1',
        taskId,
        row,
        col,
        isCenter: false,
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-01-01T00:00:00.000Z',
        version: 1,
      });
    }
  }
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.syncQueue.clear();
});

describe('handleTaskCompletion — boardCompleted vs isGreenlog gating (issue #272)', () => {
  it('completing the last square: isGreenlog AND boardCompleted are both true (real transition)', async () => {
    await seedTask({ isCompleted: false });
    await seedBoard({ status: BoardStatus.ACTIVE, completedTasks: 8 });
    await seedBoardTask();
    await seedRemainingCompletedSquares();

    const result = await handleTaskCompletion('board-1', 'bt-1', { isCompleted: true });

    expect(result.isGreenlog).toBe(true);
    expect(result.boardCompleted).toBe(true);

    const board = await db.boards.get('board-1');
    expect(board?.status).toBe(BoardStatus.COMPLETED);
  });

  it('re-saving an already-complete square on an already-COMPLETED board: isGreenlog stays true but boardCompleted is false (no transition)', async () => {
    // Simulates overshooting a counting task past its goal on a board
    // that's already fully GREENLOG — the task's completion state doesn't
    // change, but handleTaskCompletion still runs the full cascade.
    await seedTask({ isCompleted: true, completedAt: '2026-01-01T00:00:00.000Z' });
    await seedBoard({ status: BoardStatus.COMPLETED, completedTasks: 9, completedAt: '2026-01-01T00:00:00.000Z' });
    await seedBoardTask();
    await seedRemainingCompletedSquares();

    const result = await handleTaskCompletion('board-1', 'bt-1', { isCompleted: true });

    expect(result.isGreenlog).toBe(true);
    // The board never left COMPLETED — this write didn't cause the
    // transition, so `boardCompleted` (the signal fed to the flash ladder)
    // must be false even though the ungated `isGreenlog` is still true.
    expect(result.boardCompleted).toBe(false);

    const board = await db.boards.get('board-1');
    expect(board?.status).toBe(BoardStatus.COMPLETED);
  });

  it('completing a square that is not the last one: isGreenlog and boardCompleted are both false', async () => {
    await seedTask({ isCompleted: false });
    await seedBoard({ status: BoardStatus.ACTIVE, completedTasks: 0 });
    await seedBoardTask();
    // Only the target square + no filler squares completed.

    const result = await handleTaskCompletion('board-1', 'bt-1', { isCompleted: true });

    expect(result.isGreenlog).toBe(false);
    expect(result.boardCompleted).toBe(false);
  });
});
