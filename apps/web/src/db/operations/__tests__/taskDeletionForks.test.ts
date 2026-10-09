import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  forkTaskId,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { computeTaskDeletionImpact, deleteTaskWithCascade } from '../tasks.deletion';

/**
 * Board-scoped task edits PR 1 (docs/BOARD_SCOPED_TASK_EDITS.md §3
 * "Deletion"): a fork is an independent row. Deleting the ORIGINAL must not
 * touch the fork, its placement or its events, and the impact preview must
 * not list the fork's board. Deleting the fork tombstones only its own
 * placement. iOS twin: `CascadeDeleteForkTests`.
 */

const USER = 'user-1';
const T0 = '2026-10-05T00:00:00.000Z';
const ORIG = '70000000-0000-4000-8000-000000000001';
const B1 = '70000000-0000-4000-8000-0000000000b1';
const B2 = '70000000-0000-4000-8000-0000000000b2';
const FORK = forkTaskId(B2, ORIG);

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Read',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function board(id: string): Board {
  return {
    id,
    userId: USER,
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: T0,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  } as Board;
}

function placement(id: string, boardId: string, taskId: string): BoardTask {
  return {
    id,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };
}

function completion(id: string, taskId: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt: '2026-10-06T09:00:00.000Z',
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };
}

async function seed(): Promise<void> {
  await db.boards.bulkAdd([board(B1), board(B2)]);
  await db.tasks.bulkAdd([
    task(ORIG),
    task(FORK, { forkedFromTaskId: ORIG, createdInWizard: true }),
  ]);
  await db.boardTasks.bulkAdd([placement('bt-orig', B1, ORIG), placement('bt-fork', B2, FORK)]);
  await db.taskEvents.bulkAdd([completion('ev-orig', ORIG), completion('ev-fork', FORK)]);
}

describe('deleteTaskWithCascade — forks are independent rows', () => {
  it('deleting the original leaves its fork, the fork placement and the fork events untouched', async () => {
    await seed();
    await deleteTaskWithCascade(ORIG);

    expect((await db.tasks.get(ORIG))?.isDeleted).toBe(true);
    expect((await db.boardTasks.get('bt-orig'))?.isDeleted).toBe(true);

    const fork = await db.tasks.get(FORK);
    expect(fork?.isDeleted).toBe(false);
    expect(fork?.version).toBe(1);
    expect(fork?.forkedFromTaskId).toBe(ORIG);
    const forkPlacement = await db.boardTasks.get('bt-fork');
    expect(forkPlacement?.isDeleted).toBe(false);
    expect(forkPlacement?.taskId).toBe(FORK);
    expect((await db.taskEvents.get('ev-fork'))?.isDeleted).toBe(false);
  });

  it("the impact preview lists only the original's own board", async () => {
    await seed();
    const impact = await computeTaskDeletionImpact(ORIG);
    expect(impact.boardTaskCount).toBe(1);
    expect(impact.affectedBoardIds).toEqual([B1]);
  });

  it('deleting the fork tombstones only its own placement; the original is untouched', async () => {
    await seed();
    await deleteTaskWithCascade(FORK);

    expect((await db.tasks.get(FORK))?.isDeleted).toBe(true);
    expect((await db.boardTasks.get('bt-fork'))?.isDeleted).toBe(true);
    expect((await db.tasks.get(ORIG))?.isDeleted).toBe(false);
    expect((await db.tasks.get(ORIG))?.version).toBe(1);
    expect((await db.boardTasks.get('bt-orig'))?.isDeleted).toBe(false);
  });
});
