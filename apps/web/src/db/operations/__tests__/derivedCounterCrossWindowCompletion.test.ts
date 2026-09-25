import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  computeBoardGrid,
  derivedTaskId,
  type Board,
  type BoardSource,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { persistWizardBoardRows, type PersistWizardBoardRowsInput } from '../wizardBoard';
import { incrementSharedCounter } from '../tasks.sharedCounter';
import { buildWindowContext } from '../windowContext';
import { reDeriveSealedBoardsByIds, sealBoard } from '../sealing';

/**
 * REPRO — owner report 2026-09-23 (branch bugfix/derived-counter-cross-window-completion):
 * "Completing a shared counter task on a daily board with a counter task pulled
 * in from a weekly board seems to complete the task on the weekly board as well,
 * even if the weekly board has a larger goal count that is not met yet."
 *
 * Production paths only: boards via `persistWizardBoardRows` (the wizard's
 * active-save path, which runs `planDerivedTasks` + mint), increments via
 * `incrementSharedCounter` (what `useBoardPlay.handleSharedCounterIncrement`
 * calls), weekly cell resolved via `computeBoardGrid` + `buildWindowContext`
 * (the unified per-cell resolver the play surface uses).
 */

const USER = 'user-1';
const ROOT = '80000000-0000-4000-8000-000000000001';
const MONTH_SRC = '80000000-0000-4000-8000-000000000002';

// Local-ISO board dates (the web convention).
const WEEK_START = '2026-09-21T00:00:00.000';
const WEEK_END = '2026-09-27T23:59:59.999';
const DAY_START = '2026-09-23T00:00:00.000';
const DAY_END = '2026-09-23T23:59:59.999';
const NOW = new Date('2026-09-23T12:00:00.000'); // local noon, inside both windows

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

