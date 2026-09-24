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
} from '@oybc/shared';
import { db } from '../../internal';
import { checkAchievementRetargetCycle } from '../tasks.crud';

/**
 * `checkAchievementRetargetCycle` renders the cycle path as board NAMES,
 * healed through `boardDisplayName` so a frozen legacy "Today" core board
 * reads as its window (CLAUDE.md board-naming rule, #482). iOS twin:
 * `AppDatabaseTaskEditTests` (same fixture shape and ids).
 *
 * Fixture: achievement X (watching A) sits on B, so B → A. Achievement T
 * sits on A. Re-targeting T at B closes A → B → A; at C it doesn't.
 */

const USER = 'user-1';
const TS = '2026-06-01T00:00:00.000';
const BOARD_A = 'aaaaaaaa-0000-4000-8000-000000000001';
const BOARD_B = 'bbbbbbbb-0000-4000-8000-000000000002';
const BOARD_C = 'cccccccc-0000-4000-8000-000000000003';

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
});

function board(id: string, name: string, over: Partial<Board> = {}): Board {
  return {
    id,
    userId: USER,
    name,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: TS,
    endDate: '2026-06-30T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function achievement(id: string, referencedBoardId: string): Task {
  return {
    id,
    userId: USER,
    title: `Task ${id}`,
    type: TaskType.ACHIEVEMENT,
    referencedBoardId,
    achievementTrigger: AchievementTrigger.BINGO,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    isDeleted: false,
  };
}

function placement(boardId: string, taskId: string): BoardTask {
  return {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    isDeleted: false,
  };
}

async function seedCycleFixture(): Promise<void> {
  await db.boards.bulkAdd([
    board(BOARD_A, 'Alpha Monthly'),
    // Frozen legacy core-board name: must render healed, never as "Today".
    board(BOARD_B, 'Today', {
      timeframe: Timeframe.DAILY,
      startDate: '2026-03-15T00:00:00.000',
      endDate: '2026-03-15T23:59:59.999',
      isCore: true,
    }),
    board(BOARD_C, 'Charlie Daily'),
  ]);
  await db.tasks.bulkAdd([achievement('x', BOARD_A), achievement('t', BOARD_C)]);
  await db.boardTasks.bulkAdd([placement(BOARD_B, 'x'), placement(BOARD_A, 't')]);
}

describe('checkAchievementRetargetCycle', () => {
  it('names the cycle path with healed board display names, never raw ids or the frozen "Today"', async () => {
    await seedCycleFixture();

    const message = await checkAchievementRetargetCycle('t', { referencedBoardId: BOARD_B });

    expect(message).not.toBeNull();
    expect(message).toMatch(/^This reference would create a cycle: /);
    expect(message).toContain('Alpha Monthly');
    expect(message).toContain('Mar 15, 2026');
    expect(message).not.toContain('Today');
    expect(message).not.toContain(BOARD_A);
    expect(message).not.toContain(BOARD_B);
  });

  it('returns null for a non-cycling retarget', async () => {
    await seedCycleFixture();

    expect(await checkAchievementRetargetCycle('t', { referencedBoardId: BOARD_C })).toBeNull();
  });
});
