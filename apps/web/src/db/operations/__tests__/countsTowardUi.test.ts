import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  countsTowardEventId,
  forkTaskId,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import { saveTaskEdit } from '../compoundStructureEdit';
import { CountsTowardError, creditedBoardsForCounter, setCountsToward } from '../countsToward';
import { loadCountsTowardSection } from '../countsTowardSection';
import { handleTaskCompletion } from '../orchestration';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import type { BoardEditTaskOverride } from '../../../hooks/squaresEditReducer';
import { countsTowardCreditPreview } from '../../../hooks/useBoardPlay';

/**
 * "Counts toward" PR 4 — the UI's data seams (docs/SHARED_COUNTER_SETTINGS.md
 * §3d / §5): the Counter Detail section's read model, the Board Edit commit
 * flagging the FORK through `setCountsTowardInTransaction`, `saveTaskEdit`'s
 * set-first / clear-last order, the credited-toast board set and the
 * completion-moment preview. iOS twins: `CountsTowardSectionTests` /
 * `CountsTowardBoardEditTests`.
 */

const USER = 'user-1';
const T0 = '2026-10-01T00:00:00.000Z';
const NOW = '2026-10-08T12:00:00.000Z';
const ROOT = '90000000-0000-4000-8000-0000000000a1';
const ROOT2 = '90000000-0000-4000-8000-0000000000a2';
const COPY = '90000000-0000-4000-8000-0000000000a3';
const DUNE = '90000000-0000-4000-8000-0000000000b1';
const PAGES = '90000000-0000-4000-8000-0000000000b2';
const LOOSE = '90000000-0000-4000-8000-0000000000b3';
const B1 = '90000000-0000-4000-8000-0000000000e1'; // weekly, being edited
const B2 = '90000000-0000-4000-8000-0000000000e2'; // monthly
const B1_START = '2026-10-05T00:00:00.000Z';
const B1_END = '2026-10-11T23:59:59.999Z';
const B2_START = '2026-10-01T00:00:00.000Z';
const B2_END = '2026-10-31T23:59:59.999Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: USER, title: id, type: TaskType.NORMAL, isCompleted: false,
    totalCompletions: 0, totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}
const rootTask = (id = ROOT, over: Partial<Task> = {}): Task =>
  task(id, { title: 'Read 12 books', type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 12, currentCount: 0, isCounter: true, counterName: 'Books', ...over });

function board(id: string, startDate: string, endDate: string, over: Partial<Board> = {}): Board {
  return {
    id, userId: USER, name: id, status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
    startDate, endDate, centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9,
    completedTasks: 0, linesCompleted: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  } as Board;
}
function placement(id: string, boardId: string, taskId: string, col = 0): BoardTask {
  return { id, boardId, taskId, row: 0, col, isCenter: false, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}
function event(id: string, taskId: string, kind: 'completion' | 'increment', occurredAt: string, delta?: number): TaskEvent {
  return { id, userId: USER, taskId, kind, occurredAt, ...(delta !== undefined ? { delta } : {}), createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}
function cell(o: Partial<SquareDraftCell> & Pick<SquareDraftCell, 'cellId' | 'taskId'>): SquareDraftCell {
  return { row: 0, col: 0, isLocked: false, originalTaskId: o.taskId, originalRow: o.row ?? 0, originalCol: o.col ?? 0, originalLocked: false, ...o };
}
function commitInput(cells: SquareDraftCell[], overrides: Array<[string, BoardEditTaskOverride]>): CommitSquareEditsInput {
  return { boardId: B1, cells, removedBoardTaskIds: [], taskOverrides: new Map(overrides), isLegacyChosenOnDisk: false, centerCellKeepLocked: false };
}
const liveCredits = async (rootId = ROOT): Promise<TaskEvent[]> =>
  (await db.taskEvents.where('taskId').equals(rootId).toArray()).filter((e) => !e.isDeleted && e.kind === 'increment');

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date(NOW));
  await db.boards.bulkAdd([board(B1, B1_START, B1_END, { name: 'Reading week' }), board(B2, B2_START, B2_END, { timeframe: Timeframe.MONTHLY, name: 'October' })]);
});

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all([db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue].map((t) => t.clear()));
});

