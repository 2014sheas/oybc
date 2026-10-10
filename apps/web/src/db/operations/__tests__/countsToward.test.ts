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
  type ContributionOccurrence,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { handleTaskCompletion, runBoardCascadeForTasks } from '../orchestration';
import { createCompound, toggleTaskCompletionAndCascade } from '../tasks.crud';
import { appendCompletionEvent } from '../taskEvents';
import { lateLogCompletion } from '../lateLog';
import { deleteTaskWithCascade, computeTaskDeletionImpact } from '../tasks.deletion';
import { deleteCounterWithUnlink } from '../tasks.counter';
import { COUNTS_TOWARD_KIND_MESSAGE, CountKindSwitchError, switchCounterKind } from '../countKindSwitch';
import { CountsTowardError, setCountsToward } from '../countsToward';
import { applyTaskEventsBatch } from '../taskEventPull';
import { validatePatch, type TaskEditPatch } from '../../taskEditPatch';

/**
 * "Counts toward" PR 3 — data + cascade (docs/SHARED_COUNTER_SETTINGS.md §3;
 * D10: one credit per completion occurrence). Twin of iOS `CountsTowardTests`.
 */

const USER = 'user-1';
const T0 = '2026-01-01T00:00:00.000Z';
const ROOT = '00000000-0000-4000-8000-0000000000a1'; // "Read 12 books" counter
const COPY = '00000000-0000-4000-8000-0000000000a2'; // weekly copy, goal 1
const SIMPLE = '00000000-0000-4000-8000-0000000000b1'; // "Read Dune"
const RUN = '00000000-0000-4000-8000-0000000000b2'; // "Run 2 km" — a plain counting contributor
const CHILD_A = '00000000-0000-4000-8000-0000000000c1';
const CHILD_B = '00000000-0000-4000-8000-0000000000c2';
const BOX = '00000000-0000-4000-8000-0000000000d1'; // compound container
const OCT = '00000000-0000-4000-8000-0000000000e1';
const WEEK = '00000000-0000-4000-8000-0000000000e2';
const CLOSED = '00000000-0000-4000-8000-0000000000e3';
const W1 = '00000000-0000-4000-8000-0000000000e4'; // the repeating weekly board, window 1
const W2 = '00000000-0000-4000-8000-0000000000e5'; // … window 2
const DAY = '00000000-0000-4000-8000-0000000000e6';

const OCT_START = '2026-10-01T00:00:00.000Z';
const OCT_END = '2026-10-31T23:59:59.999Z';
const WEEK_START = '2026-10-12T00:00:00.000Z';
const WEEK_END = '2026-10-18T23:59:59.999Z';
const W1_START = '2026-10-05T00:00:00.000Z';
const W1_END = '2026-10-11T23:59:59.999Z';
const DAY_START = '2026-10-14T00:00:00.000Z';
const DAY_END = '2026-10-14T23:59:59.999Z';
const IN_W1 = '2026-10-07T09:00:00.000Z';
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

const copyTask = (): Task =>
  task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 });

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
  await db.tasks.bulkPut([rootTask(), copyTask(), task(SIMPLE, { title: 'Read Dune', countsTowardCounterId: ROOT, ...simpleOver })]);
  await db.boards.bulkPut([board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)]);
  await db.boardTasks.bulkPut([placement('bt-simple', OCT, SIMPLE), placement('bt-copy', WEEK, COPY)]);
}

/** Root counter + a contributor on two windows of a repeating weekly board. */
async function seedWeeks(contributor: Task = task(SIMPLE, { title: 'Read Dune', countsTowardCounterId: ROOT })): Promise<void> {
  await db.tasks.bulkPut([rootTask(), contributor]);
  await db.boards.bulkPut([board(W1, W1_START, W1_END), board(W2, WEEK_START, WEEK_END)]);
  await db.boardTasks.bulkPut([placement('bt-w1', W1, contributor.id), placement('bt-w2', W2, contributor.id)]);
}

const runTask = (): Task =>
  task(RUN, { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 2, currentCount: 0, countsTowardCounterId: ROOT });

const sortByInstant = (rows: TaskEvent[]): TaskEvent[] =>
  [...rows].sort((a, b) => new Date(a.occurredAt).getTime() - new Date(b.occurredAt).getTime() || (a.id < b.id ? -1 : 1));

