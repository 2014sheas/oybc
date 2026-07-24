import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { persistWizardBoardRows, type PersistWizardBoardRowsInput } from '../wizardBoard';

/**
 * Item 2 (bingo-pipeline hardening) — wizard board creation bypassed
 * derivation: wizard persist / activation hand-init stats (`completedTasks:
 * 0`, etc.) instead of running the shared derivation pass, so a new board
 * placing an already-in-window-complete task (or with a FREE center) stored
 * wrong stats + synced a wrong CREATE until the next app-open self-heal. The
 * fix mirrors the recurring-spawn path (`recurringBoardSpawn.ts`): stored
 * stats are always derivation output, computed over the just-written
 * placements after the board row (and, for a fresh active board, the
 * activation) lands — in the same Dexie transaction.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';

function uuid(n: number): string {
  return `50000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedWindowedCompleteTask(id: string): Promise<Task> {
  const task: Task = {
    id,
    userId: USER,
    title: 'Already done this window',
    type: TaskType.NORMAL,
    isCompleted: false, // lifetime cache is stale/irrelevant — the event decides.
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
  const event: TaskEvent = {
    id: `${id}-ev`,
    userId: USER,
    taskId: id,
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
  return task;
}

function baseInput(
  over: Partial<PersistWizardBoardRowsInput> = {},
): PersistWizardBoardRowsInput {
  return {
    userId: USER,
    draftBoardId: null,
    isCore: false,
    status: 'active',
    boardFields: {
      name: 'Test board',
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
    },
    placement: new Array(9).fill(null),
    size: 3,
    centerType: CenterSquareType.NONE,
    pendingTasks: [],
    ...over,
  };
}

describe('persistWizardBoardRows — windowed derivation pass (item 2)', () => {
  it('fresh create + activate: a task already windowed-complete stores completedTasks=1, not a hand-init 0', async () => {
    const task = await seedWindowedCompleteTask(uuid(1));
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(baseInput({ placement }));

    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.ACTIVE);
    expect(board?.completedTasks).toBe(1);
    expect(board?.linesCompleted).toBe(0); // one cell alone is not a full line.
  });

  it('fresh create + activate: a FREE center auto-fills and counts toward completedTasks', async () => {
    // Odd board (3x3), FREE center, no task placed at the center cell (index 4).
    const boardId = await persistWizardBoardRows(
      baseInput({
        boardFields: {
          name: 'Free center board',
          boardSize: 3,
          timeframe: Timeframe.DAILY,
          startDate: START,
          centerSquareType: CenterSquareType.FREE,
          isRandomized: false,
        },
        centerType: CenterSquareType.FREE,
        placement: new Array(9).fill(null),
      }),
    );

    const board = await db.boards.get(boardId);
    expect(board?.completedTasks).toBe(1); // just the auto-filled FREE center.
  });

  it('does NOT stage an unactivated draft as complete — a draft-status persist skips activation and still derives correctly', async () => {
    const task = await seedWindowedCompleteTask(uuid(2));
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(
      baseInput({ status: 'draft', placement }),
    );

    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.DRAFT);
    // Derivation still ran (stored stats are always derivation output, never
    // a hand-init) even though the board never activated.
    expect(board?.completedTasks).toBe(1);
  });

  it('draft-resume activation path: saving an existing draft as active derives stats from its placements', async () => {
    // Simulate an existing DRAFT board (as if created by a prior wizard
    // session) with no placements yet.
    const draftId = uuid(3);
    const draftBoard: Board = {
      id: draftId,
      userId: USER,
      name: 'Resumed draft',
      status: BoardStatus.DRAFT,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
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
    };
    await db.boards.add(draftBoard);

    const task = await seedWindowedCompleteTask(uuid(4));
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(
      baseInput({ draftBoardId: draftId, status: 'active', placement }),
    );

    expect(boardId).toBe(draftId);
    const board = await db.boards.get(boardId);
    expect(board?.status).toBe(BoardStatus.ACTIVE);
    expect(board?.completedTasks).toBe(1);
  });

  it('a task with no in-window event does NOT count (no phantom completion from a stale lifetime cache)', async () => {
    // isCompleted=true lifetime cache, but no event in this fresh board's
    // window — must resolve incomplete (the windowed seam item 5 pins at the
    // kernel level; this proves the wizard-persist call site actually wires
    // a real windowContext rather than passing undefined/lifetime).
    const task: Task = {
      id: uuid(5),
      userId: USER,
      title: 'Stale lifetime-complete',
      type: TaskType.NORMAL,
      isCompleted: true,
      completedAt: '2020-01-01T00:00:00.000Z',
      totalCompletions: 1,
      totalInstances: 1,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(task);
    const placement = new Array(9).fill(null);
    placement[0] = task;

    const boardId = await persistWizardBoardRows(baseInput({ placement }));

    const board = await db.boards.get(boardId);
    expect(board?.completedTasks).toBe(0);
  });
});
