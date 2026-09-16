import { describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  getTimeframeBoundaries,
  stepWindow,
  type Board,
  type WeekStartDay,
} from '@oybc/shared';
import {
  buildPickerPage,
  buildWindowNeighborhood,
  captionSideLabel,
  chipLabelSuffix,
  describeWindow,
  pickerPageStart,
  pickerPageTitle,
  pickerTileLabel,
  stepPickerPage,
  tileStateFor,
} from './corePickerTiles';

// ─── Fixtures ────────────────────────────────────────────────────────────────

function makeBoard(startDate: string, overrides: Partial<Board> = {}): Board {
  return {
    id: `b-${startDate}`,
    userId: 'u1',
    name: 'Test board',
    timeframe: Timeframe.MONTHLY,
    startDate,
    endDate: null,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    centerSquareType: 'free',
    totalTasks: 9,
    completedTasks: 4,
    linesCompleted: 1,
    completedLineIds: [],
    isCore: true,
    isDeleted: false,
    createdAt: startDate,
    updatedAt: startDate,
    version: 1,
    ...overrides,
  } as unknown as Board;
}

/** A fixed "now" mid-September 2026 for deterministic windows. */
const NOW = new Date(2026, 8, 15, 12, 0, 0);
const MONTHLY_TODAY = getTimeframeBoundaries(Timeframe.MONTHLY, NOW).startDate;

// ─── Neighborhood ────────────────────────────────────────────────────────────

describe('buildWindowNeighborhood', () => {
  it('returns 5 dots with offsets −2…+2, flags displayed + today + hasBoard', () => {
    const boards = new Map<string, Board>([[MONTHLY_TODAY, makeBoard(MONTHLY_TODAY)]]);
    const dots = buildWindowNeighborhood(
      Timeframe.MONTHLY, MONTHLY_TODAY, MONTHLY_TODAY, boards, 'monday',
    );
    expect(dots).toHaveLength(5);
    expect(dots.map((d) => d.offset)).toEqual([-2, -1, 0, 1, 2]);
    const center = dots[2];
    expect(center.isDisplayed).toBe(true);
    expect(center.isToday).toBe(true);
    expect(center.hasBoard).toBe(true);
    expect(dots[0].hasBoard).toBe(false);
  });

  it('marks today on a non-displayed dot when paged away', () => {
    const prev = stepWindow(Timeframe.MONTHLY, MONTHLY_TODAY, -1, 'monday').startDate;
    const dots = buildWindowNeighborhood(
      Timeframe.MONTHLY, prev, MONTHLY_TODAY, new Map(), 'monday',
    );
    expect(dots[2].isDisplayed).toBe(true);
    expect(dots[2].isToday).toBe(false);
    expect(dots[3].isToday).toBe(true); // +1 from August = September
  });
});

// ─── Chip suffix ─────────────────────────────────────────────────────────────

describe('chipLabelSuffix', () => {
  it('is "· closed" for a sealed board', () => {
    const sealed = makeBoard(MONTHLY_TODAY, { sealedAt: '2026-09-01T00:00:00' } as Partial<Board>);
    expect(chipLabelSuffix(sealed, false, true)).toBe(' · closed');
  });
  it('is "· next" / "· past" for empty non-current windows', () => {
    expect(chipLabelSuffix(null, false, false)).toBe(' · next');
    expect(chipLabelSuffix(null, false, true)).toBe(' · past');
  });
  it('is empty for the current window or a live board', () => {
    expect(chipLabelSuffix(null, true, false)).toBe('');
    expect(chipLabelSuffix(makeBoard(MONTHLY_TODAY), false, false)).toBe('');
  });
});

// ─── Tile states ─────────────────────────────────────────────────────────────

