import {
  BoardStatus,
  Timeframe,
  getTimeframeBoundaries,
  stepWindow,
  toLocalISO,
  type Board,
  type WeekStartDay,
} from '@oybc/shared';

// ─── Core-window picker + chip model (pure) ──────────────────────────────────
//
// Pure derivation helpers for the core-board surface rework: the window
// chip's position dots, and the picker popover/sheet's calendar-aligned
// tile pages. No DB access — callers pass a `boardsByStart` lookup (the
// user's `isCore` boards for one timeframe, keyed by `Board.startDate`).
//
// Mirrors iOS `CoreWindowPickerModel.swift` — change both together
// (parity rule 6).

const MONTH_ABBREVS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

// ─── Neighborhood (chip + caption dots) ──────────────────────────────────────

/** One position dot in the window chip / caption (offsets −2…+2). */
export interface WindowNeighborhoodDot {
  /** Window offset relative to the displayed window (−2…+2). */
  offset: number;
  /** Local-ISO window start. */
  windowStart: string;
  /** A core board exists for this window. */
  hasBoard: boolean;
  /** This dot is the displayed window (offset 0). */
  isDisplayed: boolean;
  /** This dot is today's (current) window. */
  isToday: boolean;
}

/**
 * Build the ±2-window neighborhood around the displayed window, for the
 * chip's position dots and the under-grid caption dots.
 *
 * @param timeframe - The pager's timeframe.
 * @param windowStart - The displayed window's local-ISO start.
 * @param todayWindowStart - Today's window's local-ISO start.
 * @param boardsByStart - Core boards for this timeframe keyed by startDate.
 * @param weekStartDay - First day of week (WEEKLY stepping).
 */
export function buildWindowNeighborhood(
  timeframe: Timeframe,
  windowStart: string,
  todayWindowStart: string,
  boardsByStart: ReadonlyMap<string, Board>,
  weekStartDay: WeekStartDay,
): WindowNeighborhoodDot[] {
  const dots: WindowNeighborhoodDot[] = [];
  for (let offset = -2; offset <= 2; offset += 1) {
    const start = offset === 0
      ? windowStart
      : stepWindow(timeframe, windowStart, offset, weekStartDay).startDate;
    dots.push({
      offset,
      windowStart: start,
      hasBoard: boardsByStart.has(start),
      isDisplayed: offset === 0,
      isToday: start === todayWindowStart,
    });
  }
  return dots;
}

// ─── Chip label suffix ───────────────────────────────────────────────────────

/**
 * Suffix appended to the chip's window label: "· closed" for a sealed
 * board's window, "· next"/"· past" for an empty non-current window,
 * nothing otherwise.
 */
export function chipLabelSuffix(
  board: Board | null | undefined,
  isCurrentWindow: boolean,
  isPastWindow: boolean,
): string {
  if (board?.sealedAt != null) return ' · closed';
  if (!board && !isCurrentWindow) return isPastWindow ? ' · past' : ' · next';
  return '';
}

// ─── Picker tiles ────────────────────────────────────────────────────────────

/**
 * Visual state of one picker tile — the six-state table from the design
 * spec, plus two derived extras the table implies but does not draw:
 * `inProgress` (a live unsealed board in a non-current window) and
 * `draft` (a draft board's window).
 */
export type CoreWindowTileState =
  | 'closed'       // past, sealed board
  | 'done'         // completed (greenlog) board
  | 'pastEmpty'    // past, no board
  | 'current'      // today's window (gold)
  | 'nextEmpty'    // the +1 window, empty ("set up")
  | 'futureEmpty'  // further future, empty (dim)
  | 'inProgress'   // live board in a non-current window
  | 'draft';       // draft board

/** One tile in the picker grid. */
export interface CoreWindowTile {
  windowStart: string;
  windowEnd: string;
  /** Short in-grid label (day number / "Sep 14 – 20" / "Jan" / "2026"). */
  label: string;
  state: CoreWindowTileState;
  /** Board progress for current/inProgress tiles ("4 of 9"). */
  progress?: { done: number; total: number };
  isCurrent: boolean;
}

/** One picker page: a calendar period of tiles. */
export interface CoreWindowPickerPage {
  /** Page heading chip label ("2026", "Q3 2026", "September 2026", "2020 – 2029"). */
  title: string;
  /** Footer labels for the previous/next page. */
  prevTitle: string;
  nextTitle: string;
  tiles: CoreWindowTile[];
  /** DAILY only: leading blank cells before day 1 in the 7-col grid. */
  leadingBlanks: number;
}

