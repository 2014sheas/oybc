import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  TaskType,
  findTemplatesPendingSpawn,
  getTimeframeBoundaries,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { repeatBoardAsRecurring } from '../repeatBoard';

/**
 * P6 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 7) — "Repeat this board…" write. Integration coverage for
 * `repeatBoardAsRecurring`: the multi-table transaction (template insert +
 * board back-stamp), not just `buildRepeatBoardTemplateInput` in isolation
 * (already unit-tested in `packages/shared/tests/algorithms/
 * recurringBoardTemplates.test.ts`).
 */

const USER_ID = 'user-1';
const NOW = '2026-05-07T00:00:00.000Z';

async function seedTask(id: string): Promise<Task> {
  const task: Task = {
    id,
    userId: USER_ID,
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
  return task;
}

function buildOneOffBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: USER_ID,
    name: 'Morning Routine',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: '2026-05-06T00:00:00.000', // Wednesday, in the Mon May 4 – Sun May 10 week
    endDate: '2026-05-06T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 9,
    completedTasks: 1, // auto-completed FREE center
    linesCompleted: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

async function seedBoardTask(
  boardId: string,
  taskId: string,
  row: number,
  col: number,
  overrides: Partial<BoardTask> = {},
): Promise<void> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${row}-${col}`,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boardTasks.add(bt);
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.recurringBoardTemplates.clear();
  await db.syncQueue.clear();
});

describe('repeatBoardAsRecurring', () => {
  it('mints a template whose manualTaskIds match the board\'s live placed tasks, and back-stamps the board', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    const taskIds = ['t0', 't1', 't2', 't3', 't4', 't5', 't6', 't7'];
    for (const id of taskIds) await seedTask(id);
    // 3x3 FREE center — 8 fillable cells, skip the center (row1,col1).
    let i = 0;
    for (let row = 0; row < 3; row++) {
      for (let col = 0; col < 3; col++) {
        if (row === 1 && col === 1) continue;
        await seedBoardTask(board.id, taskIds[i], row, col);
        i++;
      }
    }

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    expect(new Set(template.manualTaskIds)).toEqual(new Set(taskIds));
    expect(template.poolIds).toEqual([]);
    expect(template.removedTaskIds).toEqual([]);
    expect(template.isActive).toBe(true);
    expect(template.userId).toBe(USER_ID);
    expect(template.centerSquareType).toBe(CenterSquareType.FREE);
    expect(template.boardSize).toBe(3);

    const updatedBoard = await db.boards.get(board.id);
    expect(updatedBoard?.spawnedFromTemplateId).toBe(template.id);
    expect(updatedBoard?.version).toBe((board.version ?? 0) + 1);

    // Both writes queued for sync.
    const queued = await db.syncQueue.toArray();
    const entityTypes = queued.map((q) => q.entityType);
    expect(entityTypes).toContain('recurringBoardTemplates');
    expect(entityTypes).toContain('boards');
  });

  it('lastSpawnedWindowKey is keyed off the CHOSEN cadence, not board.timeframe (critical window-alignment vector)', async () => {
    // DAILY board dated a Wednesday (2026-05-06), repeated WEEKLY (Monday
    // week start) — the window key must be the week's Monday (May 4), NOT
    // the Wednesday the board itself is dated for.
    const board = buildOneOffBoard({ timeframe: Timeframe.DAILY, startDate: '2026-05-06T00:00:00.000' });
    await db.boards.add(board);
    await seedTask('only-task');
    await seedBoardTask(board.id, 'only-task', 0, 0);

    const template = await repeatBoardAsRecurring(board, Timeframe.WEEKLY, USER_ID, 'monday');

    const expectedWeekWindow = getTimeframeBoundaries(
      Timeframe.WEEKLY,
      new Date('2026-05-06T00:00:00.000'),
      'monday',
    );
    expect(expectedWeekWindow.startDate).not.toBe(board.startDate);
    expect(template.lastSpawnedWindowKey).toBe(expectedWeekWindow.startDate);
    expect(template.timeframe).toBe(Timeframe.WEEKLY);
  });

  it('findTemplatesPendingSpawn does not flag the new template as pending for the window it was just written against (no immediate duplicate spawn)', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('solo-task');
    await seedBoardTask(board.id, 'solo-task', 0, 0);

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    // "Now" = the same reference date the board's startDate represents —
    // the window `findTemplatesPendingSpawn` would check on the very next
    // Boards-tab open.
    const referenceNow = new Date('2026-05-06T09:00:00.000');
    const allBoards = await db.boards.toArray();
    const pending = findTemplatesPendingSpawn([template], allBoards, 'monday', referenceNow);
    expect(pending).toHaveLength(0);
  });

  it('does not touch isCore, status, or other board fields', async () => {
    const board = buildOneOffBoard({ isCore: false, status: BoardStatus.ACTIVE, name: 'Keep My Name' });
    await db.boards.add(board);
    await seedTask('x');
    await seedBoardTask(board.id, 'x', 0, 0);

    await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    const updatedBoard = await db.boards.get(board.id);
    expect(updatedBoard?.isCore).toBe(false);
    expect(updatedBoard?.status).toBe(BoardStatus.ACTIVE);
    expect(updatedBoard?.name).toBe('Keep My Name');
  });

  it('dedupes a task placed on multiple cells (defensive) and preserves grid order', async () => {
    const board = buildOneOffBoard();
    await db.boards.add(board);
    await seedTask('dup-task');
    await seedTask('other-task');
    await seedBoardTask(board.id, 'dup-task', 0, 0);
    await seedBoardTask(board.id, 'other-task', 0, 1);
    // Same task placed again elsewhere (shouldn't normally happen, but the
    // dedup must hold regardless).
    await seedBoardTask(board.id, 'dup-task', 0, 2, { id: 'bt-dup-2' });

    const template = await repeatBoardAsRecurring(board, Timeframe.DAILY, USER_ID, 'monday');

    expect(template.manualTaskIds).toEqual(['dup-task', 'other-task']);
  });
});
