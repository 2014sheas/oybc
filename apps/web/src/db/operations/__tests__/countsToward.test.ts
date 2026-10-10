import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  countsTowardEventId,
  evaluateCompound,
  planBoardScopedFork,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { handleTaskCompletion, runBoardCascadeForTasks } from '../orchestration';
import { createCompound, toggleTaskCompletionAndCascade } from '../tasks.crud';
import { lateLogCompletion } from '../lateLog';
import { deleteTaskWithCascade, computeTaskDeletionImpact } from '../tasks.deletion';
import { deleteCounterWithUnlink } from '../tasks.counter';
import { COUNTS_TOWARD_KIND_MESSAGE, CountKindSwitchError, switchCounterKind } from '../countKindSwitch';
import { CountsTowardError, setCountsToward } from '../countsToward';
import { applyTaskEventsBatch } from '../taskEventPull';
import { validatePatch, type TaskEditPatch } from '../../taskEditPatch';

/**
 * "Counts toward" PR 3 — data + cascade (docs/SHARED_COUNTER_SETTINGS.md §3).
 * Twin of iOS `CountsTowardTests`.
 */

const USER = 'user-1';
const T0 = '2026-01-01T00:00:00.000Z';
const ROOT = '00000000-0000-4000-8000-0000000000a1'; // "Read 12 books" counter
const COPY = '00000000-0000-4000-8000-0000000000a2'; // weekly copy, goal 1
const SIMPLE = '00000000-0000-4000-8000-0000000000b1'; // "Read Dune"
const CHILD_A = '00000000-0000-4000-8000-0000000000c1';
const CHILD_B = '00000000-0000-4000-8000-0000000000c2';
const BOX = '00000000-0000-4000-8000-0000000000d1'; // compound container
const OCT = '00000000-0000-4000-8000-0000000000e1';
const WEEK = '00000000-0000-4000-8000-0000000000e2';
const CLOSED = '00000000-0000-4000-8000-0000000000e3';

const OCT_START = '2026-10-01T00:00:00.000Z';
const OCT_END = '2026-10-31T23:59:59.999Z';
const WEEK_START = '2026-10-12T00:00:00.000Z';
const WEEK_END = '2026-10-18T23:59:59.999Z';
const NOW = '2026-10-14T09:00:00.000Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

const rootTask = (over: Partial<Task> = {}): Task =>
  task(ROOT, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 12, currentCount: 0, isCounter: true, ...over });

function board(id: string, startDate: string, endDate: string, over: Partial<Board> = {}): Board {
  return {
    id,
    userId: USER,
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.CUSTOM,
    startDate,
    endDate,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
}

function placement(id: string, boardId: string, taskId: string, col = 0): BoardTask {
  return { id, boardId, taskId, row: 0, col, isCenter: false, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}

function link(id: string, compoundTaskId: string, childTaskId: string, childIndex = 0): CompoundChild {
  return { id, compoundTaskId, childTaskId, childIndex, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false } as CompoundChild;
}

function completion(id: string, taskId: string, occurredAt: string): TaskEvent {
  return { id, userId: USER, taskId, kind: 'completion', occurredAt, createdAt: occurredAt, updatedAt: occurredAt, version: 1, isDeleted: false };
}

/** Root counter + its weekly copy (goal 1) on the week board + "Read Dune" on the October board. */
async function seed(simpleOver: Partial<Task> = {}): Promise<void> {
  await db.tasks.bulkPut([
    rootTask(),
    task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 }),
    task(SIMPLE, { title: 'Read Dune', countsTowardCounterId: ROOT, ...simpleOver }),
  ]);
  await db.boards.bulkPut([board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)]);
  await db.boardTasks.bulkPut([placement('bt-simple', OCT, SIMPLE), placement('bt-copy', WEEK, COPY)]);
}

async function liveCountsTowardEvent(contributorId: string): Promise<TaskEvent | undefined> {
  const e = await db.taskEvents.get(countsTowardEventId(contributorId));
  return e && !e.isDeleted ? e : undefined;
}

async function inTxn<T>(fn: () => Promise<T>): Promise<T> {
  return db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], fn);
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date(NOW));
});

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all([
    db.tasks.clear(),
    db.taskEvents.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('counts toward — a Simple task', () => {
  it('completing it writes +1 on the root, stamped at the completion, and the weekly copy counts it in-window', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });

    const ev = await liveCountsTowardEvent(SIMPLE);
    expect(ev).toMatchObject({ taskId: ROOT, kind: 'increment', delta: 1, occurredAt: NOW, version: 1 });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(1);
    const queued = (await db.syncQueue.toArray()).filter((q) => q.entityType === 'taskEvents').map((q) => q.entityId);
    expect(queued).toContain(countsTowardEventId(SIMPLE));
  });

  it('un-completing tombstones the increment and the copy drops back', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: false });

    const stored = await db.taskEvents.get(countsTowardEventId(SIMPLE));
    expect(stored).toMatchObject({ isDeleted: true, version: 2 });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(0);
  });

  it('carries countsTowardAmount', async () => {
    await seed({ countsTowardAmount: 3 });
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    expect((await liveCountsTowardEvent(SIMPLE))?.delta).toBe(3);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(3);
  });

  it('a replayed cascade with no state change writes nothing', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    const queueBefore = await db.syncQueue.count();
    const eventBefore = await db.taskEvents.get(countsTowardEventId(SIMPLE));
    const rootVersionBefore = (await db.tasks.get(ROOT))!.version;

    await inTxn(() => runBoardCascadeForTasks([SIMPLE]));

    expect(eventBefore?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(queueBefore);
    expect(await db.taskEvents.get(countsTowardEventId(SIMPLE))).toEqual(eventBefore);
    expect((await db.tasks.get(ROOT))!.version).toBe(rootVersionBefore);
  });
});

