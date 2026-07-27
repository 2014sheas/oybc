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
import { updateBoardAndCascade, type UpdateActiveBoardPatch } from '../boards';

/**
 * bugfix/edit-preserves-board-window — regression coverage for the
 * BoardEditPanel Save fix (apps/web/src/components/boardEdit/BoardEditPanel.tsx,
 * "Timeframe + dates" patch block).
 *
 * Bug: Board-Edit Save rewrote `startDate` on EVERY save (indefinite boards
 * re-anchored to today; core-timeframe boards recomputed from today's
 * window). Under Windowed Completion, `startDate` is the completion
 * window's lower bound (`[startDate, ∞)`) — rewriting it on a metadata-only
 * edit (e.g. renaming the board) silently re-windows the board and makes
 * every completion event that predates the new start invisible, wiping the
 * user's progress even though nothing about the task's completion changed.
 *
 * Fix: the panel now omits `startDate`/`endDate` from the patch unless the
 * user actually changed the timeframe or (for CUSTOM) the explicit dates.
 * `updateBoardAndCascade`'s `sanitized.startDate` write is already
 * conditioned on `patch.startDate != null` (apps/web/src/db/operations/boards.ts
 * — `if (patch.startDate != null) sanitized.startDate = patch.startDate;`),
 * so an omitted `startDate` in the patch is what actually preserves the
 * stored window at the DB layer. These tests exercise `updateBoardAndCascade`
 * directly (the real op — no mocking) with both patch shapes to pin:
 *   1. the FIXED shape (dates omitted) preserves window + completions,
 *   2. the PRE-FIX shape (dates always written) — documented as still
 *      correct/reachable, but ONLY for a deliberate timeframe change,
 *   3. a genuine timeframe change legitimately re-windows (intentional),
 *   4. CUSTOM boards: edited dates re-window, untouched dates preserve.
 */

function daysAgoISO(days: number): string {
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
}

function daysFromNowISO(days: number): string {
  return new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
}