function ev(id: string, delta: number, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId: ROOT,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

/** Root counter, goal 20. `history` = lifetime increments logged BEFORE this week. */
async function seedRoot(history: number): Promise<Task> {
  const root: Task = {
    id: ROOT,
    userId: USER,
    title: 'Read 20 pages',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'pages',
    maxCount: 20,
    currentCount: history,
    isCompleted: history >= 20,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-08-01T00:00:00.000Z',
    updatedAt: '2026-08-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(root);
  if (history > 0) await db.taskEvents.add(ev('hist-1', history, '2026-09-10T09:00:00.000'));
  return root;
}

function input(over: Partial<PersistWizardBoardRowsInput>): PersistWizardBoardRowsInput {
  return {
    userId: USER,
    draftBoardId: null,
    isCore: false,
    isRecurringDraft: false,
    status: 'active',
    boardFields: {
      name: 'B',
      boardSize: 3,
      timeframe: Timeframe.WEEKLY,
      startDate: WEEK_START,
      endDate: WEEK_END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
    },
    placement: new Array(9).fill(null),
    size: 3,
    centerType: CenterSquareType.NONE,
    pendingTasks: [],
    sources: [],
    manualTaskIds: [],
    ...over,
  };
}

function boardSource(sourceId: string, memberRules?: BoardSource['memberRules']): BoardSource {
  return {
    sourceId,
    kind: 'board',
    min: 0,
    max: null,
    excludedTaskIds: [],
    filter: 'all',
    ...(memberRules ? { memberRules } : {}),
  } as BoardSource;
}

async function weeklyCellState(weeklyId: string) {
  const board = (await db.boards.get(weeklyId))!;
  const bts = (await db.boardTasks.where('boardId').equals(weeklyId).toArray()).filter(
    (b) => !b.isDeleted,
  );
  const taskById: Record<string, Task> = {};
  for (const t of await db.tasks.toArray()) taskById[t.id] = t;
  const { cells, completedTasks } = computeBoardGrid(
    board,
    bts,
    {},
    taskById,
    await db.boards.toArray(),
    await buildWindowContext(),
  );
  return { board, bts, cells, completedTasks, taskById };
}

async function createDailyPulling(weeklyId: string, member: Task): Promise<string> {
  const placement = new Array(9).fill(null);
  placement[0] = member;
  return persistWizardBoardRows(
    input({
      boardFields: {
        name: 'Daily',
        boardSize: 3,
        timeframe: Timeframe.DAILY,
        startDate: DAY_START,
        endDate: DAY_END,
        centerSquareType: CenterSquareType.NONE,
        isRandomized: false,
      },
      placement,
      sources: [boardSource(weeklyId)],
    }),
  );
}

async function completeDailyAndAssertWeekly(dailyId: string, weeklyId: string, weeklyTaskId: string) {
  const dId = derivedTaskId(dailyId, ROOT);
  const d = (await db.tasks.get(dId))!;
  // Precondition: the daily's member IS a distinct minted row with a smaller target.
  expect(d).toBeDefined();
  expect(d.sharedCounterId).toBe(ROOT);
  expect(d.maxCount).toBe(3); // ceil(20 * 1 / 7)
  const dailyBt = (await db.boardTasks.where('boardId').equals(dailyId).toArray())[0];
  expect(dailyBt.taskId).toBe(dId);

  // Log on the daily cell until it completes (the play surface routes a
  // derived cell to incrementSharedCounter(root)).
  await incrementSharedCounter(ROOT, 3);
  expect((await db.tasks.get(dId))!.isCompleted).toBe(true);
  expect((await db.boards.get(dailyId))!.completedTasks).toBe(1);

  // Weekly: 3 of 20 this week — must NOT be complete.
  const w = await weeklyCellState(weeklyId);
  const weeklyTask = w.taskById[weeklyTaskId];
  const cell = w.cells.find((c) => c.taskId === weeklyTaskId);
  return { weeklyTask, cell, board: w.board, completedTasks: w.completedTasks };
}

describe('REPRO derived counter: completing the daily must not complete the weekly', () => {
  it('variant A0: weekly one-off with hand-added ROOT (goal 20), no prior history', async () => {
    const root = await seedRoot(0);
    const wp = new Array(9).fill(null);
    wp[0] = root;
    const weeklyId = await persistWizardBoardRows(input({ placement: wp, manualTaskIds: [ROOT] }));
    const dailyId = await createDailyPulling(weeklyId, root);
    const r = await completeDailyAndAssertWeekly(dailyId, weeklyId, ROOT);
    expect(r.cell).toBeDefined();
    expect(r.cell!.isCompleted).toBe(false);
    expect(r.board.completedTasks).toBe(0);
    expect(r.completedTasks).toBe(0);
  });

  it('variant A1: weekly one-off with hand-added ROOT, root has lifetime history >= goal (latched)', async () => {
    const root = await seedRoot(25);
    const wp = new Array(9).fill(null);
    wp[0] = root;
    const weeklyId = await persistWizardBoardRows(input({ placement: wp, manualTaskIds: [ROOT] }));
    const dailyId = await createDailyPulling(weeklyId, (await db.tasks.get(ROOT))!);
    const r = await completeDailyAndAssertWeekly(dailyId, weeklyId, ROOT);
    expect(r.cell).toBeDefined();
    expect(r.cell!.isCompleted).toBe(false);
    expect(r.board.completedTasks).toBe(0);
  });

  it.each([0, 25])(
    'variant B (history=%i): weekly member is a window-stamped DERIVED counter (target 20) pulled from a monthly',
    async (history) => {
      await seedRoot(history);
      // Make the root's goal larger than the weekly's so the weekly member is minted.
      await db.tasks.update(ROOT, { maxCount: 80, isCompleted: history >= 80 });
      const monthly: Board = {
        id: MONTH_SRC,
        userId: USER,
        name: 'September',
        status: BoardStatus.ACTIVE,
        boardSize: 3,
        timeframe: Timeframe.MONTHLY,
        startDate: '2026-09-01T00:00:00.000',
        endDate: '2026-09-30T23:59:59.999',
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
      };
      await db.boards.add(monthly);
      await db.boardTasks.add({
        id: 'bt-month',
        boardId: MONTH_SRC,
        taskId: ROOT,
        row: 0,
        col: 0,
        isCenter: false,
        createdAt: monthly.createdAt,
        updatedAt: monthly.createdAt,
        version: 1,
        isDeleted: false,
      });
      const wp = new Array(9).fill(null);
      wp[0] = (await db.tasks.get(ROOT))!;
      const weeklyId = await persistWizardBoardRows(
        input({ placement: wp, sources: [boardSource(MONTH_SRC, { [ROOT]: { target: 20 } })] }),
      );
      const wId = derivedTaskId(weeklyId, ROOT);
      const wRow = (await db.tasks.get(wId))!;
      expect(wRow.maxCount).toBe(20);
      expect(wRow.isCompleted).toBe(false);

      const dailyId = await createDailyPulling(weeklyId, wRow);
      const r = await completeDailyAndAssertWeekly(dailyId, weeklyId, wId);
      expect(r.weeklyTask.isCompleted).toBe(false);
      expect(r.cell).toBeDefined();
      expect(r.cell!.isCompleted).toBe(false);
      expect(r.board.completedTasks).toBe(0);
    },
  );
});

/**
 * THE REPRODUCTION. Today's daily pulls a weekly board, and the log lands
 * after the weekly's window has ENDED while it is still ACTIVE and not yet
 * sealed (the backstop seal only lands min(48h, window/4) = 42h after a
 * weekly's end, lazily on app-open). Since the owner ruling of 2026-09-24 an
 * ended board is never a source, so the pull itself is made on the weekly's
 * last day (planning ahead) — the post-window LOG is what these pins cover.
 *
 * The weekly logged 17 of 20 inside its own window (NOT met). Today the owner
 * logs 3 on the daily's pro-rated derived square. The weekly square then
 * completes: the weekly board has no window END — for a ROOT square
 * `resolveTaskWindowState` sums `[startDate, ∞)`, and for a window-stamped
 * derived square `propagateIncrement` latches from `currentCount - baseline`
 * with no end bound either — so today's logs (made after the weekly ended)
 * count toward last week's goal.
 *
 * Status on fix/derived-counter-window-freeze (Task 3 item 5):
 *  - DERIVED square + SEALED variants are GREEN regression pins: the kernel
 *    resolves a window-stamped row from its root's events inside
 *    `[startDate, endDate]` (bounded at `sealedAt` on a sealed re-derive), and
 *    propagation freezes at the window end, so a post-window log neither
 *    greens the cell nor rewrites the frozen record.
 *  - The ROOT-square variant was an `it.fails` pin while WC Decision 1 was
 *    open (root windows `[startDate, ∞)` until sealed). The owner decided
 *    2026-09-24 (option C): a root square evaluates `[startDate, endDate]`, and
 *    a late log from an ended board's own surface is stamped at its `endDate`.
 *    It is now a GREEN regression pin (fix/root-window-end-bound).
 */
describe('REPRO (bug): daily log completes a PAST-window, unsealed weekly board it pulled from', () => {
  const PAST_WEEK_START = '2026-09-14T00:00:00.000';
  const PAST_WEEK_END = '2026-09-20T23:59:59.999';

  async function buildPastWeekly(member: 'root' | 'derived'): Promise<{ weeklyId: string; weeklyTaskId: string }> {
    vi.setSystemTime(new Date('2026-09-14T09:00:00.000'));
    await seedRoot(0);
    const pastWeekFields: PersistWizardBoardRowsInput['boardFields'] = {
      name: 'Last week',
      boardSize: 3,
      timeframe: Timeframe.WEEKLY,
      startDate: PAST_WEEK_START,
      endDate: PAST_WEEK_END,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
    };
    let weeklyId: string;
    let weeklyTaskId: string;
    if (member === 'root') {
      const wp = new Array(9).fill(null);
      wp[0] = (await db.tasks.get(ROOT))!;
      weeklyId = await persistWizardBoardRows(
        input({ boardFields: pastWeekFields, placement: wp, manualTaskIds: [ROOT] }),
      );
      weeklyTaskId = ROOT;
    } else {
      await db.tasks.update(ROOT, { maxCount: 80 });
      await db.boards.add({
        id: MONTH_SRC,
        userId: USER,
        name: 'September',
        status: BoardStatus.ACTIVE,
        boardSize: 3,
        timeframe: Timeframe.MONTHLY,
        startDate: '2026-09-01T00:00:00.000',
        endDate: '2026-09-30T23:59:59.999',
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
      });
      await db.boardTasks.add({
        id: 'bt-month',
        boardId: MONTH_SRC,
        taskId: ROOT,
        row: 0,
        col: 0,
        isCenter: false,
        createdAt: '2026-09-01T00:00:00.000Z',
        updatedAt: '2026-09-01T00:00:00.000Z',
        version: 1,
        isDeleted: false,
      });
      const wp = new Array(9).fill(null);
      wp[0] = (await db.tasks.get(ROOT))!;
      weeklyId = await persistWizardBoardRows(
        input({
          boardFields: pastWeekFields,
          placement: wp,
          sources: [boardSource(MONTH_SRC, { [ROOT]: { target: 20 } })],
        }),
      );
      weeklyTaskId = derivedTaskId(weeklyId, ROOT);
      expect((await db.tasks.get(weeklyTaskId))!.maxCount).toBe(20);
    }
    // 17 of 20 logged INSIDE last week's window — the weekly goal is NOT met.
    vi.setSystemTime(new Date('2026-09-16T18:00:00.000'));
    await incrementSharedCounter(ROOT, 17);
    const before = await weeklyCellState(weeklyId);
    expect(before.cells.find((c) => c.taskId === weeklyTaskId)!.isCompleted).toBe(false);
    return { weeklyId, weeklyTaskId };
  }

  /**
   * Plans today's daily from the weekly WHILE THE WEEKLY IS STILL OPEN
   * (2026-09-20, its last day) — since the owner ruling of 2026-09-24 an
   * ended board is never a source, so the pull can no longer be made after
   * the weekly ends — then logs on it today (2026-09-23, three days after
   * the weekly ended). `betweenPullAndLog` runs in the gap (the seal).
   */
  async function logTodayOnDaily(
    weeklyId: string,
    member: Task,
    betweenPullAndLog: () => Promise<void> = async () => {},
  ) {
    vi.setSystemTime(new Date('2026-09-20T12:00:00.000'));
    const dailyId = await createDailyPulling(weeklyId, member);
    await betweenPullAndLog();
    vi.setSystemTime(NOW); // 2026-09-23 — three days after the weekly ended
    const dId = derivedTaskId(dailyId, ROOT);
    const d = (await db.tasks.get(dId))!;
    expect(d.maxCount).toBeLessThan(20); // a distinct, pro-rated daily row
    expect((await db.boardTasks.where('boardId').equals(dailyId).toArray())[0].taskId).toBe(dId);
    await incrementSharedCounter(ROOT, d.maxCount!); // complete the daily square
    expect((await db.tasks.get(dId))!.isCompleted).toBe(true);
    return dailyId;
  }

  // Decided 2026-09-24 (WC Decision 1 amendment, option C): a root square's
  // window is `[startDate, endDate]`, so today's daily log no longer reaches
  // last week's board. Was an `it.fails` pin while the decision was open.
  it('weekly square = hand-added ROOT (goal 20): stays incomplete after a post-window daily log', async () => {
    const { weeklyId, weeklyTaskId } = await buildPastWeekly('root');
    await logTodayOnDaily(weeklyId, (await db.tasks.get(ROOT))!);
    const w = await weeklyCellState(weeklyId);
    // Failed before the amendment: 17 (in-window) + 3 (today) summed over
    // [startDate, ∞) = 20 >= 20. Now the end bound keeps the sum at 17.
    expect(w.cells.find((c) => c.taskId === weeklyTaskId)!.isCompleted).toBe(false);
    expect(w.board.completedTasks).toBe(0);
  });

  it('weekly square = window-stamped DERIVED counter (target 20): stays incomplete after a post-window daily log', async () => {
    const { weeklyId, weeklyTaskId } = await buildPastWeekly('derived');
    await logTodayOnDaily(weeklyId, (await db.tasks.get(weeklyTaskId))!);
    const w = await weeklyCellState(weeklyId);
    // Failed on dev: propagateIncrement latched the weekly row (currentCount 20 − baseline 0 >= 20).
    // Now: the ended row is frozen (no latch write) AND the kernel reads the
    // root's in-window sum (17 < 20), so both the row and the cell stay incomplete.
    expect(w.taskById[weeklyTaskId].isCompleted).toBe(false);
    expect(w.cells.find((c) => c.taskId === weeklyTaskId)!.isCompleted).toBe(false);
    expect(w.board.completedTasks).toBe(0);
    // Pin the KERNEL too: a stale latch (a pre-freeze client's write, synced
    // in) must not green the cell — completion comes from the root's events.
    await db.tasks.update(weeklyTaskId, { isCompleted: true });
    const stale = await weeklyCellState(weeklyId);
    expect(stale.cells.find((c) => c.taskId === weeklyTaskId)!.isCompleted).toBe(false);
    expect(stale.completedTasks).toBe(0);
  });

  it('SEALED weekly with a DERIVED square: a pull-path re-derive after the daily log keeps the frozen record (audit finding #1)', async () => {
    const { weeklyId, weeklyTaskId } = await buildPastWeekly('derived');
    await logTodayOnDaily(weeklyId, (await db.tasks.get(weeklyTaskId))!, async () => {
      vi.setSystemTime(new Date('2026-09-22T19:00:00.000')); // past the 42h backstop
      expect(await sealBoard(weeklyId)).toBe(true);
      expect((await db.boards.get(weeklyId))!.sealedCompletedCells ?? []).toEqual([]);
    });
    // On dev the weekly row latched from this post-seal log. Now the ended row
    // is frozen (propagation skips it), so the latch is never written — and
    // even if it were, the re-derive below would not read it.
    expect((await db.tasks.get(weeklyTaskId))!.isCompleted).toBe(false);
    // Pin the KERNEL too, not just the freeze: a latch written by a pre-freeze
    // client and synced in must still not green the sealed record.
    await db.tasks.update(weeklyTaskId, { isCompleted: true });
    await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      () => reDeriveSealedBoardsByIds([weeklyId]),
    );
    // Failed on dev: the re-derive read the latch → sealed history rewritten.
    // Now it reads the root's events bounded at `sealedAt` → unchanged.
    expect((await db.boards.get(weeklyId))!.sealedCompletedCells ?? []).toEqual([]);
  });
});