describe('counts toward — a Compound container', () => {
  async function seedBox(): Promise<void> {
    await db.tasks.bulkPut([
      rootTask(),
      task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 }),
      task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, countsTowardCounterId: ROOT }),
      task(CHILD_A),
      task(CHILD_B),
    ]);
    await db.compoundChildren.bulkPut([link('l-a', BOX, CHILD_A, 0), link('l-b', BOX, CHILD_B, 1)]);
    await db.boards.bulkPut([board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)]);
    await db.boardTasks.bulkPut([placement('bt-box', OCT, BOX), placement('bt-copy', WEEK, COPY)]);
  }

  it('counts once both sub-tasks are done, stamped at the later one', async () => {
    await seedBox();
    vi.setSystemTime(new Date('2026-10-13T08:00:00.000Z'));
    await toggleTaskCompletionAndCascade(CHILD_A);
    expect(await liveCountsTowardEvent(BOX)).toBeUndefined();

    vi.setSystemTime(new Date('2026-10-15T20:00:00.000Z'));
    await toggleTaskCompletionAndCascade(CHILD_B);
    expect(await liveCountsTowardEvent(BOX)).toMatchObject({
      taskId: ROOT,
      delta: 1,
      occurredAt: '2026-10-15T20:00:00.000Z',
    });
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(1);
  });

  it('a late log on a closed board completes the container — the increment is stamped at that board’s endDate', async () => {
    await seedBox();
    const closedStart = '2026-10-01T00:00:00.000Z';
    const closedEnd = '2026-10-07T23:59:59.999Z';
    await db.boards.put(board(CLOSED, closedStart, closedEnd, { sealedAt: '2026-10-08T00:00:01.000Z', sealedCompletedCells: [] }));
    await db.boardTasks.put(placement('bt-closed', CLOSED, BOX, 1));
    await db.taskEvents.put(completion('ev-a', CHILD_A, '2026-10-03T10:00:00.000Z'));

    await lateLogCompletion(CLOSED, CHILD_B, NOW);

    expect(await liveCountsTowardEvent(BOX)).toMatchObject({
      taskId: ROOT,
      occurredAt: new Date(closedEnd).toISOString(),
    });
  });

  it('deleting a sub-task the container needed re-derives it (the increment follows)', async () => {
    await seedBox();
    await db.tasks.update(BOX, { operator: OperatorType.OR });
    await toggleTaskCompletionAndCascade(CHILD_A);
    expect(await liveCountsTowardEvent(BOX)).toBeDefined();
    await deleteTaskWithCascade(CHILD_A);
    expect(await liveCountsTowardEvent(BOX)).toBeUndefined();
  });

  it('an empty container is allowed only with the flag, and evaluates incomplete', async () => {
    const patch: TaskEditPatch = { title: 'Books this year', goal: '', unit: '', children: [], operator: OperatorType.AND } as unknown as TaskEditPatch;
    expect(validatePatch(patch, TaskType.COMPOUND)).toBe('A compound task needs a sub-task.');
    expect(validatePatch(patch, TaskType.COMPOUND, undefined, { countsToward: true })).toBeNull();

    await db.tasks.put(rootTask());
    const box = await createCompound(USER, {
      title: 'A book',
      operator: OperatorType.AND,
      children: [],
      countsTowardCounterId: ROOT,
    });
    expect(box.countsTowardCounterId).toBe(ROOT);
    expect(evaluateCompound(box, {}, { [box.id]: box })).toBe(false);
    expect(await liveCountsTowardEvent(box.id)).toBeUndefined();
  });
});