describe('loadCountsTowardSection', () => {
  it('lists one row per contributor with its primary board, state, amount and live credit count', async () => {
    await db.tasks.bulkAdd([
      rootTask(),
      task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(PAGES, { title: 'Read 250 pages', type: TaskType.COUNTING, action: 'Read', unit: 'pages', maxCount: 250, countsTowardCounterId: ROOT, countsTowardAmount: 2, countsTowardSince: T0 }),
      task(LOOSE, { title: 'Audiobook', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task('unrelated', { title: 'Stretch' }),
    ]);
    await db.boardTasks.bulkAdd([placement('bt-dune', B1, DUNE), placement('bt-pages', B1, PAGES, 1)]);
    await db.taskEvents.bulkAdd([
      event('c1', DUNE, 'completion', '2026-10-06T09:00:00.000Z'),
      event('c-old', DUNE, 'completion', '2026-09-29T09:00:00.000Z'),
      event('p1', PAGES, 'increment', '2026-10-06T10:00:00.000Z', 100),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c1' }), ROOT, 'increment', '2026-10-06T09:00:00.000Z', 1),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c-old' }), ROOT, 'increment', '2026-09-29T09:00:00.000Z', 1),
    ]);

    const data = await loadCountsTowardSection(ROOT);
    expect(data.rows).toEqual([
      { taskId: DUNE, status: 'done', boardId: B1, amount: 1, creditCount: 2, latestOccurredAt: '2026-10-06T09:00:00.000Z' },
      { taskId: PAGES, status: 'inProgress', boardId: B1, amount: 2, creditCount: 0, latestOccurredAt: null },
      { taskId: LOOSE, status: 'notStarted', boardId: null, amount: 1, creditCount: 0, latestOccurredAt: null },
    ]);
    expect(data.taskById[DUNE]?.title).toBe('Finish Dune');
    expect(data.boardById[B1]?.name).toBe('Reading week');
  });

  it('is empty with no contributors (no table scans beyond the contributor read)', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune' })]);
    expect(await loadCountsTowardSection(ROOT)).toEqual({ rows: [], taskById: {}, boardById: {} });
  });
});

describe('commitSquareEdits — a staged "Counts toward"', () => {
  it('flags the task in place when it is placed only on this board, stamping `since` and minting the in-window credit', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune' })]);
    await db.boardTasks.add(placement('bt1', B1, DUNE));
    await db.taskEvents.add(event('c1', DUNE, 'completion', '2026-10-06T09:00:00.000Z'));

    await commitSquareEdits(commitInput([cell({ cellId: 'bt1', taskId: DUNE })], [[DUNE, { title: 'Finish Dune', countsToward: { counterId: ROOT, amount: 2 } }]]));

    const dune = (await db.tasks.get(DUNE))!;
    expect(dune).toMatchObject({ countsTowardCounterId: ROOT, countsTowardAmount: 2, countsTowardSince: NOW });
    expect(await db.tasks.get(forkTaskId(B1, DUNE))).toBeUndefined();
    // D11: the completion before `since` never credits.
    expect(await liveCredits()).toHaveLength(0);
  });

  it('forks FIRST when placed elsewhere and flags only the fork; the original keeps no flag', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune' })]);
    await db.boardTasks.bulkAdd([placement('bt1', B1, DUNE), placement('bt2', B2, DUNE)]);

    await commitSquareEdits(commitInput([cell({ cellId: 'bt1', taskId: DUNE })], [[DUNE, { title: 'Finish Dune', countsToward: { counterId: ROOT } }]]));

    const forkId = forkTaskId(B1, DUNE);
    const fork = (await db.tasks.get(forkId))!;
    expect(fork.forkedFromTaskId).toBe(DUNE);
    expect(fork).toMatchObject({ countsTowardCounterId: ROOT, countsTowardSince: NOW });
    expect((await db.boardTasks.get('bt1'))!.taskId).toBe(forkId);
    const original = (await db.tasks.get(DUNE))!;
    expect(original.countsTowardCounterId).toBeUndefined();
    expect((await db.boardTasks.get('bt2'))!.taskId).toBe(DUNE);

    // Completing the forked square now credits the root.
    await handleTaskCompletion(B1, 'bt1', { isCompleted: true });
    expect(await liveCredits()).toHaveLength(1);
  });

  it('clears a staged "None" (the credit is withdrawn) and refuses a bad target inside the transaction', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 })]);
    await db.boardTasks.add(placement('bt1', B1, DUNE));
    await handleTaskCompletion(B1, 'bt1', { isCompleted: true });
    expect(await liveCredits()).toHaveLength(1);

    await commitSquareEdits(commitInput([cell({ cellId: 'bt1', taskId: DUNE })], [[DUNE, { title: 'Finish Dune', countsToward: { counterId: null } }]]));
    expect((await db.tasks.get(DUNE))!.countsTowardCounterId).toBeUndefined();
    expect(await liveCredits()).toHaveLength(0);

    await expect(
      commitSquareEdits(commitInput([cell({ cellId: 'bt1', taskId: DUNE })], [[DUNE, { title: 'Renamed', countsToward: { counterId: DUNE } }]])),
    ).rejects.toBeInstanceOf(CountsTowardError);
    // Atomic: the rename rolled back with the refused flag.
    expect((await db.tasks.get(DUNE))!.title).toBe('Finish Dune');
  });
});

