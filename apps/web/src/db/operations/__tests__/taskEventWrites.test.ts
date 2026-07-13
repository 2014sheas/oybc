import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { handleTaskCompletion } from '../orchestration';
import { toggleTaskCompletionAndCascade } from '../tasks.crud';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Write paths + §Testing
 * matrix web row) — the board-context event write choke points: complete /
 * window-scoped un-complete (incl. multi-event + pre-window boundary) /
 * increment / context-split decrement. Each asserts the TaskEvent row is
 * written AND the lifetime caches are restamped AND the derivation fires
 * (board `completedTasks`).
 */

const START = '2026-01-01T00:00:00.000Z';

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Test board',
    status: BoardStatus.ACTIVE,
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
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedTask(overrides: Partial<Task> = {}): Promise<Task> {
  const task: Task = {
    id: 'task-1',
    userId: 'user-1',
    title: 'Read a book',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.tasks.add(task);
  return task;
}

async function seedBoardTask(overrides: Partial<BoardTask> = {}): Promise<BoardTask> {
  const bt: BoardTask = {
    id: 'bt-1',
    boardId: 'board-1',
    taskId: 'task-1',
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    ...overrides,
  };
  await db.boardTasks.add(bt);
  return bt;
}

async function seedEvent(overrides: Partial<TaskEvent> & Pick<TaskEvent, 'id' | 'kind' | 'occurredAt'>): Promise<void> {
  const event: TaskEvent = {
    userId: 'user-1',
    taskId: 'task-1',
    createdAt: overrides.occurredAt,
    updatedAt: overrides.occurredAt,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as TaskEvent;
  await db.taskEvents.add(event);
}

async function liveEvents(taskId = 'task-1'): Promise<TaskEvent[]> {
  return (await db.taskEvents.where('taskId').equals(taskId).toArray()).filter((e) => !e.isDeleted);
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('Windowed Completion — board-context completion (normal)', () => {
  it('complete appends a completion event, stamps caches, fires derivation', async () => {
    await seedTask();
    await seedBoard();
    await seedBoardTask();

    await handleTaskCompletion('board-1', 'bt-1', { isCompleted: true });

    const events = await liveEvents();
    expect(events).toHaveLength(1);
    expect(events[0].kind).toBe('completion');
    expect(events[0].boardId).toBe('board-1');

    const task = await db.tasks.get('task-1');
    expect(task?.isCompleted).toBe(true);
    expect(task?.completedAt).toBe(events[0].occurredAt);
    expect(task?.version).toBe(2); // authored cache stamp bumped version

    const board = await db.boards.get('board-1');
    expect(board?.completedTasks).toBe(1);

    // Both the TaskEvent CREATE and the Task cache UPDATE were enqueued.
    const q = await db.syncQueue.toArray();
    expect(q.some((r) => r.entityType === 'taskEvents')).toBe(true);
    expect(q.some((r) => r.entityType === 'tasks' && r.entityId === 'task-1')).toBe(true);
  });

  it('window-scoped un-complete tombstones ALL in-window completions (multi-event) but leaves pre-window events', async () => {
    await seedTask({ isCompleted: true, completedAt: '2026-01-03T00:00:00.000Z' });
    await seedBoard();
    await seedBoardTask();
    // Two in-window completions + one BEFORE the board's startDate.
    await seedEvent({ id: 'e-pre', kind: 'completion', occurredAt: '2025-12-30T00:00:00.000Z' });
    await seedEvent({ id: 'e-in1', kind: 'completion', occurredAt: '2026-01-02T00:00:00.000Z' });
    await seedEvent({ id: 'e-in2', kind: 'completion', occurredAt: '2026-01-05T00:00:00.000Z' });

    await handleTaskCompletion('board-1', 'bt-1', { isCompleted: false });

    // Both in-window events tombstoned; the pre-window event survives.
    expect((await db.taskEvents.get('e-in1'))?.isDeleted).toBe(true);
    expect((await db.taskEvents.get('e-in2'))?.isDeleted).toBe(true);
    expect((await db.taskEvents.get('e-pre'))?.isDeleted).toBe(false);

    // Board (window) shows incomplete; lifetime cache still complete (the
    // pre-window completion is a real lifetime event).
    const board = await db.boards.get('board-1');
    expect(board?.completedTasks).toBe(0);
    const task = await db.tasks.get('task-1');
    expect(task?.isCompleted).toBe(true);
  });
});

describe('Windowed Completion — board-context counting', () => {
  it('increment appends a positive-delta event and stamps the lifetime count', async () => {
    await seedTask({ type: TaskType.COUNTING, action: 'pages', unit: 'pg', maxCount: 3, currentCount: 0 });
    await seedBoard();
    await seedBoardTask();

    // UI passes the desired NEW windowed count; delta = 1 - 0.
    await handleTaskCompletion('board-1', 'bt-1', { currentCount: 1 });

    const events = await liveEvents();
    expect(events).toHaveLength(1);
    expect(events[0].kind).toBe('increment');
    expect(events[0].delta).toBe(1);

    const task = await db.tasks.get('task-1');
    expect(task?.currentCount).toBe(1);
    expect(task?.isCompleted).toBe(false);
  });

  it('reaching maxCount stamps isCompleted; context-split decrement appends a gated negative delta', async () => {
    await seedTask({ type: TaskType.COUNTING, maxCount: 3, currentCount: 0 });
    await seedBoard();
    await seedBoardTask();

    await handleTaskCompletion('board-1', 'bt-1', { currentCount: 1 });
    await handleTaskCompletion('board-1', 'bt-1', { currentCount: 2 });
    await handleTaskCompletion('board-1', 'bt-1', { currentCount: 3 });

    let task = await db.tasks.get('task-1');
    expect(task?.currentCount).toBe(3);
    expect(task?.isCompleted).toBe(true);
    let board = await db.boards.get('board-1');
    expect(board?.completedTasks).toBe(1);

    // Board-context decrement: desired 2 from windowed 3 → delta -1.
    await handleTaskCompletion('board-1', 'bt-1', { currentCount: 2 });
    const events = await liveEvents();
    const deltas = events.map((e) => e.delta).sort();
    expect(deltas).toEqual([-1, 1, 1, 1]);
    task = await db.tasks.get('task-1');
    expect(task?.currentCount).toBe(2);
    expect(task?.isCompleted).toBe(false);
    board = await db.boards.get('board-1');
    expect(board?.completedTasks).toBe(0);
  });

  it('decrement is gated so the window sum cannot go negative', async () => {
    await seedTask({ type: TaskType.COUNTING, maxCount: 3, currentCount: 0 });
    await seedBoard();
    await seedBoardTask();

    // Windowed count is 0; a reset to 0 is a no-op (delta clamps to 0).
    await handleTaskCompletion('board-1', 'bt-1', { currentCount: 0, isCompleted: false });
    expect(await liveEvents()).toHaveLength(0);
    expect((await db.tasks.get('task-1'))?.currentCount ?? 0).toBe(0);
  });
});

describe('Windowed Completion — library-context toggle (unplaced compound child)', () => {
  it('toggle on appends a completion event; toggle off tombstones the latest', async () => {
    await seedTask();

    await toggleTaskCompletionAndCascade('task-1');
    expect(await liveEvents()).toHaveLength(1);
    expect((await db.tasks.get('task-1'))?.isCompleted).toBe(true);

    await toggleTaskCompletionAndCascade('task-1');
    expect(await liveEvents()).toHaveLength(0);
    expect((await db.tasks.get('task-1'))?.isCompleted).toBe(false);
  });
});
