import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  isBoardClosingOut,
  isBoardSealable,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  tombstoneWindowCompletions,
  tombstoneLatestCompletion,
  isUncompleteBlockedBySeal,
} from '../taskEvents';

/**
 * Windowed Completion PR C slice 2 — sealed-window tombstone immunity
 * (docs/WINDOWED_COMPLETION.md §Write paths → "Sealed-window immunity" /
 * Decision 9) + the closing-out prompt eligibility + edit-gating predicate.
 *
 * An event whose `occurredAt` falls inside `[startDate, sealedAt]` of a sealed
 * board that places the task can NEVER be tombstoned — history stays history.
 * The library un-complete affordance reads `isUncompleteBlockedBySeal` to
 * disable-with-explanation when a task is green only via such an event.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const END = '2026-07-02T00:00:00.000Z';
const SEALED_AT = '2026-07-02T06:00:00.000Z';
const IN_SEALED_WINDOW = '2026-07-01T12:00:00.000Z'; // inside [START, SEALED_AT]
const POST_SEAL = '2026-07-02T12:00:00.000Z'; // after SEALED_AT (overtime → tombstonable)

const TASK_A = '10000000-0000-4000-8000-000000000001';
const SEALED_BOARD = '20000000-0000-4000-8000-000000000001';
const LIVE_BOARD = '20000000-0000-4000-8000-000000000002';

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedNormalTask(id: string, isCompleted = true): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'N',
    type: TaskType.NORMAL,
    isCompleted,
    completedAt: isCompleted ? IN_SEALED_WINDOW : undefined,
    totalCompletions: isCompleted ? 1 : 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 3,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<void> {
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
}

async function placeTask(boardId: string, taskId: string, cell = 0): Promise<void> {
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
  };
  await db.boardTasks.add(bt);
}

function completionEvent(id: string, occurredAt: string, isDeleted = false): TaskEvent {
  return {
    id,
    userId: USER,
    taskId: TASK_A,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted,
  };
}

describe('tombstoneWindowCompletions — sealed-window immunity', () => {
  it('does NOT tombstone an event inside a sealed board window', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(SEALED_BOARD, { sealedAt: SEALED_AT });
    await placeTask(SEALED_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e-immune', IN_SEALED_WINDOW));

    // Un-complete over the whole lifetime window (windowStart = START).
    await tombstoneWindowCompletions(TASK_A, START, '2026-07-03T00:00:00.000Z');

    const ev = await db.taskEvents.get('e-immune');
    expect(ev?.isDeleted).toBe(false); // immune — history stays
    // The lifetime cache stays complete (the immune event keeps it green).
    expect((await db.tasks.get(TASK_A))?.isCompleted).toBe(true);
  });

  it('DOES tombstone a non-immune (post-seal overtime) event while sparing the immune one', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(SEALED_BOARD, { sealedAt: SEALED_AT });
    await placeTask(SEALED_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e-immune', IN_SEALED_WINDOW));
    await db.taskEvents.add(completionEvent('e-open', POST_SEAL)); // outside the sealed window

    await tombstoneWindowCompletions(TASK_A, START, '2026-07-03T00:00:00.000Z');

    expect((await db.taskEvents.get('e-immune'))?.isDeleted).toBe(false);
    expect((await db.taskEvents.get('e-open'))?.isDeleted).toBe(true);
  });

  it('tombstones normally when the task is on no sealed board', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(LIVE_BOARD); // not sealed
    await placeTask(LIVE_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e1', IN_SEALED_WINDOW));

    await tombstoneWindowCompletions(TASK_A, START, '2026-07-03T00:00:00.000Z');

    expect((await db.taskEvents.get('e1'))?.isDeleted).toBe(true);
    expect((await db.tasks.get(TASK_A))?.isCompleted).toBe(false);
  });
});

describe('tombstoneLatestCompletion — sealed-window immunity', () => {
  it('picks the latest NON-immune completion, leaving the immune one intact', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(SEALED_BOARD, { sealedAt: SEALED_AT });
    await placeTask(SEALED_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e-immune', IN_SEALED_WINDOW));
    await db.taskEvents.add(completionEvent('e-open', POST_SEAL));

    await tombstoneLatestCompletion(TASK_A, '2026-07-03T00:00:00.000Z');

    expect((await db.taskEvents.get('e-immune'))?.isDeleted).toBe(false);
    expect((await db.taskEvents.get('e-open'))?.isDeleted).toBe(true);
  });

  it('is inert when the only live completion is sealed-immune', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(SEALED_BOARD, { sealedAt: SEALED_AT });
    await placeTask(SEALED_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e-immune', IN_SEALED_WINDOW));

    await tombstoneLatestCompletion(TASK_A, '2026-07-03T00:00:00.000Z');

    expect((await db.taskEvents.get('e-immune'))?.isDeleted).toBe(false);
    // Cache recomputes from the (still-live) immune event → stays complete.
    expect((await db.tasks.get(TASK_A))?.isCompleted).toBe(true);
  });
});

describe('isUncompleteBlockedBySeal', () => {
  it('true when the task is green only via a sealed-immune completion', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(SEALED_BOARD, { sealedAt: SEALED_AT });
    await placeTask(SEALED_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e-immune', IN_SEALED_WINDOW));

    expect(await isUncompleteBlockedBySeal(TASK_A)).toBe(true);
  });

  it('false when a non-immune completion also exists (un-complete is effective)', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(SEALED_BOARD, { sealedAt: SEALED_AT });
    await placeTask(SEALED_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e-immune', IN_SEALED_WINDOW));
    await db.taskEvents.add(completionEvent('e-open', POST_SEAL));

    expect(await isUncompleteBlockedBySeal(TASK_A)).toBe(false);
  });

  it('false when there are no sealed boards at all', async () => {
    await seedNormalTask(TASK_A);
    await seedBoard(LIVE_BOARD);
    await placeTask(LIVE_BOARD, TASK_A);
    await db.taskEvents.add(completionEvent('e1', IN_SEALED_WINDOW));

    expect(await isUncompleteBlockedBySeal(TASK_A)).toBe(false);
  });
});

describe('closing-out prompt eligibility + edit gating (shared predicates)', () => {
  const nowMs = new Date('2026-07-02T03:00:00.000Z').getTime(); // past endDate, before backstop

  function board(over: Partial<Board> = {}): Board {
    return {
      id: 'b',
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
  }

  it('an expired, unsealed, non-draft board is in the closing-out set', () => {
    expect(isBoardClosingOut(board(), nowMs)).toBe(true);
  });

  it('a sealed board is neither closing-out nor sealable (edit-gating parity)', () => {
    const sealed = board({ sealedAt: SEALED_AT });
    expect(isBoardClosingOut(sealed, nowMs)).toBe(false);
    expect(isBoardSealable(sealed)).toBe(false);
  });

  it('a draft board never prompts to seal', () => {
    expect(isBoardClosingOut(board({ status: BoardStatus.DRAFT }), nowMs)).toBe(false);
  });
});
