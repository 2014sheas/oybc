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
import { deleteCounterWithUnlink, promoteTaskToCounter } from '../tasks.counter';
import { updateBoardAndCascade } from '../boards';
import { sealBoard } from '../sealing';
import { applyRemoteSubdoc } from '../pullApply';
import { COUNTS_TOWARD_KIND_MESSAGE, CountKindSwitchError, switchCounterKind } from '../countKindSwitch';
import { CountsTowardError, setCountsToward } from '../countsToward';
import { applyTaskEventsBatch } from '../taskEventPull';
import { validatePatch, type TaskEditPatch } from '../../taskEditPatch';

/**
 * "Counts toward" PR 3 — data + cascade (docs/SHARED_COUNTER_SETTINGS.md §3;
 * D10: one credit per completion occurrence; D11: count from
 * `countsTowardSince`, credits honour the counter's sealed windows). Twin of
 * iOS `CountsTowardTests`.
 */

const USER = 'user-1';
const T0 = '2026-01-01T00:00:00.000Z';
const ROOT = '00000000-0000-4000-8000-0000000000a1'; // "Read 12 books" counter
const ROOT2 = '00000000-0000-4000-8000-0000000000a3'; // "Finish 5 novels" counter
const COPY = '00000000-0000-4000-8000-0000000000a2'; // weekly copy, goal 1
const COPY2 = '00000000-0000-4000-8000-0000000000a4'; // ROOT2's copy, goal 1
const SIMPLE = '00000000-0000-4000-8000-0000000000b1'; // "Read Dune"
const RUN = '00000000-0000-4000-8000-0000000000b2'; // "Run 2 km" — a plain counting contributor
const OTHER = '00000000-0000-4000-8000-0000000000b3'; // a second Simple contributor
const CHILD_A = '00000000-0000-4000-8000-0000000000c1';
const CHILD_B = '00000000-0000-4000-8000-0000000000c2';
const BOX = '00000000-0000-4000-8000-0000000000d1'; // compound container
const OCT = '00000000-0000-4000-8000-0000000000e1';
const WEEK = '00000000-0000-4000-8000-0000000000e2';
const CLOSED = '00000000-0000-4000-8000-0000000000e3';
const W1 = '00000000-0000-4000-8000-0000000000e4'; // the repeating weekly board, window 1
const W2 = '00000000-0000-4000-8000-0000000000e5'; // … window 2
const DAY = '00000000-0000-4000-8000-0000000000e6';
const SEALED_LATE = '00000000-0000-4000-8000-0000000000e7';
const MISSING = '00000000-0000-4000-8000-00000000dead';

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
const LATER = '2026-10-16T09:00:00.000Z';

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

/** The counts-toward flag as a row carries it: counter + the D11 `since` stamp (T0 = before every event here). */
const flagged = (over: Partial<Task> = {}): Partial<Task> => ({ countsTowardCounterId: ROOT, countsTowardSince: T0, ...over });

const rootTask = (over: Partial<Task> = {}): Task =>
  task(ROOT, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 12, currentCount: 0, isCounter: true, ...over });

const root2Task = (): Task =>
  task(ROOT2, { type: TaskType.COUNTING, action: 'Finish', unit: 'novels', maxCount: 5, currentCount: 0, isCounter: true });

const copyTask = (id = COPY, rootId = ROOT): Task =>
  task(id, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: rootId, baseline: 0, currentCount: 0 });

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
  await db.tasks.bulkPut([rootTask(), copyTask(), task(SIMPLE, { title: 'Read Dune', ...flagged(), ...simpleOver })]);
  await db.boards.bulkPut([board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)]);
  await db.boardTasks.bulkPut([placement('bt-simple', OCT, SIMPLE), placement('bt-copy', WEEK, COPY)]);
}

/** Root counter + a contributor on two windows of a repeating weekly board. */
async function seedWeeks(contributor: Task = task(SIMPLE, { title: 'Read Dune', ...flagged() })): Promise<void> {
  await db.tasks.bulkPut([rootTask(), contributor]);
  await db.boards.bulkPut([board(W1, W1_START, W1_END), board(W2, WEEK_START, WEEK_END)]);
  await db.boardTasks.bulkPut([placement('bt-w1', W1, contributor.id), placement('bt-w2', W2, contributor.id)]);
}