describe('tileStateFor', () => {
  const b = makeBoard(MONTHLY_TODAY);
  it('maps the six-state table', () => {
    expect(tileStateFor({ ...b, sealedAt: 'x' } as Board, false, true, false)).toBe('closed');
    expect(tileStateFor({ ...b, status: BoardStatus.COMPLETED } as Board, false, true, false)).toBe('done');
    expect(tileStateFor(undefined, false, true, false)).toBe('pastEmpty');
    expect(tileStateFor(b, true, false, false)).toBe('current');
    expect(tileStateFor(undefined, true, false, false)).toBe('current');
    expect(tileStateFor(undefined, false, false, true)).toBe('nextEmpty');
    expect(tileStateFor(undefined, false, false, false)).toBe('futureEmpty');
  });
  it('maps the derived extras: inProgress + draft', () => {
    expect(tileStateFor(b, false, false, false)).toBe('inProgress');
    expect(tileStateFor({ ...b, status: BoardStatus.DRAFT } as Board, true, false, false)).toBe('draft');
  });
});

// ─── Pages ───────────────────────────────────────────────────────────────────

describe('buildPickerPage', () => {
  it('MONTHLY: builds a 12-tile year page with progress on the current tile', () => {
    const boards = new Map<string, Board>([[MONTHLY_TODAY, makeBoard(MONTHLY_TODAY)]]);
    const page = buildPickerPage(
      Timeframe.MONTHLY, pickerPageStart(Timeframe.MONTHLY, NOW), boards, NOW, 'monday',
    );
    expect(page.tiles).toHaveLength(12);
    expect(page.title).toBe('2026');
    const current = page.tiles.find((t) => t.isCurrent);
    expect(current?.label).toBe('Sep');
    expect(current?.state).toBe('current');
    expect(current?.progress).toEqual({ done: 4, total: 9 });
    // October is the empty +1 window.
    expect(page.tiles[9].state).toBe('nextEmpty');
    // November is further future.
    expect(page.tiles[10].state).toBe('futureEmpty');
    // January is a past empty window.
    expect(page.tiles[0].state).toBe('pastEmpty');
  });

  it('DAILY: builds a month page with weekday-aligned leading blanks', () => {
    const page = buildPickerPage(
      Timeframe.DAILY, pickerPageStart(Timeframe.DAILY, NOW), new Map(), NOW, 'monday',
    );
    expect(page.tiles).toHaveLength(30); // September
    expect(page.title).toBe('September 2026');
    // Sep 1 2026 is a Tuesday → 1 leading blank with Monday start.
    expect(page.leadingBlanks).toBe(1);
    expect(page.tiles[0].label).toBe('1');
  });

  it('WEEKLY: builds a quarter of weeks whose starts fall in the quarter', () => {
    const page = buildPickerPage(
      Timeframe.WEEKLY, pickerPageStart(Timeframe.WEEKLY, NOW), new Map(), NOW, 'monday',
    );
    expect(page.title).toBe('Q3 2026');
    expect(page.tiles.length).toBeGreaterThanOrEqual(12);
    expect(page.tiles.length).toBeLessThanOrEqual(14);
    for (const t of page.tiles) {
      expect(t.windowStart >= '2026-07-01').toBe(true);
      expect(t.windowStart < '2026-10-01').toBe(true);
    }
  });

  it('YEARLY: builds a 10-tile decade page', () => {
    const page = buildPickerPage(
      Timeframe.YEARLY, pickerPageStart(Timeframe.YEARLY, NOW), new Map(), NOW, 'monday',
    );
    expect(page.tiles).toHaveLength(10);
    expect(page.title).toBe('2020 – 2029');
    expect(page.tiles[0].label).toBe('2020');
  });
});

// ─── Labels + paging ─────────────────────────────────────────────────────────