/** Every counts-toward credit stored on the root (any state), by instant. */
async function storedCredits(rootId = ROOT): Promise<TaskEvent[]> {
  return sortByInstant((await db.taskEvents.where('taskId').equals(rootId).toArray()).filter((e) => e.kind === 'increment'));
}

/** The LIVE credits on the root, by instant. */
async function liveCredits(rootId = ROOT): Promise<TaskEvent[]> {
  return (await storedCredits(rootId)).filter((e) => !e.isDeleted);
}

/** The contributor's own live events, by instant. */
async function liveEventsOf(taskId: string): Promise<TaskEvent[]> {
  return sortByInstant((await db.taskEvents.where('taskId').equals(taskId).toArray()).filter((e) => !e.isDeleted));
}

const creditId = (contributorId: string, occurrence: ContributionOccurrence): string => countsTowardEventId(contributorId, occurrence);
/** An event-keyed credit id — the contributor is not part of the name. */
const eventCredit = (eventId: string): string => creditId('-', { kind: 'event', eventId });

async function inTxn<T>(fn: () => Promise<T>): Promise<T> {
  return db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], fn);
}

/** A library-style completion stamped at `at`: the event + the cascade, one transaction. */
async function logCompletion(taskId: string, at: string): Promise<void> {
  await inTxn(async () => {
    await appendCompletionEvent(taskId, undefined, at);
    await runBoardCascadeForTasks([taskId]);
  });
}

/** Run `fn` with the clock at `iso`, then put it back at `NOW`. */
async function at(iso: string, fn: () => Promise<unknown>): Promise<void> {
  vi.setSystemTime(new Date(iso));
  await fn();
  vi.setSystemTime(new Date(NOW));
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
  it('completing it writes +1 on the root, keyed by the completion event and stamped at it; the weekly copy counts it in-window', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });

    const [done] = await liveEventsOf(SIMPLE);
    const credits = await liveCredits();
    expect(credits).toHaveLength(1);
    expect(credits[0]).toMatchObject({ id: eventCredit(done.id), taskId: ROOT, kind: 'increment', delta: 1, occurredAt: NOW, version: 1 });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(1);
    const queued = (await db.syncQueue.toArray()).filter((q) => q.entityType === 'taskEvents').map((q) => q.entityId);
    expect(queued).toContain(credits[0].id);
  });

  it('a counter copy on the SAME board is read with the new increment in the same pass (its bingo is reported)', async () => {
    await seed();
    const DONE = '00000000-0000-4000-8000-0000000000b9';
    await db.tasks.put(task(DONE));
    await db.taskEvents.put(completion('00000000-0000-4000-8000-0000000000b8', DONE, '2026-10-02T10:00:00.000Z'));
    // Row 0 of October: Dune · the counter's copy (goal 1) · an already-done task.
    await db.boardTasks.bulkPut([placement('bt-copy-oct', OCT, COPY, 1), placement('bt-done', OCT, DONE, 2)]);

    const result = await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });

    expect(result.newBingos).toHaveLength(1);
    expect((await db.boards.get(OCT))?.completedTasks).toBe(3);
  });

  it('un-completing tombstones the credit and the copy drops back', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: false });

    const stored = await storedCredits();
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ isDeleted: true, version: 2 });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(0);
  });

  it('carries countsTowardAmount', async () => {
    await seed({ countsTowardAmount: 3 });
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    expect((await liveCredits())[0]?.delta).toBe(3);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(3);
  });

  it('a replayed cascade with no state change writes nothing', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    const queueBefore = await db.syncQueue.count();
    const creditsBefore = await storedCredits();
    const rootVersionBefore = (await db.tasks.get(ROOT))!.version;

    await inTxn(() => runBoardCascadeForTasks([SIMPLE]));

    expect(creditsBefore).toHaveLength(1);
    expect(creditsBefore[0].version).toBe(1);
    expect(await db.syncQueue.count()).toBe(queueBefore);
    expect(await storedCredits()).toEqual(creditsBefore);
    expect((await db.tasks.get(ROOT))!.version).toBe(rootVersionBefore);
  });
});