describe('saveTaskEdit — countsToward', () => {
  it('sets the flag before the field write and clears it after; an untouched row writes nothing', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune' })]);

    await saveTaskEdit(DUNE, { title: 'Finish Dune Messiah', countsToward: { counterId: ROOT, amount: 3 } });
    expect((await db.tasks.get(DUNE))!).toMatchObject({ title: 'Finish Dune Messiah', countsTowardCounterId: ROOT, countsTowardAmount: 3, countsTowardSince: NOW });

    const before = (await db.tasks.get(DUNE))!.version;
    await saveTaskEdit(DUNE, { title: 'Finish Dune Messiah' });
    expect((await db.tasks.get(DUNE))!.countsTowardCounterId).toBe(ROOT);

    await saveTaskEdit(DUNE, { title: 'Done with Dune', countsToward: { counterId: null } });
    const after = (await db.tasks.get(DUNE))!;
    expect(after.title).toBe('Done with Dune');
    expect(after.countsTowardCounterId).toBeUndefined();
    expect(after.countsTowardSince).toBeUndefined();
    expect(after.version).toBeGreaterThan(before);
  });

  it('a refused target throws the CountsTowardError before any field is written', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune' })]);
    await expect(saveTaskEdit(DUNE, { title: 'Renamed', countsToward: { counterId: DUNE } })).rejects.toMatchObject({ code: 'self' });
    expect((await db.tasks.get(DUNE))!.title).toBe('Finish Dune');
  });
});

describe('creditedBoardsForCounter', () => {
  it('lists the active creditable boards placing the root or a live copy, minus the completing board', async () => {
    const ended = '90000000-0000-4000-8000-0000000000e3';
    await db.boards.add(board(ended, '2026-09-01T00:00:00.000Z', '2026-09-30T23:59:59.999Z', { name: 'September' }));
    await db.tasks.bulkAdd([
      rootTask(),
      task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 }),
    ]);
    await db.boardTasks.bulkAdd([placement('bt-root', B2, ROOT), placement('bt-copy', B1, COPY), placement('bt-sept', ended, COPY)]);

    expect(await creditedBoardsForCounter(ROOT, B1, new Date(NOW))).toEqual([{ boardId: B2, boardName: 'October' }]);
    expect(await creditedBoardsForCounter(ROOT, null, new Date(NOW))).toHaveLength(2);
    expect(await creditedBoardsForCounter(ROOT2, null, new Date(NOW))).toEqual([]);
  });
});

describe('countsTowardCreditPreview', () => {
  const ctx = { windowStart: B1_START, windowEnd: B1_END, eventsByTaskId: {} as Record<string, TaskEvent[]> };
  const dune = task(DUNE, { countsTowardCounterId: ROOT, countsTowardSince: T0 });
  const pages = task(PAGES, { type: TaskType.COUNTING, maxCount: 250, countsTowardCounterId: ROOT, countsTowardSince: T0 });
  const bts = [placement('bt-dune', B1, DUNE), placement('bt-pages', B1, PAGES, 1)];
  const taskMap = { [DUNE]: dune, [PAGES]: pages };

  it('fires for a Simple square checked off and a Counting square reaching its goal, with the write that puts it back', () => {
    expect(countsTowardCreditPreview('bt-dune', { isCompleted: true }, bts, taskMap, ctx)).toEqual({ task: dune, boardTaskId: 'bt-dune', revert: { isCompleted: false } });
    const withLog = { ...ctx, eventsByTaskId: { [PAGES]: [event('p1', PAGES, 'increment', '2026-10-06T10:00:00.000Z', 100)] } };
    expect(countsTowardCreditPreview('bt-pages', { currentCount: 250 }, bts, taskMap, withLog)).toEqual({ task: pages, boardTaskId: 'bt-pages', revert: { currentCount: 100 } });
  });

  it('stays quiet for an un-complete, an already-complete window, a count below the goal and an unflagged task', () => {
    expect(countsTowardCreditPreview('bt-dune', { isCompleted: false }, bts, taskMap, ctx)).toBeNull();
    const done = { ...ctx, eventsByTaskId: { [DUNE]: [event('c1', DUNE, 'completion', '2026-10-06T09:00:00.000Z')] } };
    expect(countsTowardCreditPreview('bt-dune', { isCompleted: true }, bts, taskMap, done)).toBeNull();
    expect(countsTowardCreditPreview('bt-pages', { currentCount: 200 }, bts, taskMap, ctx)).toBeNull();
    expect(countsTowardCreditPreview('bt-dune', { isCompleted: true }, bts, { [DUNE]: task(DUNE) }, ctx)).toBeNull();
  });
});

describe('setCountsToward (the one write path) — sanity', () => {
  it('refuses a Continuous target with the target-not-discrete code', async () => {
    await db.tasks.bulkAdd([rootTask(ROOT2, { countKind: 'continuous' }), task(DUNE)]);
    await expect(setCountsToward(DUNE, ROOT2)).rejects.toMatchObject({ code: 'target-not-discrete' });
  });
});