/** Local midnight for "today" — mirrors BoardEditPanel's INDEFINITE re-anchor. */
function todayStartOfDayISO(): string {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

async function seedTask(id: string, occurredAt: string): Promise<void> {
  const task: Task = {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: true,
    completedAt: occurredAt,
    totalCompletions: 1,
    totalInstances: 1,
    createdAt: daysAgoISO(30),
    updatedAt: occurredAt,
    version: 2,
    isDeleted: false,
  };
  await db.tasks.add(task);
  const event: TaskEvent = {
    id: `evt-${id}`,
    userId: 'user-1',
    taskId: id,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
}

async function seedBoard(overrides: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id: 'board-1',
    userId: 'user-1',
    name: 'Original name',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: daysAgoISO(5),
    endDate: daysFromNowISO(2),
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: daysAgoISO(5),
    updatedAt: daysAgoISO(5),
    version: 1,
    isDeleted: false,
    ...overrides,
  };
  await db.boards.add(board);
  return board;
}

async function seedPlacement(id: string, taskId: string, row: number, col: number): Promise<void> {
  const bt: BoardTask = {
    id,
    boardId: 'board-1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: daysAgoISO(5),
    updatedAt: daysAgoISO(5),
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('Board-Edit window preservation (bugfix/edit-preserves-board-window)', () => {
  it('FIXED shape: a metadata-only patch that OMITS dates preserves the stored window and the backdated completion survives', async () => {
    // Board window opened 5 days ago; task completed 2 days ago — well
    // inside the window.
    await seedBoard();
    await seedTask('task-A', daysAgoISO(2));
    await seedPlacement('bt-A', 'task-A', 0, 0);

    const originalStartDate = (await db.boards.get('board-1'))!.startDate;

    // Exactly what the FIXED BoardEditPanel sends for a name-only edit:
    // `patch.timeframe` is always present (unchanged value), but
    // `startDate`/`endDate` are omitted entirely.
    const patch: UpdateActiveBoardPatch = {
      name: 'Renamed board',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.WEEKLY,
    };
    await updateBoardAndCascade('board-1', patch);

    const board = await db.boards.get('board-1');
    expect(board!.name).toBe('Renamed board');
    // The stored window is byte-identical — never touched.
    expect(board!.startDate).toBe(originalStartDate);
    // The backdated completion event is still inside the (preserved) window.
    expect(board!.completedTasks).toBe(1);
  });

  it('PRE-FIX shape (documented): a patch that explicitly re-sends startDate=today WIPES the backdated completion — proves the bug and why the fix omits dates', async () => {
    await seedBoard();
    await seedTask('task-A', daysAgoISO(2));
    await seedPlacement('bt-A', 'task-A', 0, 0);

    // This is the OLD BoardEditPanel behavior: every save recomputed
    // startDate from "today" regardless of whether the timeframe changed.
    // Post-fix, this patch shape is only ever sent when the user actually
    // changes the timeframe (see the next test) — but the DB op itself
    // still honors whatever patch it's given, so this documents the exact
    // mechanism of the original bug.
    const preFixPatch: UpdateActiveBoardPatch = {
      name: 'Renamed board',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.WEEKLY,
      startDate: todayStartOfDayISO(),
      endDate: daysFromNowISO(7),
    };
    await updateBoardAndCascade('board-1', preFixPatch);

    const board = await db.boards.get('board-1');
    // Window re-anchored to today...
    expect(new Date(board!.startDate).toDateString()).toBe(new Date().toDateString());
    // ...and the 2-day-old completion event now predates the window, so the
    // cell reads incomplete and board stats silently lost the progress.
    expect(board!.completedTasks).toBe(0);
  });

  it('a genuine timeframe change (weekly -> indefinite) legitimately re-windows to today — intentional, not a regression', async () => {
    await seedBoard();
    await seedTask('task-A', daysAgoISO(2));
    await seedPlacement('bt-A', 'task-A', 0, 0);

    // Mirrors BoardEditPanel's `timeframeChanged` branch for INDEFINITE:
    // dayStart anchor, endDate cleared.
    const patch: UpdateActiveBoardPatch = {
      name: 'Original name',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.INDEFINITE,
      startDate: todayStartOfDayISO(),
      endDate: null,
    };
    await updateBoardAndCascade('board-1', patch);

    const board = await db.boards.get('board-1');
    expect(board!.timeframe).toBe(Timeframe.INDEFINITE);
    expect(new Date(board!.startDate).toDateString()).toBe(new Date().toDateString());
    expect(board!.endDate).toBeUndefined();
    // The 2-day-old completion now predates the new (today) window —
    // re-deriving to 0 is the EXPECTED, deliberate consequence of a real
    // timeframe change, not a bug.
    expect(board!.completedTasks).toBe(0);
  });

  it('CUSTOM board: editing the explicit dates re-windows; leaving dates untouched preserves completions', async () => {
    const customStart = daysAgoISO(5);
    const customEnd = daysFromNowISO(5);
    await seedBoard({ timeframe: Timeframe.CUSTOM, startDate: customStart, endDate: customEnd });
    await seedTask('task-A', daysAgoISO(2));
    await seedPlacement('bt-A', 'task-A', 0, 0);

    // 1. Metadata-only save on a CUSTOM board with dates UNCHANGED — the
    //    panel's `customDatesChanged` is false, so dates are omitted.
    await updateBoardAndCascade('board-1', {
      name: 'Renamed once',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.CUSTOM,
    });
    let board = await db.boards.get('board-1');
    expect(board!.startDate).toBe(customStart);
    expect(board!.completedTasks).toBe(1);

    // 2. Now the user deliberately edits the custom start date forward past
    //    the completion — `customDatesChanged` is true, dates ARE sent.
    const newCustomStart = daysAgoISO(1);
    await updateBoardAndCascade('board-1', {
      name: 'Renamed once',
      centerSquareType: CenterSquareType.NONE,
      timeframe: Timeframe.CUSTOM,
      startDate: newCustomStart,
      endDate: customEnd,
    });
    board = await db.boards.get('board-1');
    expect(board!.startDate).toBe(newCustomStart);
    // The completion (2 days ago) now predates the new custom start (1 day
    // ago) — correctly excluded, since the user explicitly moved the window.
    expect(board!.completedTasks).toBe(0);
  });
});