describe('counts toward — one credit per completion occurrence (D10)', () => {
  it('the same Simple task on two windows of a repeating weekly board credits each window, stamped at each completion', async () => {
    await seedWeeks();
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }));
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: true });

    const [c1, c2] = await liveEventsOf(SIMPLE);
    const credits = await liveCredits();
    expect(credits.map((c) => c.occurredAt)).toEqual([IN_W1, NOW]);
    expect(credits.map((c) => c.id)).toEqual([eventCredit(c1.id), eventCredit(c2.id)]);
    expect(credits[0].id).not.toBe(credits[1].id);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(2);
  });

  it('un-completing week 2 tombstones only week 2’s credit', async () => {
    await seedWeeks();
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }));
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: true });
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: false });

    const stored = await storedCredits();
    expect(stored).toHaveLength(2);
    expect(stored[0]).toMatchObject({ occurredAt: IN_W1, isDeleted: false, version: 1 });
    expect(stored[1]).toMatchObject({ occurredAt: NOW, isDeleted: true, version: 2 });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
  });

  it('the same Simple task on a daily and a monthly board completed once is one credit', async () => {
    await db.tasks.bulkPut([rootTask(), task(SIMPLE, { countsTowardCounterId: ROOT })]);
    await db.boards.bulkPut([board(DAY, DAY_START, DAY_END), board(OCT, OCT_START, OCT_END)]);
    await db.boardTasks.bulkPut([placement('bt-day', DAY, SIMPLE), placement('bt-oct', OCT, SIMPLE)]);

    await handleTaskCompletion(DAY, 'bt-day', { isCompleted: true });

    expect(await liveCredits()).toHaveLength(1);
    expect((await db.boards.get(OCT))?.completedTasks).toBe(1);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
  });

  it('a plain Counting task reaching its goal in two windows credits each, keyed by the crossing increment', async () => {
    await seedWeeks(runTask());
    await at('2026-10-06T09:00:00.000Z', () => handleTaskCompletion(W1, 'bt-w1', { currentCount: 1 }));
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { currentCount: 2 }));
    expect(await liveCredits()).toHaveLength(1);
    await at('2026-10-13T09:00:00.000Z', () => handleTaskCompletion(W2, 'bt-w2', { currentCount: 1 }));
    await handleTaskCompletion(W2, 'bt-w2', { currentCount: 2 });

    const increments = await liveEventsOf(RUN);
    const credits = await liveCredits();
    expect(credits.map((c) => c.occurredAt)).toEqual([IN_W1, NOW]);
    expect(credits.map((c) => c.id)).toEqual([eventCredit(increments[1].id), eventCredit(increments[3].id)]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(2);
  });

  it('the same crossing increment inside two overlapping windows is one credit', async () => {
    await db.tasks.bulkPut([rootTask(), runTask()]);
    await db.boards.bulkPut([board(WEEK, WEEK_START, WEEK_END), board(OCT, OCT_START, OCT_END)]);
    await db.boardTasks.bulkPut([placement('bt-run-week', WEEK, RUN), placement('bt-run-oct', OCT, RUN)]);

    await at('2026-10-13T09:00:00.000Z', () => handleTaskCompletion(WEEK, 'bt-run-week', { currentCount: 1 }));
    await handleTaskCompletion(WEEK, 'bt-run-week', { currentCount: 2 });

    const increments = await liveEventsOf(RUN);
    expect(await liveCredits()).toMatchObject([{ id: eventCredit(increments[1].id), occurredAt: NOW }]);
    expect((await db.boards.get(OCT))?.completedTasks).toBe(1);
  });

  it('a Compound credits each window its derivation is complete in, and an unplaced one credits its lifetime', async () => {
    const LIFE = '00000000-0000-4000-8000-0000000000d2';
    await db.tasks.bulkPut([
      rootTask(),
      task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, countsTowardCounterId: ROOT }),
      task(LIFE, { type: TaskType.COMPOUND, operator: OperatorType.OR, countsTowardCounterId: ROOT }),
      task(CHILD_A),
      task(CHILD_B),
    ]);
    await db.compoundChildren.bulkPut([link('l-a', BOX, CHILD_A, 0), link('l-b', BOX, CHILD_B, 1), link('l-life', LIFE, CHILD_A, 0)]);
    await db.boards.bulkPut([board(W1, W1_START, W1_END), board(W2, WEEK_START, WEEK_END)]);
    await db.boardTasks.bulkPut([placement('bt-w1', W1, BOX), placement('bt-w2', W2, BOX)]);

    await logCompletion(CHILD_A, '2026-10-06T09:00:00.000Z');
    await logCompletion(CHILD_B, IN_W1);
    await logCompletion(CHILD_A, '2026-10-13T09:00:00.000Z');
    await logCompletion(CHILD_B, '2026-10-15T09:00:00.000Z');

    const credits = await liveCredits();
    expect(credits).toMatchObject([
      { id: creditId(LIFE, { kind: 'lifetime' }), occurredAt: '2026-10-06T09:00:00.000Z' },
      { id: creditId(BOX, { kind: 'window', startDate: W1_START }), occurredAt: IN_W1 },
      { id: creditId(BOX, { kind: 'window', startDate: WEEK_START }), occurredAt: '2026-10-15T09:00:00.000Z' },
    ]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(3);
  });

  it('a board-scoped fork of a flagged Simple task carries the completion over as the SAME credit — one live credit before and after', async () => {
    await seed();
    await db.boardTasks.put(placement('bt-other', WEEK, SIMPLE, 2));
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    const before = await liveCredits();
    expect(before).toHaveLength(1);

    const plan = planBoardScopedFork({
      task: (await db.tasks.get(SIMPLE))!,
      board: { id: OCT, startDate: OCT_START, endDate: OCT_END, sealedAt: undefined },
      editedType: TaskType.NORMAL,
      placements: await db.boardTasks.toArray(),
      boards: await db.boards.toArray(),
      compoundChildren: [],
      events: await db.taskEvents.toArray(),
      now: NOW,
    });
    if (plan.mode !== 'fork') throw new Error('expected a fork');
    expect(plan.fork.countsTowardCounterId).toBe(ROOT);
    expect(plan.eventCopies).toHaveLength(1);
    await inTxn(async () => {
      await db.tasks.put(plan.fork);
      await db.taskEvents.bulkPut(plan.eventCopies);
      await db.boardTasks.update('bt-simple', { taskId: plan.fork.id });
      await runBoardCascadeForTasks([SIMPLE, plan.fork.id]);
    });

    expect(await storedCredits()).toEqual(before);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
    // A replay from either side changes nothing.
    await inTxn(() => runBoardCascadeForTasks([plan.fork.id]));
    expect(await storedCredits()).toEqual(before);
  });

  it('clearing the flag tombstones every live credit', async () => {
    await seedWeeks();
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }));
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: true });
    expect(await liveCredits()).toHaveLength(2);

    await setCountsToward(SIMPLE, null);

    expect(await liveCredits()).toHaveLength(0);
    expect((await storedCredits()).map((c) => c.version)).toEqual([2, 2]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
  });

  it('a replay after several occurrences writes nothing', async () => {
    await seedWeeks();
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }));
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: true });
    const creditsBefore = await storedCredits();
    const queueBefore = await db.syncQueue.count();

    await inTxn(() => runBoardCascadeForTasks([SIMPLE]));
    await inTxn(() => runBoardCascadeForTasks([ROOT]));

    expect(await storedCredits()).toEqual(creditsBefore);
    expect(await db.syncQueue.count()).toBe(queueBefore);
  });
});