const runTask = (): Task =>
  task(RUN, { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 2, currentCount: 0, ...flagged() });

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

const creditId = (rootId: string, scope: string, occurrence: ContributionOccurrence): string => countsTowardEventId(rootId, scope, occurrence);
/** An own-event credit id on `rootId` — the contributor is not part of the name. */
const eventCredit = (eventId: string, rootId = ROOT): string => creditId(rootId, '-', { kind: 'event', eventId });
/** A compound's credit for its completing child's event — scoped by the compound (its lineage root). */
const childCredit = (compoundId: string, eventId: string, rootId = ROOT): string => creditId(rootId, compoundId, { kind: 'childEvent', eventId });

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

/**
 * Seed "Read Dune" on October AND the week board, complete it on October, then
 * fork it for October (the fork copies the in-window completion). Returns the
 * fork; afterwards the original owns the week placement and the fork October's.
 */
async function forkCompletedDune(): Promise<Task> {
  await seed();
  await db.boardTasks.put(placement('bt-other', WEEK, SIMPLE, 2));
  await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
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
  await inTxn(async () => {
    await db.tasks.put(plan.fork);
    await db.taskEvents.bulkPut(plan.eventCopies);
    await db.boardTasks.update('bt-simple', { taskId: plan.fork.id });
    await runBoardCascadeForTasks([SIMPLE, plan.fork.id]);
  });
  return plan.fork;
}

/** Credits + sync queue before/after a replay must be byte-identical. */
async function expectReplayNoop(taskIds: string[], roots: string[] = [ROOT]): Promise<void> {
  const before = await Promise.all(roots.map((r) => storedCredits(r)));
  const queueBefore = await db.syncQueue.count();
  await inTxn(() => runBoardCascadeForTasks(taskIds));
  expect(await Promise.all(roots.map((r) => storedCredits(r)))).toEqual(before);
  expect(await db.syncQueue.count()).toBe(queueBefore);
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
  it('completing it writes +1 on the root, keyed by the root + completion event and stamped at it; the weekly copy counts it in-window', async () => {
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
    const rootVersionBefore = (await db.tasks.get(ROOT))!.version;
    await expectReplayNoop([SIMPLE]);
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
    await db.tasks.bulkPut([rootTask(), task(SIMPLE, flagged())]);
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

  it('a Compound credits each window its derivation is complete in, keyed by the completing child’s event; an unplaced one too', async () => {
    const LIFE = '00000000-0000-4000-8000-0000000000d2';
    await db.tasks.bulkPut([
      rootTask(),
      task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, ...flagged() }),
      task(LIFE, { type: TaskType.COMPOUND, operator: OperatorType.OR, ...flagged() }),
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

    const [a1] = await liveEventsOf(CHILD_A);
    const [b1, b2] = await liveEventsOf(CHILD_B);
    expect(await liveCredits()).toMatchObject([
      { id: childCredit(LIFE, a1.id), occurredAt: '2026-10-06T09:00:00.000Z' },
      { id: childCredit(BOX, b1.id), occurredAt: IN_W1 },
      { id: childCredit(BOX, b2.id), occurredAt: '2026-10-15T09:00:00.000Z' },
    ]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(3);
  });

  it('a Compound on a daily and a monthly board completed once is one credit', async () => {
    await db.tasks.bulkPut([rootTask(), task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, ...flagged() }), task(CHILD_A)]);
    await db.compoundChildren.put(link('l-a', BOX, CHILD_A, 0));
    await db.boards.bulkPut([board(DAY, DAY_START, DAY_END), board(OCT, OCT_START, OCT_END)]);
    await db.boardTasks.bulkPut([placement('bt-day', DAY, BOX), placement('bt-oct', OCT, BOX, 1)]);

    await logCompletion(CHILD_A, NOW);

    const [a] = await liveEventsOf(CHILD_A);
    expect(await liveCredits()).toMatchObject([{ id: childCredit(BOX, a.id), occurredAt: NOW }]);
  });

  it('editing a board’s start date keeps a Compound’s credit (one live credit before and after)', async () => {
    await db.tasks.bulkPut([rootTask(), task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, ...flagged() }), task(CHILD_A)]);
    await db.compoundChildren.put(link('l-a', BOX, CHILD_A, 0));
    await db.boards.put(board(OCT, OCT_START, OCT_END));
    await db.boardTasks.put(placement('bt-oct', OCT, BOX));
    await logCompletion(CHILD_A, NOW);
    const before = await liveCredits();
    expect(before).toHaveLength(1);

    await updateBoardAndCascade(OCT, { startDate: '2026-10-03T00:00:00.000Z' });
    await inTxn(() => runBoardCascadeForTasks([BOX]));

    expect(await storedCredits()).toEqual(before);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
  });

  it('clearing the flag tombstones every live credit and the since stamp', async () => {
    await seedWeeks();
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }));
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: true });
    expect(await liveCredits()).toHaveLength(2);

    await setCountsToward(SIMPLE, null);

    expect(await liveCredits()).toHaveLength(0);
    expect((await storedCredits()).map((c) => c.version)).toEqual([2, 2]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
    const cleared = (await db.tasks.get(SIMPLE))!;
    expect('countsTowardSince' in cleared).toBe(false);
  });

  it('a replay after several occurrences writes nothing', async () => {
    await seedWeeks();
    await at(IN_W1, () => handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }));
    await handleTaskCompletion(W2, 'bt-w2', { isCompleted: true });
    await expectReplayNoop([SIMPLE]);
    await expectReplayNoop([ROOT]);
  });
});

