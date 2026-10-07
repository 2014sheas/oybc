import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  resolveLinkedCounterDisplay,
  type Board,
  type BoardTask,
  type CountKind,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  KindGoalError,
  applyKindSwitchThenGoalGuard,
  previewCounterKindSwitch,
  switchCounterKind,
} from '../countKindSwitch';
import { createTask } from '../tasks.crud';

/**
 * Counter kinds — the root kind switch + family cascade (docs/COUNTER_KINDS.md
 * D4/D5, Review Focus #2 / #3). Setup follows
 * `sharedCounterPropagationFreeze.test.ts`: a root, an in-window derived row
 * (live) and an ended derived row (frozen), each placed on its own board.
 */

const USER = 'user-1';
const NOW = new Date('2026-09-23T12:00:00.000Z');
const SEEDED = '2026-09-01T08:00:00.000Z';
const ROOT = 'root-1';
const LIVE = 'derived-live';
const ENDED = 'derived-ended';
const BOARD_LIVE = 'board-live';
const BOARD_ENDED = 'board-ended';
const LIVE_WINDOW = { startDate: '2026-09-21T00:00:00.000Z', endDate: '2026-09-27T23:59:59.999Z' };
const ENDED_WINDOW = { startDate: '2026-09-14T00:00:00.000Z', endDate: '2026-09-20T23:59:59.999Z' };

interface FamilyOptions {
  countKind: CountKind;
  rootGoal: number;
  liveTarget?: number;
  endedTarget?: number;
  /** Root increments, all logged inside the live window. */
  deltas?: number[];
}

function counting(id: string, over: Partial<Task>): Task {
  return {
    id,
    userId: USER,
    title: 'Run',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function derived(id: string, maxCount: number, kind: CountKind, window: typeof LIVE_WINDOW): Task {
  return counting(id, {
    maxCount,
    countKind: kind,
    sharedCounterId: ROOT,
    baseline: 0,
    createdInWizard: true,
    timeframe: Timeframe.WEEKLY,
    version: 4,
    ...window,
  });
}

async function seedBoard(id: string, window: typeof LIVE_WINDOW, taskId: string): Promise<void> {
  const board: Board = {
    id,
    userId: USER,
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    ...window,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
  };
  await db.boards.add(board);
  const bt: BoardTask = {
    id: `bt-${id}`,
    boardId: id,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

async function seedFamily(opts: FamilyOptions): Promise<void> {
  const deltas = opts.deltas ?? [];
  const lifetime = deltas.reduce((a, b) => a + b, 0);
  await db.tasks.add(
    counting(ROOT, { maxCount: opts.rootGoal, countKind: opts.countKind, currentCount: lifetime, defaultLogAmount: 1 }),
  );
  await db.tasks.add(derived(LIVE, opts.liveTarget ?? 6, opts.countKind, LIVE_WINDOW));
  await db.tasks.add(derived(ENDED, opts.endedTarget ?? 6, opts.countKind, ENDED_WINDOW));
  await seedBoard(BOARD_LIVE, LIVE_WINDOW, LIVE);
  await seedBoard(BOARD_ENDED, ENDED_WINDOW, ENDED);
  for (const [i, delta] of deltas.entries()) {
    const at = `2026-09-22T0${i}:00:00.000Z`;
    const event: TaskEvent = {
      id: `ev-${i}`,
      userId: USER,
      taskId: ROOT,
      kind: 'increment',
      delta,
      occurredAt: at,
      createdAt: at,
      updatedAt: at,
      version: 1,
      isDeleted: false,
    } as TaskEvent;
    await db.taskEvents.add(event);
  }
}

/** What the live row's cell shows: the root's in-window sum, finalised by the row's kind. */
async function displayedCountFor(rowId: string): Promise<number> {
  const row = (await db.tasks.get(rowId))!;
  const events = await db.taskEvents.toArray();
  const byTask: Record<string, TaskEvent[]> = {};
  for (const e of events) (byTask[e.taskId] ??= []).push(e);
  return resolveLinkedCounterDisplay(row, byTask, null, LIVE_WINDOW).displayed;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
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

describe('switchCounterKind', () => {
  it('continuous → discrete rounds root and live family, frozen row and events untouched', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1, endedTarget: 6.4, deltas: [0.4, 0.4, 0.4] });
    const eventsBefore = await db.taskEvents.toArray();
    const endedBefore = await db.tasks.get(ENDED);

    await switchCounterKind(ROOT, 'discrete', NOW);

    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'discrete', maxCount: 26, defaultLogAmount: 1, version: 2 });
    expect(await db.tasks.get(LIVE)).toMatchObject({ countKind: 'discrete', maxCount: 6, version: 5 });
    expect(await db.tasks.get(ENDED)).toEqual(endedBefore);
    expect(await db.taskEvents.toArray()).toEqual(eventsBefore);
  });

  it('round trip restores the exact window count', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1, deltas: [0.4, 0.4, 0.4] });
    expect(await displayedCountFor(LIVE)).toBe(1.2);

    await switchCounterKind(ROOT, 'discrete', NOW);
    expect(await displayedCountFor(LIVE)).toBe(1);

    await switchCounterKind(ROOT, 'continuous', NOW);
    expect(await displayedCountFor(LIVE)).toBe(1.2);
    // The goals rounded on the way down stay whole on the way back up.
    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'continuous', maxCount: 26 });
    expect(await db.tasks.get(LIVE)).toMatchObject({ countKind: 'continuous', maxCount: 6 });
  });

  it('restamps the lifetime caches from events at the goal line, both directions', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1, deltas: [25.6] });

    await switchCounterKind(ROOT, 'discrete', NOW);
    // 25.6 rounds to 26 against the rounded goal 26 → complete.
    expect(await db.tasks.get(ROOT)).toMatchObject({ maxCount: 26, isCompleted: true, currentCount: 26 });

    await switchCounterKind(ROOT, 'continuous', NOW);
    expect(await db.tasks.get(ROOT)).toMatchObject({ maxCount: 26, isCompleted: false, currentCount: 25.6 });
  });

  it('refuses duration in either direction, a no-op switch, linked rows and non-counters — writing nothing', async () => {
    await seedFamily({ countKind: 'discrete', rootGoal: 30 });
    await db.tasks.add(counting('normal-1', { type: TaskType.NORMAL }));
    await db.tasks.add(counting('dur-root', { maxCount: 30, countKind: 'duration' }));

    await expect(switchCounterKind(ROOT, 'duration', NOW)).rejects.toMatchObject({ code: 'refused' });
    await expect(switchCounterKind('dur-root', 'discrete', NOW)).rejects.toMatchObject({ code: 'refused' });
    await expect(switchCounterKind(ROOT, 'discrete', NOW)).rejects.toMatchObject({ code: 'refused' });
    await expect(switchCounterKind(LIVE, 'continuous', NOW)).rejects.toMatchObject({ code: 'not-a-root' });
    await expect(switchCounterKind('normal-1', 'continuous', NOW)).rejects.toMatchObject({ code: 'not-counting' });
    await expect(switchCounterKind('missing', 'continuous', NOW)).rejects.toMatchObject({ code: 'not-counting' });

    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'discrete', maxCount: 30, version: 1 });
    expect((await db.tasks.get('dur-root'))!.countKind).toBe('duration');
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('enqueues one task UPDATE per written row (root + live only) and writes discrete explicitly', async () => {
    await seedFamily({ countKind: 'discrete', rootGoal: 30, liveTarget: 5 });
    await db.tasks.update(ROOT, { countKind: undefined }); // pre-feature root: absent ⇒ discrete

    await switchCounterKind(ROOT, 'continuous', NOW);
    await switchCounterKind(ROOT, 'discrete', NOW);

    const taskItems = (await db.syncQueue.toArray()).filter((i) => i.entityType === 'tasks');
    expect(taskItems.map((i) => i.entityId).sort()).toEqual([ROOT, LIVE].sort());
    const root = await db.tasks.get(ROOT);
    expect(root!.countKind).toBe('discrete');
    expect(root!.version).toBe(3);
    expect(JSON.parse(taskItems.find((i) => i.entityId === ROOT)!.payload as string)).toMatchObject({
      countKind: 'discrete',
      version: 3,
    });
  });
});