describe('counts toward — a Compound container', () => {
  async function seedBox(): Promise<void> {
    await db.tasks.bulkPut([
      rootTask(),
      copyTask(),
      task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, countsTowardCounterId: ROOT }),
      task(CHILD_A),
      task(CHILD_B),
    ]);
    await db.compoundChildren.bulkPut([link('l-a', BOX, CHILD_A, 0), link('l-b', BOX, CHILD_B, 1)]);
    await db.boards.bulkPut([board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)]);
    await db.boardTasks.bulkPut([placement('bt-box', OCT, BOX), placement('bt-copy', WEEK, COPY)]);
  }

  it('counts once both sub-tasks are done, keyed by the October window and stamped at the later one', async () => {
    await seedBox();
    vi.setSystemTime(new Date('2026-10-13T08:00:00.000Z'));
    await toggleTaskCompletionAndCascade(CHILD_A);
    expect(await liveCredits()).toHaveLength(0);

    vi.setSystemTime(new Date('2026-10-15T20:00:00.000Z'));
    await toggleTaskCompletionAndCascade(CHILD_B);
    expect(await liveCredits()).toMatchObject([
      { id: creditId(BOX, { kind: 'window', startDate: OCT_START }), taskId: ROOT, delta: 1, occurredAt: '2026-10-15T20:00:00.000Z' },
    ]);
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(1);
  });

  it('a late log on a closed board completes the container there — that window’s credit is stamped at the board’s endDate', async () => {
    await seedBox();
    const closedStart = '2026-10-01T00:00:00.000Z';
    const closedEnd = '2026-10-07T23:59:59.999Z';
    await db.boards.put(board(CLOSED, closedStart, closedEnd, { sealedAt: '2026-10-08T00:00:01.000Z', sealedCompletedCells: [] }));
    await db.boardTasks.put(placement('bt-closed', CLOSED, BOX, 1));
    await db.taskEvents.put(completion('ev-a', CHILD_A, '2026-10-03T10:00:00.000Z'));

    await lateLogCompletion(CLOSED, CHILD_B, NOW);

    const credits = await liveCredits();
    expect(credits.find((c) => c.id === creditId(BOX, { kind: 'window', startDate: closedStart }))).toMatchObject({
      taskId: ROOT,
      occurredAt: new Date(closedEnd).toISOString(),
    });
  });

  it('deleting a sub-task the container needed re-derives it (the credit follows)', async () => {
    await seedBox();
    await db.tasks.update(BOX, { operator: OperatorType.OR });
    await toggleTaskCompletionAndCascade(CHILD_A);
    expect(await liveCredits()).toHaveLength(1);
    await deleteTaskWithCascade(CHILD_A);
    expect(await liveCredits()).toHaveLength(0);
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
    expect(await liveCredits()).toHaveLength(0);
  });
});