describe('counts toward — fork lineage shares one credit', () => {
  it('a board-scoped fork of a flagged Simple task carries the completion over as the SAME credit — one live credit before and after', async () => {
    const fork = await forkCompletedDune();
    expect(fork.countsTowardCounterId).toBe(ROOT);
    expect(fork.countsTowardSince).toBe(T0);
    expect(await liveCredits()).toHaveLength(1);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
    await expectReplayNoop([fork.id]);
  });

  it('an undo on the FORK’s board only — the original still wants the credit, so it stays', async () => {
    const fork = await forkCompletedDune();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: false });

    expect(await liveEventsOf(fork.id)).toHaveLength(0);
    expect(await liveEventsOf(SIMPLE)).toHaveLength(1);
    expect((await liveCredits()).map((c) => c.version)).toEqual([1]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
  });

  it('an undo on the ORIGINAL only — the fork still wants the credit, so it stays', async () => {
    const fork = await forkCompletedDune();
    await handleTaskCompletion(WEEK, 'bt-other', { isCompleted: false });

    expect(await liveEventsOf(SIMPLE)).toHaveLength(0);
    expect(await liveEventsOf(fork.id)).toHaveLength(1);
    expect((await liveCredits()).map((c) => c.version)).toEqual([1]);
  });

  it('deleting the original — the fork still wants the credit, so it stays', async () => {
    await forkCompletedDune();
    await deleteTaskWithCascade(SIMPLE);
    expect((await liveCredits()).map((c) => c.version)).toEqual([1]);
  });

  it('clearing the fork’s flag — the original still wants the credit; once both are gone it is tombstoned', async () => {
    const fork = await forkCompletedDune();
    await setCountsToward(fork.id, null);
    expect((await liveCredits()).map((c) => c.version)).toEqual([1]);

    await handleTaskCompletion(WEEK, 'bt-other', { isCompleted: false });
    expect(await liveCredits()).toHaveLength(0);
    expect((await storedCredits()).map((c) => c.version)).toEqual([2]);
  });

  it('the original re-pointed to another counter while the fork keeps the first: separate credits, one on each root, and replays write nothing', async () => {
    const fork = await forkCompletedDune();
    await db.tasks.put(root2Task());

    await at(LATER, () => setCountsToward(SIMPLE, ROOT2));
    // The shared completion (10-14) is before the original's new `since`, so
    // only the fork keeps crediting ROOT; the original credits ROOT2 from now on.
    expect((await liveCredits(ROOT)).map((c) => c.version)).toEqual([1]);
    expect(await liveCredits(ROOT2)).toHaveLength(0);

    await logCompletion(SIMPLE, '2026-10-17T09:00:00.000Z');
    const [, e2] = await liveEventsOf(SIMPLE);
    expect(await liveCredits(ROOT2)).toMatchObject([{ id: eventCredit(e2.id, ROOT2), occurredAt: '2026-10-17T09:00:00.000Z' }]);
    expect((await liveCredits(ROOT)).map((c) => c.version)).toEqual([1]);

    await expectReplayNoop([SIMPLE], [ROOT, ROOT2]);
    await expectReplayNoop([fork.id], [ROOT, ROOT2]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
    expect((await db.tasks.get(ROOT2))?.currentCount).toBe(1);
  });

  it('the fork and the original disagree on the amount: one credit, the lineage root’s amount, and replays write nothing', async () => {
    const fork = await forkCompletedDune();
    await at(LATER, () => setCountsToward(fork.id, ROOT, 3));

    expect(await liveCredits()).toMatchObject([{ delta: 1, version: 1 }]);
    await expectReplayNoop([fork.id]);
    await expectReplayNoop([SIMPLE]);

    // The lineage root's amount is the rule: raising it moves the one credit.
    await at(LATER, () => setCountsToward(SIMPLE, ROOT, 2));
    expect(await liveCredits()).toMatchObject([{ delta: 2, version: 2 }]);
    await expectReplayNoop([fork.id]);
  });

  it('a fork whose original is not loaded yet produces nothing until the original arrives', async () => {
    await db.tasks.bulkPut([rootTask(), task(OTHER, { forkedFromTaskId: MISSING, createdInWizard: true, ...flagged() })]);
    await db.boards.put(board(OCT, OCT_START, OCT_END));
    await db.boardTasks.put(placement('bt-other', OCT, OTHER));
    await handleTaskCompletion(OCT, 'bt-other', { isCompleted: true });
    expect(await storedCredits()).toHaveLength(0);

    await db.tasks.put(task(MISSING));
    await inTxn(() => runBoardCascadeForTasks([OTHER]));
    const [done] = await liveEventsOf(OTHER);
    expect(await liveCredits()).toMatchObject([{ id: eventCredit(done.id), occurredAt: NOW }]);
  });
});