describe('labels + page stepping', () => {
  it('pickerTileLabel per timeframe', () => {
    expect(pickerTileLabel(Timeframe.MONTHLY, '2026-09-01T00:00:00')).toBe('Sep');
    expect(pickerTileLabel(Timeframe.YEARLY, '2026-01-01T00:00:00')).toBe('2026');
    expect(pickerTileLabel(Timeframe.DAILY, '2026-09-05T00:00:00')).toBe('5');
    expect(pickerTileLabel(Timeframe.WEEKLY, '2026-09-14T00:00:00')).toBe('Sep 14 – 20');
  });
  it('captionSideLabel per timeframe', () => {
    expect(captionSideLabel(Timeframe.MONTHLY, '2026-08-01T00:00:00')).toBe('August');
    expect(captionSideLabel(Timeframe.DAILY, '2026-09-14T00:00:00')).toBe('Sep 14');
    expect(captionSideLabel(Timeframe.YEARLY, '2027-01-01T00:00:00')).toBe('2027');
  });
  it('stepPickerPage steps by the page period', () => {
    const y = pickerPageStart(Timeframe.MONTHLY, NOW);
    expect(stepPickerPage(Timeframe.MONTHLY, y, 1).getFullYear()).toBe(2027);
    const dec = pickerPageStart(Timeframe.YEARLY, NOW);
    expect(stepPickerPage(Timeframe.YEARLY, dec, -1).getFullYear()).toBe(2010);
    const m = pickerPageStart(Timeframe.DAILY, NOW);
    expect(stepPickerPage(Timeframe.DAILY, m, 1).getMonth()).toBe(9);
    expect(pickerPageTitle(Timeframe.WEEKLY, stepPickerPage(Timeframe.WEEKLY, pickerPageStart(Timeframe.WEEKLY, NOW), 1))).toBe('Q4 2026');
  });
});

describe('describeWindow — role/timing independence (owner report 2026-09-16)', () => {
  const weekStart: WeekStartDay = 'monday';
  const now = new Date('2026-09-16T12:00:00');
  const todayStart = getTimeframeBoundaries(Timeframe.MONTHLY, now, weekStart).startDate;
  const augStart = getTimeframeBoundaries(
    Timeframe.MONTHLY, new Date('2026-08-15T12:00:00'), weekStart,
  ).startDate;

  it('a past window reads isPast regardless of which window is displayed', () => {
    // THE regression: the incoming card used to render hardcoded
    // isPast:false ("Set up"), then flip to isPast:true ("Backfill")
    // the instant the swipe committed. describeWindow takes no
    // "am I displayed?" input at all, so the same window start always
    // produces the same answer.
    const asIncoming = describeWindow(
      Timeframe.MONTHLY, augStart, todayStart, new Map(), weekStart, now,
    );
    const asDisplayed = describeWindow(
      Timeframe.MONTHLY, augStart, todayStart, new Map(), weekStart, now,
    );
    expect(asIncoming.isPast).toBe(true);
    expect(asIncoming).toEqual(asDisplayed);
    expect(asIncoming.chipSuffix).toBe(' · past');
  });

  it('today’s window is current, not past, and carries no suffix', () => {
    const d = describeWindow(
      Timeframe.MONTHLY, todayStart, todayStart, new Map(), weekStart, now,
    );
    expect(d.isCurrent).toBe(true);
    expect(d.isPast).toBe(false);
    expect(d.chipSuffix).toBe('');
  });

  it('a future empty window reads "· next"', () => {
    const octStart = getTimeframeBoundaries(
      Timeframe.MONTHLY, new Date('2026-10-15T12:00:00'), weekStart,
    ).startDate;
    const d = describeWindow(
      Timeframe.MONTHLY, octStart, todayStart, new Map(), weekStart, now,
    );
    expect(d.isPast).toBe(false);
    expect(d.chipSuffix).toBe(' · next');
  });

  it('splits playable vs draft boards and keeps the sealed suffix', () => {
    const base = {
      id: 'b1', userId: 'u1', name: 'Aug', boardSize: 3,
      timeframe: Timeframe.MONTHLY, startDate: augStart, endDate: augStart,
      centerSquareType: CenterSquareType.NONE, isRandomized: true, isCore: true,
      totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [],
      createdAt: augStart, updatedAt: augStart, version: 1, isDeleted: false,
    };
    const draft = describeWindow(
      Timeframe.MONTHLY, augStart, todayStart,
      new Map([[augStart, { ...base, status: BoardStatus.DRAFT } as Board]]),
      weekStart, now,
    );
    expect(draft.isDraft).toBe(true);
    expect(draft.playableBoard).toBeNull();

    const sealed = describeWindow(
      Timeframe.MONTHLY, augStart, todayStart,
      new Map([[augStart, { ...base, status: BoardStatus.COMPLETED, sealedAt: augStart } as Board]]),
      weekStart, now,
    );
    expect(sealed.chipSuffix).toBe(' · closed');
    expect(sealed.playableBoard).not.toBeNull();
  });
});