/** Start of the calendar period (page) containing `d` for a timeframe. */
export function pickerPageStart(timeframe: Timeframe, d: Date): Date {
  switch (timeframe) {
    case Timeframe.DAILY:
      return new Date(d.getFullYear(), d.getMonth(), 1);
    case Timeframe.WEEKLY: {
      const quarterMonth = Math.floor(d.getMonth() / 3) * 3;
      return new Date(d.getFullYear(), quarterMonth, 1);
    }
    case Timeframe.MONTHLY:
      return new Date(d.getFullYear(), 0, 1);
    case Timeframe.YEARLY:
      return new Date(Math.floor(d.getFullYear() / 10) * 10, 0, 1);
    default:
      return new Date(d.getFullYear(), 0, 1);
  }
}

/** Step a page anchor by ±1 period. */
export function stepPickerPage(timeframe: Timeframe, pageStart: Date, step: number): Date {
  switch (timeframe) {
    case Timeframe.DAILY:
      return new Date(pageStart.getFullYear(), pageStart.getMonth() + step, 1);
    case Timeframe.WEEKLY:
      return new Date(pageStart.getFullYear(), pageStart.getMonth() + 3 * step, 1);
    case Timeframe.MONTHLY:
      return new Date(pageStart.getFullYear() + step, 0, 1);
    case Timeframe.YEARLY:
      return new Date(pageStart.getFullYear() + 10 * step, 0, 1);
    default:
      return pageStart;
  }
}

/** Exclusive end of the page starting at `pageStart`. */
function pickerPageEnd(timeframe: Timeframe, pageStart: Date): Date {
  return stepPickerPage(timeframe, pageStart, 1);
}

/** Page heading for the page starting at `pageStart`. */
export function pickerPageTitle(timeframe: Timeframe, pageStart: Date): string {
  switch (timeframe) {
    case Timeframe.DAILY:
      return `${MONTH_NAMES[pageStart.getMonth()]} ${pageStart.getFullYear()}`;
    case Timeframe.WEEKLY:
      return `Q${Math.floor(pageStart.getMonth() / 3) + 1} ${pageStart.getFullYear()}`;
    case Timeframe.MONTHLY:
      return `${pageStart.getFullYear()}`;
    case Timeframe.YEARLY:
      return `${pageStart.getFullYear()} – ${pageStart.getFullYear() + 9}`;
    default:
      return '';
  }
}

/** Short tile label for a window inside a picker page. */
export function pickerTileLabel(timeframe: Timeframe, windowStart: string): string {
  const d = new Date(windowStart);
  switch (timeframe) {
    case Timeframe.DAILY:
      return `${d.getDate()}`;
    case Timeframe.WEEKLY: {
      const end = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 6);
      if (d.getMonth() === end.getMonth()) {
        return `${MONTH_ABBREVS[d.getMonth()]} ${d.getDate()} – ${end.getDate()}`;
      }
      return `${MONTH_ABBREVS[d.getMonth()]} ${d.getDate()} – ${MONTH_ABBREVS[end.getMonth()]} ${end.getDate()}`;
    }
    case Timeframe.MONTHLY:
      return MONTH_ABBREVS[d.getMonth()];
    case Timeframe.YEARLY:
      return `${d.getFullYear()}`;
    default:
      return '';
  }
}

/**
 * Short label for the position caption's side taps ("‹ August" /
 * "October ›"): month name for MONTHLY, "Sep 14" for DAILY,
 * "Sep 14 – 20" for WEEKLY, the year for YEARLY.
 */
export function captionSideLabel(timeframe: Timeframe, windowStart: string): string {
  const d = new Date(windowStart);
  switch (timeframe) {
    case Timeframe.DAILY:
      return `${MONTH_ABBREVS[d.getMonth()]} ${d.getDate()}`;
    case Timeframe.WEEKLY:
      return pickerTileLabel(timeframe, windowStart);
    case Timeframe.MONTHLY:
      return MONTH_NAMES[d.getMonth()];
    case Timeframe.YEARLY:
      return `${d.getFullYear()}`;
    default:
      return '';
  }
}

