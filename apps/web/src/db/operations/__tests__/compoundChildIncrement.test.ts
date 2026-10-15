import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  computeBoardGrid,
  type Board,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { incrementCompoundChildFallback } from '../tasks.crud';
import { buildWindowContext } from '../windowContext';
import { buildSquareWindowContext, compoundChildCount } from '../../adapters';

/**
 * `incrementCompoundChildFallback` — the compound sheet's stepper on a plain
 * COUNTING child not placed on the host board (iOS twin
 * `CompoundChildIncrementTests`). Board A = yesterday (ended, unsealed); the
 * child is placed nowhere, the AND-compound parent on A.
 */

const USER = 'user-1';
const A = 'board-a';
const A_START = '2026-09-22T00:00:00.000';
const A_END = '2026-09-22T23:59:59.999';
const NOW = new Date('2026-09-23T10:00:00.000');
const A_END_STAMP = new Date(A_END).toISOString();

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
    id, userId: USER, title: id, type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0, totalInstances: 1,
    createdAt: '2026-09-01T00:00:00.000Z', updatedAt: '2026-09-01T00:00:00.000Z', version: 1, isDeleted: false, ...over,
  };
  await db.tasks.add(task);
  return task;
}

async function seed(opts: { linked?: boolean; sealed?: boolean } = {}): Promise<void> {
  await seedTask('p', { type: TaskType.COMPOUND, operator: OperatorType.AND });
  if (opts.linked) {
    await seedTask('root', { type: TaskType.COUNTING, isCounter: true });
    await seedTask('c', { type: TaskType.COUNTING, maxCount: 2, sharedCounterId: 'root', baseline: 0 });
  } else {
    await seedTask('c', { type: TaskType.COUNTING, maxCount: 2 });
  }
  await db.compoundChildren.add({
    id: 'link-c', compoundTaskId: 'p', childTaskId: 'c', childIndex: 0,
    createdAt: '2026-09-01T00:00:00.000Z', updatedAt: '2026-09-01T00:00:00.000Z', version: 1, isDeleted: false,
  });
  const board: Board = {
    id: A, userId: USER, name: A, status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.DAILY,
    startDate: A_START, endDate: A_END, centerSquareType: CenterSquareType.NONE, isRandomized: false,
    totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
    createdAt: '2026-09-01T00:00:00.000Z', updatedAt: '2026-09-01T00:00:00.000Z', version: 1, isDeleted: false,
    ...(opts.sealed ? { sealedAt: new Date('2026-09-23T06:00:00.000').toISOString() } : {}),
  };
  await db.boards.add(board);
  await db.boardTasks.add({
    id: `bt-${A}-p`, boardId: A, taskId: 'p', row: 0, col: 0, isCenter: false,
    createdAt: '2026-09-01T00:00:00.000Z', updatedAt: '2026-09-01T00:00:00.000Z', version: 1, isDeleted: false,
  });
}

async function liveEvents(): Promise<TaskEvent[]> {
  return (await db.taskEvents.where('taskId').equals('c').toArray()).filter((e) => !e.isDeleted);
}

/** The kernel's per-cell resolution for the parent on A (what the play grid paints). */
async function parentCell() {
  const board = (await db.boards.get(A))!;
  const bts = (await db.boardTasks.where('boardId').equals(A).toArray()).filter((b) => !b.isDeleted);
  const taskById: Record<string, Task> = {};
  for (const t of await db.tasks.toArray()) taskById[t.id] = t;
  // The REAL children map — an AND over `{}` (no children) is vacuously complete.
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  for (const l of await db.compoundChildren.toArray()) (childrenByCompound[l.compoundTaskId] ??= []).push(l);
  const { cells } = computeBoardGrid(board, bts, childrenByCompound, taskById, await db.boards.toArray(), await buildWindowContext());
  return cells.find((c) => c.taskId === 'p')!;
}

/** The count the sheet's stepper shows for `c` on A (the adapters path). */
async function shownCount(): Promise<number> {
  const taskMap: Record<string, Task> = {};
  for (const t of await db.tasks.toArray()) taskMap[t.id] = t;
  const ctx = buildSquareWindowContext(await db.taskEvents.toArray(), A_START, A_END);
  return compoundChildCount(taskMap['c'], taskMap, ctx)!.current;
}

describe('incrementCompoundChildFallback', () => {
  it('steps append window-stamped increments; the AND parent completes at the goal and un-completes on a step back', async () => {
    await seed();
    await incrementCompoundChildFallback('c', 1, A_START, A_END, A);
    let events = await liveEvents();
    expect(events.map((e) => e.delta)).toEqual([1]);
    expect(events[0].boardId).toBe(A);
    expect(events[0].occurredAt).toBe(A_END_STAMP); // ended, unsealed → stamped at A's endDate
    expect(await shownCount()).toBe(1);
    expect((await parentCell()).isCompleted).toBe(false);

    await incrementCompoundChildFallback('c', 1, A_START, A_END, A);
    events = await liveEvents();
    expect(events).toHaveLength(2);
    expect(await shownCount()).toBe(2);
    expect((await parentCell()).isCompleted).toBe(true);
    expect((await db.boards.get(A))!.completedTasks).toBe(1);

    await incrementCompoundChildFallback('c', -1, A_START, A_END, A);
    expect(await shownCount()).toBe(1);
    expect((await parentCell()).isCompleted).toBe(false);
  });

  it('a decrement is gated at zero', async () => {
    await seed();
    await incrementCompoundChildFallback('c', -1, A_START, A_END, A);
    expect(await liveEvents()).toEqual([]);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('authors nothing for a linked child (its count is its counter\'s) or on a sealed board', async () => {
    await seed({ linked: true });
    await incrementCompoundChildFallback('c', 1, A_START, A_END, A);
    expect(await liveEvents()).toEqual([]);
    const taskMap: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) taskMap[t.id] = t;
    // The sheet still shows a stepper for it — the hook routes it to the counter.
    expect(compoundChildCount(taskMap['c'], taskMap)).toMatchObject({ current: 0, max: 2, step: 1 });

    await db.tasks.clear(); await db.boards.clear(); await db.boardTasks.clear(); await db.compoundChildren.clear();
    await seed({ sealed: true });
    await incrementCompoundChildFallback('c', 1, A_START, A_END, A);
    expect(await liveEvents()).toEqual([]);
  });
});