describe('counts toward — forks, deletion and guards', () => {
  it('a board-scoped fork keeps the flag and mints its own event when it completes', async () => {
    await seed();
    const plan = planBoardScopedFork({
      task: (await db.tasks.get(SIMPLE))!,
      board: { id: OCT, startDate: OCT_START, endDate: OCT_END, sealedAt: undefined },
      editedType: TaskType.NORMAL,
      placements: [placement('bt-simple', OCT, SIMPLE), placement('bt-other', WEEK, SIMPLE, 2)],
      boards: [board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)],
      compoundChildren: [],
      events: [],
      now: NOW,
    });
    if (plan.mode !== 'fork') throw new Error('expected a fork');
    expect(plan.fork.countsTowardCounterId).toBe(ROOT);
    await db.tasks.put(plan.fork);
    await db.boardTasks.update('bt-simple', { taskId: plan.fork.id });

    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    expect(await liveCountsTowardEvent(plan.fork.id)).toMatchObject({ taskId: ROOT, delta: 1 });
    expect(await liveCountsTowardEvent(SIMPLE)).toBeUndefined();
  });

  it('deleting a contributor tombstones its increment', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await deleteTaskWithCascade(SIMPLE);
    expect((await db.taskEvents.get(countsTowardEventId(SIMPLE)))?.isDeleted).toBe(true);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
  });

  it('the delete preview names the counter', async () => {
    await seed();
    expect((await computeTaskDeletionImpact(SIMPLE)).countsTowardCounter?.id).toBe(ROOT);
    expect((await computeTaskDeletionImpact(COPY)).countsTowardCounter).toBeNull();
  });

  it('deleting the counter unflags its contributors (authored) and leaves the events with the root', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await db.syncQueue.clear();
    const versionBefore = (await db.tasks.get(SIMPLE))!.version;
    await deleteCounterWithUnlink(ROOT);

    const simple = await db.tasks.get(SIMPLE);
    expect(simple && 'countsTowardCounterId' in simple).toBe(false);
    expect(simple?.version).toBe(versionBefore + 1);
    const queuedTasks = (await db.syncQueue.toArray()).filter((q) => q.entityType === 'tasks').map((q) => q.entityId);
    expect(queuedTasks).toContain(SIMPLE);
    expect((await db.taskEvents.get(countsTowardEventId(SIMPLE)))?.isDeleted).toBe(false);
  });

  it('the kind switch refuses to leave Discrete while contributors exist', async () => {
    await seed();
    const refusal = switchCounterKind(ROOT, 'continuous');
    await expect(refusal).rejects.toBeInstanceOf(CountKindSwitchError);
    await expect(refusal).rejects.toMatchObject({ code: 'has-contributors', message: COUNTS_TOWARD_KIND_MESSAGE });
    expect((await db.tasks.get(ROOT))?.countKind).toBeUndefined();
  });

  it('setCountsToward validates, then mints at once for a task already done; clearing tombstones', async () => {
    await seed({ countsTowardCounterId: undefined });
    await db.taskEvents.put(completion('00000000-0000-4000-8000-0000000000f1', SIMPLE, '2026-10-10T10:00:00.000Z'));
    await db.tasks.put(task('00000000-0000-4000-8000-0000000000f2', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, isCounter: true, countKind: 'continuous' }));

    await expect(setCountsToward(SIMPLE, '00000000-0000-4000-8000-0000000000f2')).rejects.toBeInstanceOf(CountsTowardError);
    await expect(setCountsToward(SIMPLE, SIMPLE)).rejects.toMatchObject({ code: 'self' });

    await setCountsToward(SIMPLE, ROOT, 2);
    expect(await liveCountsTowardEvent(SIMPLE)).toMatchObject({ delta: 2, occurredAt: '2026-10-10T10:00:00.000Z' });

    await setCountsToward(SIMPLE, null);
    const cleared = await db.tasks.get(SIMPLE);
    expect(cleared && ('countsTowardCounterId' in cleared || 'countsTowardAmount' in cleared)).toBe(false);
    expect(await liveCountsTowardEvent(SIMPLE)).toBeUndefined();
  });
});

describe('counts toward — pull path', () => {
  it('a second device re-derives the SAME event from the pulled completion, and the peer’s copy converges on one row', async () => {
    await seed();
    const completionDoc = completion('00000000-0000-4000-8000-0000000000f9', SIMPLE, '2026-10-13T07:30:00.000Z');

    await applyTaskEventsBatch(USER, [completionDoc]);
    const mine = await liveCountsTowardEvent(SIMPLE);
    expect(mine).toMatchObject({ taskId: ROOT, delta: 1, occurredAt: '2026-10-13T07:30:00.000Z' });

    // The authoring device's own row arrives (same id, same content, earlier createdAt).
    const peer: TaskEvent = {
      id: countsTowardEventId(SIMPLE),
      userId: USER,
      taskId: ROOT,
      kind: 'increment',
      delta: 1,
      occurredAt: '2026-10-13T07:30:00.000Z',
      createdAt: '2026-10-13T07:30:01.000Z',
      updatedAt: '2026-10-13T07:30:01.000Z',
      version: 1,
      isDeleted: false,
    };
    await applyTaskEventsBatch(USER, [peer]);
    const rows = (await db.taskEvents.toArray()).filter((e) => e.taskId === ROOT);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ delta: 1, occurredAt: '2026-10-13T07:30:00.000Z', isDeleted: false });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
  });
});
