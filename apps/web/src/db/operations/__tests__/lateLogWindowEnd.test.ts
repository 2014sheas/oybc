import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  computeBoardGrid,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { handleTaskCompletion } from '../orchestration';
import { decrementSharedCounter, incrementSharedCounter } from '../tasks.sharedCounter';
import { toggleCompoundChildFallback } from '../tasks.crud';
import { buildWindowContext } from '../windowContext';
import { buildSquareWindowContext, compoundChildToggleDesired, taskToSquareState } from '../../adapters';

/**
 * 2026-09-24 amendment of WC Decision 1 (root-square end bound) — web wiring.
 *
 * A board's root squares evaluate events inside `[startDate, endDate]`. So a
 * log made from an ENDED-but-unsealed board's own play surface must be stamped
 * at that board's `endDate` (decision C2, `lateLogOccurredAt`) — otherwise it
 * would count for nothing on the board it was made from and bleed into the
 * next window's board instead. Undo on that board tombstones only its own
 * window's completions (C4). Shared-counter logs take an optional `boardId`
 * for the same clamp (C3); without one they stamp `now`.
 *
 * Fixture: yesterday's daily board A (ended, unsealed) and today's daily B,
 * both placing the same Task. Board dates are LOCAL-ISO (web convention);
 * event timestamps are UTC ISO — compared by parsed ms, never by string.
 */

const USER = 'user-1';
const A = 'board-a';
const B = 'board-b';
const A_START = '2026-09-22T00:00:00.000';
const A_END = '2026-09-22T23:59:59.999';
const B_START = '2026-09-23T00:00:00.000';
const B_END = '2026-09-23T23:59:59.999';
const NOW = new Date('2026-09-23T10:00:00.000'); // local; A has ended, B is open
const A_END_STAMP = new Date(A_END).toISOString();
const NOW_STAMP = NOW.toISOString();

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
});