describe('counts toward — deletion and guards', () => {
  it('deleting a contributor tombstones its credit', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await deleteTaskWithCascade(SIMPLE);
    expect((await storedCredits()).map((c) => c.isDeleted)).toEqual([true]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
  });

  it('the delete preview names the counter', async () => {
    await seed();
    expect((await computeTaskDeletionImpact(SIMPLE)).countsTowardCounter?.id).toBe(ROOT);
    expect((await computeTaskDeletionImpact(COPY)).countsTowardCounter).toBeNull();
  });

  it('deleting the counter unflags its contributors (authored) and leaves the credits with the root', async () => {
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
    expect((await storedCredits()).map((c) => c.isDeleted)).toEqual([false]);
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
    const done = completion('00000000-0000-4000-8000-0000000000f1', SIMPLE, '2026-10-10T10:00:00.000Z');
    await db.taskEvents.put(done);
    await db.tasks.put(task('00000000-0000-4000-8000-0000000000f2', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, isCounter: true, countKind: 'continuous' }));

    await expect(setCountsToward(SIMPLE, '00000000-0000-4000-8000-0000000000f2')).rejects.toBeInstanceOf(CountsTowardError);
    await expect(setCountsToward(SIMPLE, SIMPLE)).rejects.toMatchObject({ code: 'self' });

    await setCountsToward(SIMPLE, ROOT, 2);
    expect(await liveCredits()).toMatchObject([{ id: eventCredit(done.id), delta: 2, occurredAt: '2026-10-10T10:00:00.000Z' }]);

    await setCountsToward(SIMPLE, null);
    const cleared = await db.tasks.get(SIMPLE);
    expect(cleared && ('countsTowardCounterId' in cleared || 'countsTowardAmount' in cleared)).toBe(false);
    expect(await liveCredits()).toHaveLength(0);
  });
});

describe('counts toward — pull path', () => {
  it('a second device re-derives the SAME credit from the pulled completion, and the peer’s copy converges on one row', async () => {
    await seed();
    const completionDoc = completion('00000000-0000-4000-8000-0000000000f9', SIMPLE, '2026-10-13T07:30:00.000Z');

    await applyTaskEventsBatch(USER, [completionDoc]);
    const mine = await liveCredits();
    expect(mine).toMatchObject([{ id: eventCredit(completionDoc.id), taskId: ROOT, delta: 1, occurredAt: '2026-10-13T07:30:00.000Z' }]);

    // The authoring device's own row arrives (same id, same content, earlier createdAt).
    const peer: TaskEvent = {
      id: eventCredit(completionDoc.id),
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
    const rows = await storedCredits();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ delta: 1, occurredAt: '2026-10-13T07:30:00.000Z', isDeleted: false });
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
  });
});
