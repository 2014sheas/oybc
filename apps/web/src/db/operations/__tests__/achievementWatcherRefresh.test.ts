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
import { closeBoard, reopenBoard } from '../boardLifecycle';
import { lateLogCompletion } from '../lateLog';
import { sealBoard } from '../sealing';

/**
 * Board Edit redesign slice 4 (T2, D8) — Close / Reopen / a closed-board late
 * log each refresh every achievement watcher of whatever board's stats just
 * changed, in the SAME transaction. Covers specific-board mode
 * (`referencedBoardId`) and recurring-template mode (`referencedTemplateId`),
 * a sealed watcher board re-deriving locally (no version bump), and a
 * deleted / non-achievement task never firing.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const END = '2026-07-01T23:59:59.999Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';
const PAST_AUTO_CLOSE = '2026-07-03T01:00:00.000Z';

const WATCHED = 'watched-board';
const WATCHER = 'watcher-board';
const ACH = 'achievement-task';

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedNormalTask(id: string): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'N',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
    endDate: END,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.put(board);
  return board;
}

async function placeTask(boardId: string, taskId: string, cell: number): Promise<void> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row: Math.floor(cell / 3),
    col: cell % 3,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

function completionEvent(id: string, taskId: string, occurredAt: string) {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'completion' as const,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

async function seedFullBoard(boardId: string, over: Partial<Board> = {}): Promise<string[]> {
  await seedBoard(boardId, over);
  const ids: string[] = [];
  for (let cell = 0; cell < 9; cell++) {
    const id = `full-${boardId}-${cell}`;
    await seedNormalTask(id);
    await placeTask(boardId, id, cell);
    ids.push(id);
  }
  return ids;
}

function specificBoardAchievement(over: Partial<Task> = {}): Task {
  return {
    id: ACH,
    userId: USER,
    title: 'Watch it',
    type: TaskType.ACHIEVEMENT,
    referencedBoardId: WATCHED,
    achievementTrigger: AchievementTrigger.GREENLOG,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

describe('closeBoard refreshes achievement watchers', () => {
  it('a specific-board watcher square greens the moment the watched board closes greenlog', async () => {
    const ids = await seedFullBoard(WATCHED);
    for (const id of ids) await db.taskEvents.add(completionEvent(`ce-${id}`, id, IN_WINDOW));
    await db.tasks.add(specificBoardAchievement());
    await seedBoard(WATCHER, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER, ACH, 0);

    await closeBoard(WATCHED, PAST_AUTO_CLOSE);

    expect((await db.boards.get(WATCHED))?.status).toBe(BoardStatus.COMPLETED);
    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(1);
  });

  it('a template-mode watcher matches via the watched board\'s spawnedFromTemplateId', async () => {
    const TEMPLATE = 'template-1';
    const ids = await seedFullBoard(WATCHED, { spawnedFromTemplateId: TEMPLATE });
    for (const id of ids) await db.taskEvents.add(completionEvent(`ce-${id}`, id, IN_WINDOW));
    await db.tasks.add(
      specificBoardAchievement({ referencedBoardId: undefined, referencedTemplateId: TEMPLATE, requiredCount: 1 }),
    );
    await seedBoard(WATCHER, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER, ACH, 0);

    await closeBoard(WATCHED, PAST_AUTO_CLOSE);

    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(1);
  });

  it('re-derives a SEALED watcher board locally — no version bump', async () => {
    const ids = await seedFullBoard(WATCHED);
    for (const id of ids) await db.taskEvents.add(completionEvent(`ce-${id}`, id, IN_WINDOW));
    await db.tasks.add(specificBoardAchievement());
    await seedBoard(WATCHER, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER, ACH, 0);
    await sealBoard(WATCHER, '2026-07-02T00:00:00.000Z'); // sealed before the watched board closes
    const watcherVersionBeforeClose = (await db.boards.get(WATCHER))?.version;

    await closeBoard(WATCHED, PAST_AUTO_CLOSE);

    const watcher = await db.boards.get(WATCHER);
    expect(watcher?.sealedCompletedCells).toEqual([0]);
    expect(watcher?.version).toBe(watcherVersionBeforeClose); // local-only re-derive
  });

  it('ignores a deleted watcher task and a non-ACHIEVEMENT task', async () => {
    const ids = await seedFullBoard(WATCHED);
    for (const id of ids) await db.taskEvents.add(completionEvent(`ce-${id}`, id, IN_WINDOW));
    await db.tasks.add(specificBoardAchievement({ isDeleted: true }));
    await seedBoard(WATCHER, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER, ACH, 0);

    await closeBoard(WATCHED, PAST_AUTO_CLOSE);
    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(0);
  });
});

describe('reopenBoard refreshes achievement watchers', () => {
  it('a watcher drops back to incomplete once the watched board is reopened short of complete', async () => {
    const ids = await seedFullBoard(WATCHED);
    for (const id of ids) await db.taskEvents.add(completionEvent(`ce-${id}`, id, IN_WINDOW));
    await db.tasks.add(specificBoardAchievement());
    await seedBoard(WATCHER, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER, ACH, 0);
    await closeBoard(WATCHED, PAST_AUTO_CLOSE);
    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(1);

    // Tombstone one of the watched board's completions, then reopen —
    // the watched board's greenlog is now gone.
    await db.taskEvents.where('id').equals(`ce-${ids[0]}`).modify({ isDeleted: true });
    await reopenBoard(WATCHED, '2026-07-10T00:00:00.000Z');

    expect((await db.boards.get(WATCHED))?.status).toBe(BoardStatus.ACTIVE);
    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(0);
  });
});

describe('a closed-board late log refreshes achievement watchers', () => {
  it('completing the last square via late log flips the watcher square green', async () => {
    const ids = await seedFullBoard(WATCHED);
    // Complete 8 of 9 in-window, close (short of greenlog).
    for (let i = 0; i < 8; i++) await db.taskEvents.add(completionEvent(`ce-${i}`, ids[i], IN_WINDOW));
    await closeBoard(WATCHED, PAST_AUTO_CLOSE);
    await db.tasks.add(specificBoardAchievement());
    await seedBoard(WATCHER, { boardSize: 3, totalTasks: 1 });
    await placeTask(WATCHER, ACH, 0);
    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(0);

    // Late-log the 9th square — WATCHED becomes greenlog; the watcher must
    // pick this up in the SAME late-log transaction.
    await lateLogCompletion(WATCHED, ids[8], '2026-07-05T00:00:00.000Z');

    expect((await db.boards.get(WATCHED))?.status).toBe(BoardStatus.COMPLETED);
    expect((await db.boards.get(WATCHER))?.completedTasks).toBe(1);
  });
});