describe('counts toward — count from flag time (D11)', () => {
  it('setting the flag after a completion does not credit it; a completion after the flag does', async () => {
    await seed({ countsTowardCounterId: undefined, countsTowardSince: undefined });
    await logCompletion(SIMPLE, '2026-10-10T10:00:00.000Z');

    await setCountsToward(SIMPLE, ROOT);
    expect((await db.tasks.get(SIMPLE))?.countsTowardSince).toBe(NOW);
    expect(await liveCredits()).toHaveLength(0);

    await logCompletion(SIMPLE, LATER);
    const [, later] = await liveEventsOf(SIMPLE);
    expect(await liveCredits()).toMatchObject([{ id: eventCredit(later.id), occurredAt: LATER }]);
  });

  it('a late log stamped at an ended board’s endDate before the flag does not credit (D8 stamp is the occurrence instant)', async () => {
    await db.tasks.bulkPut([rootTask(), task(SIMPLE)]);
    await db.boards.put(board(W1, W1_START, W1_END));
    await db.boardTasks.put(placement('bt-w1', W1, SIMPLE));
    await setCountsToward(SIMPLE, ROOT); // since = NOW (10-14), after W1 ended

    await handleTaskCompletion(W1, 'bt-w1', { isCompleted: true }); // stamped min(now, endDate) = 10-11

    expect((await liveEventsOf(SIMPLE))[0].occurredAt).toBe(new Date(W1_END).toISOString());
    expect(await liveCredits()).toHaveLength(0);
  });

  it('re-pointing to another counter resets since: the old root’s earlier credit is tombstoned, later occurrences credit the new root', async () => {
    await seed();
    await db.tasks.put(root2Task());
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    expect(await liveCredits(ROOT)).toHaveLength(1);

    await at(LATER, () => setCountsToward(SIMPLE, ROOT2));
    expect((await db.tasks.get(SIMPLE))?.countsTowardSince).toBe(LATER);
    expect(await liveCredits(ROOT)).toHaveLength(0);
    expect((await storedCredits(ROOT)).map((c) => c.version)).toEqual([2]);
    expect(await liveCredits(ROOT2)).toHaveLength(0);

    await logCompletion(SIMPLE, '2026-10-17T09:00:00.000Z');
    expect(await liveCredits(ROOT2)).toMatchObject([{ occurredAt: '2026-10-17T09:00:00.000Z' }]);
    expect(await liveCredits(ROOT)).toHaveLength(0);
  });

  it('changing only the amount keeps since; clearing drops it', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await at(LATER, () => setCountsToward(SIMPLE, ROOT, 3));
    expect((await db.tasks.get(SIMPLE))?.countsTowardSince).toBe(T0);
    expect(await liveCredits()).toMatchObject([{ delta: 3 }]);

    await setCountsToward(SIMPLE, null);
    const cleared = (await db.tasks.get(SIMPLE))!;
    expect('countsTowardCounterId' in cleared || 'countsTowardAmount' in cleared || 'countsTowardSince' in cleared).toBe(false);
  });
});

