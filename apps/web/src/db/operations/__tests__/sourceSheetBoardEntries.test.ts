import { afterEach, describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, Timeframe, type Board } from '@oybc/shared';
import { db } from '../../internal';
import { fetchSourceSheetBoardEntries } from '../boardSources';

/**
 * The "Add from a pool or board" sheet's board rows.
 *
 * Owner-reported (2026-09-16, with a screenshot): the sheet showed four
 * boards all named "Today" plus a "June 2026" board months out of window.
 * Both fixes had landed on the since-retired `fetchEligibleSourceBoards` (the
 * old "From a board…" grid picker, removed in Plan A) — while this sheet
 * has its own fetcher that filtered on `status === ACTIVE` alone and
 * returned the raw board.
 *
 * These tests assert what the FETCHER ACTUALLY RETURNS, because the
 * helpers were correct all along; nothing called them here.
 */

const USER = 'user-1';
const DAY = 24 * 60 * 60 * 1000;

/** ISO timestamp `days` before now. */
function daysAgo(days: number): string {
  return new Date(Date.now() - days * DAY).toISOString();
}

/** ISO timestamp `days` ahead of now. */
function daysAhead(days: number): string {
  return new Date(Date.now() + days * DAY).toISOString();
}

async function seedBoard(over: Partial<Board> & { id: string }): Promise<void> {
  await db.boards.add({
    userId: USER,
    name: 'Board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: daysAgo(1),
    endDate: daysAhead(5),
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: daysAgo(1),
    updatedAt: daysAgo(1),
    version: 1,
    isDeleted: false,
    ...over,
  } as Board);
}

afterEach(async () => {
  await db.boards.clear();
  await db.boardTasks.clear();
});

describe('fetchSourceSheetBoardEntries', () => {
  it('heals a frozen "Today" name — the sheet rows and its search read this', async () => {
    await seedBoard({
      id: 'core-1',
      name: 'Today',
      isCore: true,
      startDate: '2026-03-15T00:00:00.000',
      endDate: daysAhead(5), // still in window so eligibility can't hide it
    });

    const entries = await fetchSourceSheetBoardEntries(USER);

    expect(entries).toHaveLength(1);
    expect(entries[0].board.name).toBe('Mar 15, 2026');
  });

  it('gives two boards frozen as "Today" DIFFERENT names', async () => {
    // The screenshot showed four indistinguishable "Today" rows.
    await seedBoard({
      id: 'a', name: 'Today', isCore: true,
      startDate: '2026-03-15T00:00:00.000', endDate: daysAhead(5),
    });
    await seedBoard({
      id: 'b', name: 'Today', isCore: true,
      startDate: '2026-03-16T00:00:00.000', endDate: daysAhead(5),
    });

    const names = (await fetchSourceSheetBoardEntries(USER))
      .map((e) => e.board.name)
      .sort();

    expect(names).toEqual(['Mar 15, 2026', 'Mar 16, 2026']);
    expect(new Set(names).size).toBe(2);
  });

  it('EXCLUDES an active board whose window closed months ago', async () => {
    // The "June 2026" row: still ACTIVE because it was never finished,
    // so the old `status === ACTIVE` filter kept offering it forever.
    await seedBoard({
      id: 'stale', name: 'June 2026', timeframe: Timeframe.MONTHLY,
      startDate: daysAgo(100), endDate: daysAgo(70),
    });

    expect(await fetchSourceSheetBoardEntries(USER)).toHaveLength(0);
  });

  // Owner ruling 2026-09-24 (supersedes #482's 30-day lookback): "There is
  // no REAL use case for ended boards as sources."
  it('EXCLUDES an active board whose window closed yesterday (no lookback)', async () => {
    await seedBoard({
      id: 'last-week', name: 'Last week', timeframe: Timeframe.WEEKLY,
      startDate: daysAgo(8), endDate: daysAgo(1),
    });

    expect(await fetchSourceSheetBoardEntries(USER)).toHaveLength(0);
  });

  it('EXCLUDES a sealed board', async () => {
    await seedBoard({ id: 'sealed', name: 'Sealed', sealedAt: daysAgo(0) });

    expect(await fetchSourceSheetBoardEntries(USER)).toHaveLength(0);
  });

  it('keeps an active board whose window is still open', async () => {
    await seedBoard({ id: 'live', name: 'Live' });
    const entries = await fetchSourceSheetBoardEntries(USER);
    expect(entries.map((e) => e.board.id)).toEqual(['live']);
  });

  it('keeps an indefinite board (no end date)', async () => {
    await seedBoard({ id: 'ongoing', name: 'Ongoing', endDate: undefined });
    const entries = await fetchSourceSheetBoardEntries(USER);
    expect(entries.map((e) => e.board.id)).toEqual(['ongoing']);
  });

  it('admits a COMPLETED board only while its window is open', async () => {
    await seedBoard({
      id: 'done-open', name: 'Finished, still open', status: BoardStatus.COMPLETED,
      completedAt: daysAgo(0),
    });
    await seedBoard({
      id: 'done-ended', name: 'Finished, ended', status: BoardStatus.COMPLETED,
      completedAt: daysAgo(3), endDate: daysAgo(2),
    });

    const entries = await fetchSourceSheetBoardEntries(USER);
    expect(entries.map((e) => e.board.id)).toEqual(['done-open']);
  });

  it('judges "ended" against the injected now', async () => {
    await seedBoard({ id: 'live', name: 'Live' }); // ends in 5 days
    const later = new Date(Date.now() + 6 * DAY);
    expect(await fetchSourceSheetBoardEntries(USER, later)).toHaveLength(0);
  });

  it('still excludes drafts and archived boards', async () => {
    await seedBoard({ id: 'draft', status: BoardStatus.DRAFT });
    await seedBoard({ id: 'archived', status: BoardStatus.ARCHIVED });

    expect(await fetchSourceSheetBoardEntries(USER)).toHaveLength(0);
  });

  it("does not return another user's boards", async () => {
    await seedBoard({ id: 'mine' });
    await seedBoard({ id: 'theirs', userId: 'user-2' });

    const entries = await fetchSourceSheetBoardEntries(USER);
    expect(entries.map((e) => e.board.id)).toEqual(['mine']);
  });
});
