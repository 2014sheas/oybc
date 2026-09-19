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
import { fetchBoardSourceSupply, resolveBoardSourceSupply } from '../boardSources';

/**
 * §Member rules (docs/BOARD_SOURCES.md, B3 — RC4/RC5): a pulled board's
 * supply now also reports each event-owning COUNTING member's windowed count
 * and the board's OWN window, so the wizard can seed a one-off board's
 * remaining targets (`remainingTarget(goal, windowCount)`) and pro-rate an
 * auto target without a second board read.
 *
 * The count is the same windowed resolution that decides "done": events
 * BEFORE the source board's `startDate` belong to an earlier window and must
 * not count.
 */

const USER = 'user-1';
const WINDOW_START = '2026-09-14T00:00:00.000';
const WINDOW_END = '2026-09-20T23:59:59.999';

function makeBoard(over: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: USER,
    name: 'Week of Sep 14',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: WINDOW_START,
    endDate: WINDOW_END,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
}

function makeTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function increment(id: string, taskId: string, occurredAt: string, delta = 1): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  } as TaskEvent;
}

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.tasks.clear();
  await db.taskEvents.clear();
});

describe('resolveBoardSourceSupply — windowCountByTaskId (RC4)', () => {
  const counter = makeTask('c1', { type: TaskType.COUNTING, maxCount: 10, unit: 'reps' });
  const plain = makeTask('n1');
  const rows = [
    { taskId: 'c1', row: 0, col: 0 },
    { taskId: 'n1', row: 0, col: 1 },
  ];

  it('counts only increment events INSIDE the board’s window', () => {
    const info = resolveBoardSourceSupply(
      makeBoard(),
      rows,
      { c1: counter, n1: plain },
      {
        c1: [
          increment('e1', 'c1', '2026-09-13T12:00:00.000', 5), // previous window
          increment('e2', 'c1', '2026-09-15T12:00:00.000', 2),
          increment('e3', 'c1', '2026-09-16T12:00:00.000', 1),
        ],
      },
    );
    expect(info.windowCountByTaskId).toEqual({ c1: 3 });
  });

  it('sums deltas (never the raw event count) and ignores tombstoned events', () => {
    const info = resolveBoardSourceSupply(
      makeBoard(),
      rows,
      { c1: counter, n1: plain },
      {
        c1: [
          increment('e1', 'c1', '2026-09-15T12:00:00.000', 4),
          { ...increment('e2', 'c1', '2026-09-16T12:00:00.000', 3), isDeleted: true },
        ],
      },
    );
    expect(info.windowCountByTaskId.c1).toBe(4);
  });

  it('records 0 for a counting member with no progress, and nothing for a non-counter', () => {
    const info = resolveBoardSourceSupply(makeBoard(), rows, { c1: counter, n1: plain }, {});
    expect(info.windowCountByTaskId).toEqual({ c1: 0 });
  });

  it('leaves out derived counters (not event-owning — they read their own cache)', () => {
    const derived = makeTask('d1', {
      type: TaskType.COUNTING,
      maxCount: 4,
      sharedCounterId: 'root-1',
      startDate: WINDOW_START,
    });
    const info = resolveBoardSourceSupply(
      makeBoard(),
      [{ taskId: 'd1', row: 0, col: 0 }],
      { d1: derived },
      {},
    );
    expect(info.windowCountByTaskId).toEqual({});
  });
});

describe('resolveBoardSourceSupply — sourceWindow (RC5)', () => {
  it('reports the board’s own timeframe + bounds', () => {
    const info = resolveBoardSourceSupply(makeBoard(), [], {}, {});
    expect(info.sourceWindow).toEqual({
      timeframe: Timeframe.WEEKLY,
      startDate: WINDOW_START,
      endDate: WINDOW_END,
    });
  });

  it('normalises a missing endDate (an ongoing board) to null', () => {
    const info = resolveBoardSourceSupply(
      makeBoard({ timeframe: Timeframe.INDEFINITE, endDate: undefined }),
      [],
      {},
      {},
    );
    expect(info.sourceWindow).toEqual({
      timeframe: Timeframe.INDEFINITE,
      startDate: WINDOW_START,
      endDate: null,
    });
  });
});

describe('fetchBoardSourceSupply — the wizard’s read path carries both', () => {
  it('reads the counts + window straight out of Dexie', async () => {
    await db.boards.add(makeBoard());
    await db.tasks.add(makeTask('c1', { type: TaskType.COUNTING, maxCount: 10, unit: 'reps' }));
    await db.boardTasks.add({
      id: 'bt-1',
      boardId: 'board-1',
      taskId: 'c1',
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: WINDOW_START,
      updatedAt: WINDOW_START,
      version: 1,
      isDeleted: false,
    } as never);
    await db.taskEvents.add(increment('e1', 'c1', '2026-09-15T09:00:00.000', 6));
    await db.taskEvents.add(increment('e0', 'c1', '2026-09-01T09:00:00.000', 99));

    const info = await fetchBoardSourceSupply('board-1');

    expect(info).not.toBeNull();
    expect(info?.windowCountByTaskId).toEqual({ c1: 6 });
    expect(info?.sourceWindow.timeframe).toBe(Timeframe.WEEKLY);
    expect(info?.sourceWindow.startDate).toBe(WINDOW_START);
  });
});