describe('linked rows carry the root kind (D5)', () => {
  it('createTask linked to a continuous root yields a continuous row', async () => {
    await db.tasks.add(counting(ROOT, { maxCount: 26.2, countKind: 'continuous', currentCount: 1.2 }));

    const linked = await createTask(USER, {
      title: 'Run 5 km',
      type: TaskType.COUNTING,
      action: 'Run',
      unit: 'km',
      maxCount: 5,
      sharedCounterId: ROOT,
      baseline: 1.2,
    });

    expect((await db.tasks.get(linked.id))!.countKind).toBe('continuous');
    expect(linked.countKind).toBe('continuous');
  });
});

describe('previewCounterKindSwitch', () => {
  it('continuous → discrete: rounded logged, custom title kept, live linked count only', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, deltas: [12.75] });
    expect(await previewCounterKindSwitch(ROOT, 'discrete', NOW)).toEqual({
      from: 'continuous', to: 'discrete', titleBefore: 'Run', titleAfter: 'Run',
      loggedBefore: 12.75, loggedAfter: 13, linkedCount: 1, // LIVE counts, ENDED is frozen
    });
  });
  it('an auto title regenerates at the rounded goal', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, deltas: [] });
    await db.tasks.update(ROOT, { title: 'Run 26.2 km' });
    expect((await previewCounterKindSwitch(ROOT, 'discrete', NOW))?.titleAfter).toBe('Run 26 km');
  });
  it('refused switches and linked rows preview null', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2 });
    expect(await previewCounterKindSwitch(ROOT, 'duration', NOW)).toBeNull();
    expect(await previewCounterKindSwitch(LIVE, 'discrete', NOW)).toBeNull();
  });
});

describe('applyKindSwitchThenGoalGuard', () => {
  const TABLES = () => [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue];
  it('switches the root and the live family, then accepts a whole goal', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1 });
    const switched = await db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(ROOT, 'discrete', 30, NOW.toISOString()));
    expect(switched).toBe(true);
    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'discrete', maxCount: 26 });
    expect((await db.tasks.get(LIVE))?.countKind).toBe('discrete');
  });
  it('a fractional goal at the new whole kind throws AFTER the switch and rolls the switch back', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2 });
    await expect(
      db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(ROOT, 'discrete', 26.5, NOW.toISOString())),
    ).rejects.toBeInstanceOf(KindGoalError);
    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
  });
  it('never switches a linked row; an unchanged kind writes nothing', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2 });
    expect(await db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(LIVE, 'discrete', undefined, NOW.toISOString()))).toBe(false);
    expect(await db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(ROOT, 'continuous', 26.3, NOW.toISOString()))).toBe(false);
    expect((await db.tasks.get(ROOT))?.version).toBe(1);
    expect((await db.tasks.get(LIVE))?.countKind).toBe('continuous');
  });
});