afterEach(async () => {
  vi.useRealTimers();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedTask(id: string, over: Partial<Task> = {}): Promise<Task> {
  const task: Task = {
    id,
    userId: USER,
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.tasks.add(task);
  return task;
}

async function seedBoard(id: string, startDate: string, endDate: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate,
    endDate,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.add(board);
  return board;
}

async function place(boardId: string, taskId: string): Promise<BoardTask> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: '2026-09-01T00:00:00.000Z',
    updatedAt: '2026-09-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
  return bt;
}

async function seedEvent(id: string, taskId: string, occurredAt: string, over: Partial<TaskEvent> = {}): Promise<void> {
  await db.taskEvents.add({
    id,
    userId: USER,
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
    ...over,
  });
}

/** The kernel's per-cell resolution for `taskId` on `boardId` (what the play grid paints). */
async function cellFor(boardId: string, taskId: string) {
  const board = (await db.boards.get(boardId))!;
  const bts = (await db.boardTasks.where('boardId').equals(boardId).toArray()).filter((b) => !b.isDeleted);
  const taskById: Record<string, Task> = {};
  for (const t of await db.tasks.toArray()) taskById[t.id] = t;
  const { cells } = computeBoardGrid(board, bts, {}, taskById, await db.boards.toArray(), await buildWindowContext());
  return cells.find((c) => c.taskId === taskId)!;
}

/** The count the play cell displays for `taskId` on `boardId` (the adapters path). */
async function displayedCount(boardId: string, taskId: string): Promise<number> {
  const board = (await db.boards.get(boardId))!;
  const ctx = buildSquareWindowContext(await db.taskEvents.toArray(), board.startDate, board.endDate ?? null);
  return taskToSquareState((await db.tasks.get(taskId))!, undefined, undefined, undefined, ctx).currentCount;
}

async function liveEvents(taskId: string): Promise<TaskEvent[]> {
  return (await db.taskEvents.where('taskId').equals(taskId).toArray()).filter((e) => !e.isDeleted);
}

describe('late log on an ended-but-unsealed board (C2)', () => {
  it('a completion from the ended board is stamped at its endDate and counts there, not on the next window', async () => {
    await seedTask('t');
    await seedBoard(A, A_START, A_END);
    await seedBoard(B, B_START, B_END);
    const btA = await place(A, 't');
    await place(B, 't');

    await handleTaskCompletion(A, btA.id, { isCompleted: true });

    const [event] = await liveEvents('t');
    expect(event.occurredAt).toBe(A_END_STAMP);
    expect(event.boardId).toBe(A);
    expect((await cellFor(A, 't')).isCompleted).toBe(true);
    expect((await db.boards.get(A))!.completedTasks).toBe(1);
    expect((await cellFor(B, 't')).isCompleted).toBe(false);
    expect((await db.boards.get(B))!.completedTasks).toBe(0);
  });

  it('a completion from an OPEN board is stamped now (no clamp)', async () => {
    await seedTask('t');
    await seedBoard(B, B_START, B_END);
    const btB = await place(B, 't');
    await handleTaskCompletion(B, btB.id, { isCompleted: true });
    const [event] = await liveEvents('t');
    expect(event.occurredAt).toBe(NOW_STAMP);
  });

  it('a counting tap on the ended board computes its delta against [startDate, endDate] and stamps at endDate', async () => {
    await seedTask('k', { type: TaskType.COUNTING, maxCount: 5, action: 'Do', unit: 'reps' });
    await seedBoard(A, A_START, A_END);
    await seedBoard(B, B_START, B_END);
    const btA = await place(A, 'k');
    await place(B, 'k');
    // +3 inside A's window, +2 today (B's window).
    await seedEvent('k-a', 'k', new Date('2026-09-22T09:00:00.000').toISOString(), { kind: 'increment', delta: 3 });
    await seedEvent('k-b', 'k', new Date('2026-09-23T08:00:00.000').toISOString(), { kind: 'increment', delta: 2 });

    // The A cell reads 3; the user taps +1 → desired windowed count 4.
    await handleTaskCompletion(A, btA.id, { currentCount: 4 });

    const appended = (await liveEvents('k')).filter((e) => e.id !== 'k-a' && e.id !== 'k-b');
    expect(appended).toHaveLength(1);
    expect(appended[0].delta).toBe(1); // not -1 (which an unbounded 5 would give)
    expect(appended[0].occurredAt).toBe(A_END_STAMP);
    expect(await displayedCount(A, 'k')).toBe(4);
    expect(await displayedCount(B, 'k')).toBe(2);
  });
});

describe('sealed board (play locked)', () => {
  it('handleTaskCompletion on a sealed board is a no-op: no event appended, record untouched', async () => {
    await seedTask('t');
    await seedBoard(A, A_START, A_END, { sealedAt: new Date('2026-09-23T06:00:00.000').toISOString(), sealedCompletedCells: [] });
    const btA = await place(A, 't');
    await handleTaskCompletion(A, btA.id, { isCompleted: true });
    // No event lands in the sealed window (it would be seal-immune forever).
    expect(await db.taskEvents.count()).toBe(0);
    const sealed = (await db.boards.get(A))!;
    expect(sealed.sealedCompletedCells).toEqual([]);
    expect(sealed.completedTasks).toBe(0);
    expect(sealed.version).toBe(1); // the cascade skips sealed boards
  });
});

describe('undo on an ended board is window-bounded (C4)', () => {
  it('tombstones only the completions inside [startDate, endDate]', async () => {
    await seedTask('t');
    await seedBoard(A, A_START, A_END);
    await seedBoard(B, B_START, B_END);
    const btA = await place(A, 't');
    await place(B, 't');
    await seedEvent('in-a', 't', new Date('2026-09-22T09:00:00.000').toISOString(), { boardId: A });
    await seedEvent('in-b', 't', new Date('2026-09-23T08:00:00.000').toISOString(), { boardId: B });

    await handleTaskCompletion(A, btA.id, { isCompleted: false });

    expect((await db.taskEvents.get('in-a'))!.isDeleted).toBe(true);
    expect((await db.taskEvents.get('in-b'))!.isDeleted).toBe(false);
    expect((await cellFor(A, 't')).isCompleted).toBe(false);
    expect((await cellFor(B, 't')).isCompleted).toBe(true);
  });
});

describe('shared-counter logs take an optional boardId for the late-log clamp (C3)', () => {
  const ROOT = 'root';

  async function seedRoot(): Promise<void> {
    await seedTask(ROOT, { type: TaskType.COUNTING, maxCount: 10, currentCount: 0, action: 'Read', unit: 'pages' });
  }

  it('increment with the ended board stamps at its endDate; without a board stamps now', async () => {
    await seedRoot();
    await seedBoard(A, A_START, A_END);
    await place(A, ROOT);

    await incrementSharedCounter(ROOT, 2, A);
    await incrementSharedCounter(ROOT, 1);

    const events = await liveEvents(ROOT);
    expect(events.find((e) => e.delta === 2)!.occurredAt).toBe(A_END_STAMP);
    expect(events.find((e) => e.delta === 1)!.occurredAt).toBe(NOW_STAMP);
    expect(await displayedCount(A, ROOT)).toBe(2);
  });

  it('increment with an OPEN board stamps now', async () => {
    await seedRoot();
    await seedBoard(B, B_START, B_END);
    await incrementSharedCounter(ROOT, 2, B);
    expect((await liveEvents(ROOT))[0].occurredAt).toBe(NOW_STAMP);
  });

  it('decrement with the ended board stamps at its endDate', async () => {
    await seedRoot();
    await seedBoard(A, A_START, A_END);
    await incrementSharedCounter(ROOT, 3, A);
    await decrementSharedCounter(ROOT, 1, A);
    const dec = (await liveEvents(ROOT)).find((e) => (e.delta ?? 0) < 0)!;
    expect(dec.occurredAt).toBe(A_END_STAMP);
  });

  it('a late log re-derives the ended board through its FROZEN window-stamped row (cascade reach)', async () => {
    await seedRoot();
    await seedBoard(A, A_START, A_END);
    // Window-stamped derived counter minted for A (target 2) — frozen now that A ended.
    await seedTask('derived-a', {
      type: TaskType.COUNTING,
      maxCount: 2,
      currentCount: 0,
      sharedCounterId: ROOT,
      baseline: 0,
      startDate: A_START,
      endDate: A_END,
      createdInWizard: true,
    });
    await place(A, 'derived-a');

    await incrementSharedCounter(ROOT, 2, A);

    expect((await cellFor(A, 'derived-a')).isCompleted).toBe(true);
    // Stored stats follow: the frozen row is cascaded (never written).
    expect((await db.boards.get(A))!.completedTasks).toBe(1);
    expect((await db.tasks.get('derived-a'))!.version).toBe(1);
  });
});

describe('board-context compound-child toggle (fallback: child not placed on the board)', () => {
  /** Board A hosts compound P = AND(c); `c` is NOT placed on A. Returns the ctx A's sheet paints with. */
  async function seedCompoundOnA() {
    await seedTask('c');
    await seedTask('p', { type: TaskType.COMPOUND, operator: OperatorType.AND });
    await db.compoundChildren.add({
      id: 'link-c',
      compoundTaskId: 'p',
      childTaskId: 'c',
      childIndex: 0,
      createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    });
    await seedBoard(A, A_START, A_END);
    await seedBoard(B, B_START, B_END);
    await place(A, 'p');
    await place(B, 'c');
  }

  async function desiredOnA(): Promise<boolean> {
    const taskMap: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) taskMap[t.id] = t;
    const cb = { p: await db.compoundChildren.toArray() };
    const ctx = buildSquareWindowContext(await db.taskEvents.toArray(), A_START, A_END);
    return compoundChildToggleDesired(taskMap['c'], taskMap, cb, ctx);
  }

  it('child completed today on B shows incomplete on A → the tap completes it at A.endDate and keeps B\'s completion', async () => {
    await seedCompoundOnA();
    await seedEvent('today-b', 'c', new Date('2026-09-23T08:00:00.000').toISOString(), { boardId: B });
    await db.tasks.update('c', { isCompleted: true }); // lifetime latch (from B)

    const desired = await desiredOnA();
    expect(desired).toBe(true); // the sheet paints it incomplete on A
    await toggleCompoundChildFallback('c', desired, A_START, A_END, A);

    expect((await db.taskEvents.get('today-b'))!.isDeleted).toBe(false);
    const appended = (await liveEvents('c')).filter((e) => e.id !== 'today-b');
    expect(appended).toHaveLength(1);
    expect(appended[0].occurredAt).toBe(A_END_STAMP);
    expect((await cellFor(A, 'p')).isCompleted).toBe(true);
    expect((await cellFor(B, 'c')).isCompleted).toBe(true);
  });

  it('un-complete from A tombstones only A\'s window', async () => {
    await seedCompoundOnA();
    await seedEvent('in-a', 'c', new Date('2026-09-22T09:00:00.000').toISOString(), { boardId: A });
    await seedEvent('today-b', 'c', new Date('2026-09-23T08:00:00.000').toISOString(), { boardId: B });

    const desired = await desiredOnA();
    expect(desired).toBe(false);
    await toggleCompoundChildFallback('c', desired, A_START, A_END, A);

    expect((await db.taskEvents.get('in-a'))!.isDeleted).toBe(true);
    expect((await db.taskEvents.get('today-b'))!.isDeleted).toBe(false);
  });

  it('is a no-op on a sealed board', async () => {
    await seedCompoundOnA();
    await db.boards.update(A, { sealedAt: new Date('2026-09-23T06:00:00.000').toISOString() });
    await toggleCompoundChildFallback('c', true, A_START, A_END, A);
    expect(await db.taskEvents.count()).toBe(0);
  });
});
