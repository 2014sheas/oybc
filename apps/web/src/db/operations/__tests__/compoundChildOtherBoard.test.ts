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
import { toggleTaskCompletionAndCascade } from '../tasks';

/**
 * F2 regression — compound-child toggle for a child placed only on ANOTHER
 * board.
 *
 * `BoardPlaySurface`'s compound-detail sheet lets the user toggle a compound's
 * child even when that child is placed on a DIFFERENT board than the one being
 * played. The old web routing sent the other-board `BoardTask` into
 * `handleTaskCompletion(currentBoardId, otherBoardBt.id, …)`, whose hard guard
 * (`targetBt.boardId !== boardId`) throws — surfacing "Something went wrong"
 * and applying no change (iOS, which routes through a board-agnostic cascade,
 * worked fine). The fix routes the not-on-current-board case through
 * `toggleTaskCompletionAndCascade(childTaskId)` instead.
 *
 * This test locks the two facts the hook's routing decision depends on:
 *   (a) `handleTaskCompletion` with an other-board BoardTask id THROWS (the
 *       misroute the fix must avoid), and
 *   (b) `toggleTaskCompletionAndCascade(childTaskId)` — the fix's route —
 *       completes the child without throwing.
 * The hook's routing choice itself lives in React (`useBoardPlay`) and is not
 * exercised by this node-only harness — see the report's test-gap note.
 */

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-a',
    userId: 'user-1',
    name: 'Current board',
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

async function seedTask(overrides: Partial<Task> = {}): Promise<Task> {
  const task: Task = {
    id: 'child-task',
    userId: 'user-1',
    title: 'Compound child',
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

async function seedBoardTask(overrides: Partial<BoardTask> = {}): Promise<BoardTask> {
  const boardTask: BoardTask = {
    id: 'bt-on-board-b',
    boardId: 'board-b',
    taskId: 'child-task',
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boardTasks.add(boardTask);
  return boardTask;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('compound child placed only on another board (F2)', () => {
  it('handleTaskCompletion with the current board + an other-board BoardTask throws (the misroute the fix avoids)', async () => {
    await seedBoard({ id: 'board-a', name: 'Current board' });
    await seedBoard({ id: 'board-b', name: 'Other board' });
    await seedTask();
    await seedBoardTask(); // child placed on board-b only

    await expect(
      handleTaskCompletion('board-a', 'bt-on-board-b', { isCompleted: true }),
    ).rejects.toThrow(/does not belong to board board-a/);

    // No change applied by the rejected write.
    const task = await db.tasks.get('child-task');
    expect(task?.isCompleted).toBe(false);
  });

  it('toggleTaskCompletionAndCascade (the fix route) completes the other-board child without throwing', async () => {
    await seedBoard({ id: 'board-a', name: 'Current board' });
    await seedBoard({ id: 'board-b', name: 'Other board' });
    await seedTask({ isCompleted: false });
    await seedBoardTask();

    await expect(toggleTaskCompletionAndCascade('child-task')).resolves.toBeUndefined();

    const task = await db.tasks.get('child-task');
    expect(task?.isCompleted).toBe(true);
  });
});