describe('counts toward — credits honour the counter’s sealed windows (D11)', () => {
  it('an undo on the open monthly leaves a credit that sits in a now-sealed weekly copy window; the sealed snapshot is unchanged', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(1);
    await sealBoard(WEEK, '2026-10-19T00:00:00.000Z');
    const sealed = (await db.boards.get(WEEK))!;
    expect(sealed.sealedCompletedCells).toEqual([0]);

    await at('2026-10-20T09:00:00.000Z', () => handleTaskCompletion(OCT, 'bt-simple', { isCompleted: false }));

    expect(await liveEventsOf(SIMPLE)).toHaveLength(0);
    expect((await liveCredits()).map((c) => c.version)).toEqual([1]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(1);
    const after = (await db.boards.get(WEEK))!;
    expect(after.sealedCompletedCells).toEqual([0]);
    expect(after.completedTasks).toBe(1);
    expect(after.version).toBe(sealed.version);
  });

  it('a credit whose instant falls in a sealed window of the root’s copy is not minted outside the late-log path', async () => {
    await seed();
    await sealBoard(WEEK, '2026-10-19T00:00:00.000Z');
    await logCompletion(SIMPLE, NOW); // 10-14 sits inside the sealed week
    expect(await liveCredits()).toHaveLength(0);

    await logCompletion(SIMPLE, '2026-10-20T09:00:00.000Z'); // outside it
    expect((await liveCredits()).map((c) => c.occurredAt)).toEqual(['2026-10-20T09:00:00.000Z']);
  });

  it('the late-log exemption covers only the stamped instant: a chained credit at another instant inside a sealed window stays suppressed', async () => {
    const closedEnd = '2026-10-07T23:59:59.999Z';
    const Z = '00000000-0000-4000-8000-0000000000c3';
    await db.tasks.bulkPut([
      rootTask(),
      root2Task(),
      copyTask(COPY, ROOT),
      copyTask(COPY2, ROOT2),
      task(SIMPLE, flagged()), // → ROOT, late-logged on the closed board
      task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, ...flagged({ countsTowardCounterId: ROOT2 }) }), // [copy of ROOT, Z] → ROOT2
      task(Z),
    ]);
    await db.compoundChildren.bulkPut([link('l-copy', BOX, COPY, 0), link('l-z', BOX, Z, 1)]);
    await db.boards.bulkPut([
      board(CLOSED, OCT_START, closedEnd, { sealedAt: '2026-10-08T00:00:01.000Z', sealedCompletedCells: [] }),
      board(OCT, OCT_START, OCT_END), // open; holds ROOT's copy and the container
      board(SEALED_LATE, '2026-10-19T00:00:00.000Z', '2026-10-25T23:59:59.999Z', { sealedAt: '2026-10-26T00:00:01.000Z', sealedCompletedCells: [] }), // holds ROOT2's copy
    ]);
    await db.boardTasks.bulkPut([
      placement('bt-simple-closed', CLOSED, SIMPLE),
      placement('bt-copy-oct', OCT, COPY),
      placement('bt-box-oct', OCT, BOX, 1),
      placement('bt-copy2-late', SEALED_LATE, COPY2),
    ]);
    await db.taskEvents.put(completion('ev-z', Z, '2026-10-20T09:00:00.000Z'));

    await at('2026-10-27T09:00:00.000Z', () => lateLogCompletion(CLOSED, SIMPLE, '2026-10-27T09:00:00.000Z'));

    // ROOT's credit at the stamped instant lands; the container it completes
    // (its completing child is Z at 10-20) sits inside ROOT2's sealed copy
    // window → that chained credit is suppressed.
    expect((await liveCredits(ROOT)).map((c) => c.occurredAt)).toEqual([new Date(closedEnd).toISOString()]);
    expect(await storedCredits(ROOT2)).toHaveLength(0);
    expect((await db.tasks.get(ROOT2))?.currentCount).toBe(0);
  });
});