/** Kicker/footer word pairs per timeframe ("Jump to a month", "Monthly boards"). */
export function pickerCopy(timeframe: Timeframe): { kicker: string; title: string } {
  switch (timeframe) {
    case Timeframe.DAILY:   return { kicker: 'Daily boards', title: 'Jump to a day' };
    case Timeframe.WEEKLY:  return { kicker: 'Weekly boards', title: 'Jump to a week' };
    case Timeframe.MONTHLY: return { kicker: 'Monthly boards', title: 'Jump to a month' };
    case Timeframe.YEARLY:  return { kicker: 'Yearly boards', title: 'Jump to a year' };
    default:                return { kicker: 'Core boards', title: 'Jump to a window' };
  }
}

/** "Today · September"-style footer label. */
export function pickerTodayLabel(timeframe: Timeframe, now: Date): string {
  switch (timeframe) {
    case Timeframe.DAILY:
      return `Today · ${MONTH_ABBREVS[now.getMonth()]} ${now.getDate()}`;
    case Timeframe.WEEKLY:
      return 'Today · this week';
    case Timeframe.MONTHLY:
      return `Today · ${MONTH_NAMES[now.getMonth()]}`;
    case Timeframe.YEARLY:
      return `Today · ${now.getFullYear()}`;
    default:
      return 'Today';
  }
}

/** Map one window (+ board lookup) to its tile state. */
export function tileStateFor(
  board: Board | undefined,
  isCurrent: boolean,
  isPast: boolean,
  isNext: boolean,
): CoreWindowTileState {
  if (board) {
    if (board.sealedAt != null) return 'closed';
    if (board.status === BoardStatus.COMPLETED) return 'done';
    if (board.status === BoardStatus.DRAFT) return 'draft';
    return isCurrent ? 'current' : 'inProgress';
  }
  if (isCurrent) return 'current';
  if (isPast) return 'pastEmpty';
  if (isNext) return 'nextEmpty';
  return 'futureEmpty';
}

/**
 * Build one picker page of tiles for the calendar period containing
 * `pageStart`.
 *
 * @param timeframe - Window granularity (DAILY/WEEKLY/MONTHLY/YEARLY).
 * @param pageStart - Start of the page period (from `pickerPageStart`).
 * @param boardsByStart - Core boards for this timeframe keyed by startDate.
 * @param now - Reference instant for current/past flags.
 * @param weekStartDay - First day of week.
 */
export function buildPickerPage(
  timeframe: Timeframe,
  pageStart: Date,
  boardsByStart: ReadonlyMap<string, Board>,
  now: Date,
  weekStartDay: WeekStartDay,
): CoreWindowPickerPage {
  const pageEnd = pickerPageEnd(timeframe, pageStart);
  const pageStartISO = toLocalISO(pageStart);
  const pageEndISO = toLocalISO(pageEnd);

  const todayStart = getTimeframeBoundaries(timeframe, now, weekStartDay).startDate;
  const nextStart = stepWindow(timeframe, todayStart, 1, weekStartDay).startDate;

  // First window whose START falls inside the page period.
  let win = getTimeframeBoundaries(timeframe, pageStart, weekStartDay);
  while (win.startDate < pageStartISO) {
    win = stepWindow(timeframe, win.startDate, 1, weekStartDay);
  }

  const tiles: CoreWindowTile[] = [];
  while (win.startDate < pageEndISO) {
    const board = boardsByStart.get(win.startDate);
    const isCurrent = win.startDate === todayStart;
    const isPast = win.endDate < toLocalISO(now);
    const state = tileStateFor(board, isCurrent, isPast, win.startDate === nextStart);
    tiles.push({
      windowStart: win.startDate,
      windowEnd: win.endDate,
      label: pickerTileLabel(timeframe, win.startDate),
      state,
      progress:
        board && (state === 'current' || state === 'inProgress')
          ? { done: board.completedTasks, total: board.totalTasks }
          : undefined,
      isCurrent,
    });
    win = stepWindow(timeframe, win.startDate, 1, weekStartDay);
  }

  // DAILY: leading blanks so day 1 lands on its weekday column.
  let leadingBlanks = 0;
  if (timeframe === Timeframe.DAILY) {
    const firstDay = pageStart.getDay(); // 0 = Sunday
    leadingBlanks = weekStartDay === 'monday' ? (firstDay + 6) % 7 : firstDay;
  }

  return {
    title: pickerPageTitle(timeframe, pageStart),
    prevTitle: pickerPageTitle(timeframe, stepPickerPage(timeframe, pageStart, -1)),
    nextTitle: pickerPageTitle(timeframe, stepPickerPage(timeframe, pageStart, 1)),
    tiles,
    leadingBlanks,
  };
}