describe('counts toward — a Compound container', () => {
  async function seedBox(): Promise<void> {
    await db.tasks.bulkPut([
      rootTask(),
      copyTask(),
      task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, ...flagged() }),
      task(CHILD_A),
      task(CHILD_B),
    ]);
    await db.compoundChildren.bulkPut([link('l-a', BOX, CHILD_A, 0), link('l-b', BOX, CHILD_B, 1)]);
    await db.boards.bulkPut([board(OCT, OCT_START, OCT_END), board(WEEK, WEEK_START, WEEK_END)]);
    await db.boardTasks.bulkPut([placement('bt-box', OCT, BOX), placement('bt-copy', WEEK, COPY)]);
  }

  it('counts once both sub-tasks are done, keyed by the later child’s event and stamped at it', async () => {
    await seedBox();
    vi.setSystemTime(new Date('2026-10-13T08:00:00.000Z'));
    await toggleTaskCompletionAndCascade(CHILD_A);
    expect(await liveCredits()).toHaveLength(0);

    vi.setSystemTime(new Date('2026-10-15T20:00:00.000Z'));
    await toggleTaskCompletionAndCascade(CHILD_B);
    const [b] = await liveEventsOf(CHILD_B);
    expect(await liveCredits()).toMatchObject([{ id: childCredit(BOX, b.id), taskId: ROOT, delta: 1, occurredAt: '2026-10-15T20:00:00.000Z' }]);
    expect((await db.boards.get(WEEK))?.completedTasks).toBe(1);
  });

  it('a late log on a closed board completes the container — the credit is stamped at the board’s endDate even though the copy’s window there is sealed', async () => {
    await seedBox();
    const closedStart = '2026-10-01T00:00:00.000Z';
    const closedEnd = '2026-10-07T23:59:59.999Z';
    await db.boards.put(board(CLOSED, closedStart, closedEnd, { sealedAt: '2026-10-08T00:00:01.000Z', sealedCompletedCells: [] }));
    await db.boardTasks.bulkPut([placement('bt-closed', CLOSED, BOX, 1), placement('bt-copy-closed', CLOSED, COPY, 2)]);
    await db.taskEvents.put(completion('ev-a', CHILD_A, '2026-10-03T10:00:00.000Z'));

    await lateLogCompletion(CLOSED, CHILD_B, NOW);

    const [b] = await liveEventsOf(CHILD_B);
    expect(await liveCredits()).toMatchObject([{ id: childCredit(BOX, b.id), taskId: ROOT, occurredAt: new Date(closedEnd).toISOString() }]);
    expect((await db.boards.get(CLOSED))?.sealedCompletedCells).toEqual(expect.arrayContaining([1, 2]));
  });

  it('deleting a sub-task the container needed re-derives it (the credit follows)', async () => {
    await seedBox();
    await db.tasks.update(BOX, { operator: OperatorType.OR });
    await toggleTaskCompletionAndCascade(CHILD_A);
    expect(await liveCredits()).toHaveLength(1);
    await deleteTaskWithCascade(CHILD_A);
    expect(await liveCredits()).toHaveLength(0);
  });

  it('an empty container is allowed only with the flag, and evaluates incomplete; creating it flagged stamps since', async () => {
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
    expect(box.countsTowardSince).toBe(NOW);
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

  it('deleting the counter unflags its contributors (authored, since cleared) and leaves the credits with the root', async () => {
    await seed();
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    await db.syncQueue.clear();
    const versionBefore = (await db.tasks.get(SIMPLE))!.version;
    await deleteCounterWithUnlink(ROOT);

    const simple = (await db.tasks.get(SIMPLE))!;
    expect('countsTowardCounterId' in simple || 'countsTowardSince' in simple).toBe(false);
    expect(simple.version).toBe(versionBefore + 1);
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

  it('a flagged counting task cannot be promoted to a counter', async () => {
    await db.tasks.bulkPut([rootTask(), runTask()]);
    await expect(promoteTaskToCounter(RUN)).rejects.toThrow(/counts toward a counter cannot be a counter/);
    expect((await db.tasks.get(RUN))?.isCounter).toBeUndefined();
  });

  it('setCountsToward validates, then mints at once for a task already done; clearing tombstones', async () => {
    await seed({ countsTowardCounterId: undefined, countsTowardSince: undefined });
    const done = completion('00000000-0000-4000-8000-0000000000f1', SIMPLE, '2026-10-10T10:00:00.000Z');
    await db.taskEvents.put(done);
    await db.tasks.put(task('00000000-0000-4000-8000-0000000000f2', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, isCounter: true, countKind: 'continuous' }));

    await expect(setCountsToward(SIMPLE, '00000000-0000-4000-8000-0000000000f2')).rejects.toBeInstanceOf(CountsTowardError);
    await expect(setCountsToward(SIMPLE, SIMPLE)).rejects.toMatchObject({ code: 'self' });

    await at('2026-10-09T00:00:00.000Z', () => setCountsToward(SIMPLE, ROOT, 2)); // since before the completion
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

  it('pulling a contributor row whose flag another device cleared withdraws its credits here (a compound, keyed on the previous root)', async () => {
    await db.tasks.bulkPut([rootTask(), task(BOX, { type: TaskType.COMPOUND, operator: OperatorType.AND, ...flagged() }), task(CHILD_A)]);
    await db.compoundChildren.put(link('l-a', BOX, CHILD_A, 0));
    await db.boards.put(board(OCT, OCT_START, OCT_END));
    await db.boardTasks.put(placement('bt-box', OCT, BOX));
    await logCompletion(CHILD_A, NOW);
    expect(await liveCredits()).toHaveLength(1);

    const local = (await db.tasks.get(BOX))!;
    const { countsTowardCounterId: _c, countsTowardSince: _s, ...rest } = local;
    const status = await applyRemoteSubdoc('tasks', { ...rest, updatedAt: LATER, version: local.version + 1 }, USER);
    expect(status).toMatch(/Pulled tasks/);

    expect(await liveCredits()).toHaveLength(0);
    expect((await storedCredits()).map((c) => c.version)).toEqual([2]);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
  });

  it('pulling a contributor row another device re-pointed moves its credits to the new root from the new since', async () => {
    await seed();
    await db.tasks.put(root2Task());
    await handleTaskCompletion(OCT, 'bt-simple', { isCompleted: true });
    expect(await liveCredits(ROOT)).toHaveLength(1);

    const local = (await db.tasks.get(SIMPLE))!;
    await applyRemoteSubdoc('tasks', { ...local, countsTowardCounterId: ROOT2, countsTowardSince: T0, updatedAt: LATER, version: local.version + 1 }, USER);

    expect(await liveCredits(ROOT)).toHaveLength(0);
    expect((await storedCredits(ROOT)).map((c) => c.version)).toEqual([2]);
    expect((await liveCredits(ROOT2)).map((c) => c.occurredAt)).toEqual([NOW]);
  });
});
