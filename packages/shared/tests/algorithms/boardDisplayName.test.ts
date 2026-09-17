import { boardDisplayName, type BoardNameFields } from '../../src/algorithms/boardDisplayName';
import { formatTimeframeLabel, formatWindowLabel } from '../../src/algorithms/calendarBoundaries';
import { Timeframe } from '../../src/constants/enums';

/** A daily core board for the given local-ISO start, named as stored. */
function coreBoard(name: string, startDate: string, timeframe = Timeframe.DAILY): BoardNameFields {
  return { name, startDate, timeframe, isCore: true };
}

describe('boardDisplayName', () => {
  describe('heals the frozen "Today"', () => {
    it('replaces a bare "Today" with that board\'s own absolute date', () => {
      const healed = boardDisplayName(coreBoard('Today', '2026-03-15T00:00:00.000'));
      // Asserting the EXACT string (not merely "!== Today") — a helper that
      // returned '' or the timeframe name would also stop saying "Today".
      expect(healed).toBe('Mar 15, 2026');
    });

    it('gives two boards frozen as "Today" DIFFERENT names', () => {
      // This is the actual user-visible bug: a list of daily core boards
      // that all read "Today" and cannot be told apart when searching.
      const a = boardDisplayName(coreBoard('Today', '2026-03-15T00:00:00.000'));
      const b = boardDisplayName(coreBoard('Today', '2026-03-16T00:00:00.000'));
      expect(a).not.toBe(b);
      expect([a, b]).toEqual(['Mar 15, 2026', 'Mar 16, 2026']);
    });

    it('heals only the window half of a spawned "<template> — Today"', () => {
      const healed = boardDisplayName(coreBoard('Leg Day — Today', '2026-03-15T00:00:00.000'));
      expect(healed).toBe('Leg Day — Mar 15, 2026');
    });

    it('keeps an em-dash that belongs to the template name itself', () => {
      // Only the trailing " — Today" is the composed half; an em-dash
      // earlier in the user's own template name must survive.
      const healed = boardDisplayName(coreBoard('Push — Pull — Today', '2026-03-15T00:00:00.000'));
      expect(healed).toBe('Push — Pull — Mar 15, 2026');
    });
  });

  describe('leaves everything else alone', () => {
    it('returns a user-renamed core board verbatim', () => {
      const board = coreBoard('My Big Day', '2026-03-15T00:00:00.000');
      expect(boardDisplayName(board)).toBe('My Big Day');
    });

    it('does NOT heal a non-core board even when named exactly "Today"', () => {
      // A one-off board the user typed "Today" into is authored data.
      const oneOff: BoardNameFields = {
        name: 'Today',
        startDate: '2026-03-15T00:00:00.000',
        timeframe: Timeframe.DAILY,
        isCore: false,
      };
      expect(boardDisplayName(oneOff)).toBe('Today');
    });

    it('does not touch a name that merely CONTAINS the word today', () => {
      const board = coreBoard('Today I conquer', '2026-03-15T00:00:00.000');
      expect(boardDisplayName(board)).toBe('Today I conquer');
    });

    it('is case-sensitive — "today" is not the generated literal', () => {
      const board = coreBoard('today', '2026-03-15T00:00:00.000');
      expect(boardDisplayName(board)).toBe('today');
    });

    it('passes through already-absolute weekly/monthly/yearly names', () => {
      // These timeframes never had a relative branch, so they were never broken.
      expect(boardDisplayName(coreBoard('September 2026', '2026-09-01T00:00:00.000', Timeframe.MONTHLY)))
        .toBe('September 2026');
      expect(boardDisplayName(coreBoard('2026', '2026-01-01T00:00:00.000', Timeframe.YEARLY)))
        .toBe('2026');
    });
  });

  it('is clock-independent — the same board names the same on any day', () => {
    // The whole defect was a name that depended on when it was read.
    const board = coreBoard('Today', '2026-03-15T00:00:00.000');
    const realNow = Date.now;
    try {
      Date.now = () => new Date('2026-03-15T12:00:00.000').getTime();
      const onTheDay = boardDisplayName(board);
      Date.now = () => new Date('2027-11-02T12:00:00.000').getTime();
      const muchLater = boardDisplayName(board);
      expect(onTheDay).toBe(muchLater);
      expect(onTheDay).toBe('Mar 15, 2026');
    } finally {
      Date.now = realNow;
    }
  });
});

describe('formatWindowLabel vs formatTimeframeLabel', () => {
  const today = new Date('2026-03-15T09:00:00.000');
  const todayISO = '2026-03-15T00:00:00.000';

  it('formatWindowLabel NEVER says "Today", even for the current window', () => {
    // This is what makes it safe to persist. If this regresses, the mint
    // path starts freezing "Today" into names all over again.
    expect(formatWindowLabel(Timeframe.DAILY, todayISO)).toBe('Mar 15, 2026');
  });

  it('formatTimeframeLabel still says "Today" for live chrome', () => {
    // The relative label is correct and wanted at render time — the window
    // chip and pager caption rely on it.
    expect(formatTimeframeLabel(Timeframe.DAILY, todayISO, today)).toBe('Today');
  });

  it('formatTimeframeLabel honours a pinned `now` over the wall clock', () => {
    // Pinning a far-past instant proves the parameter drives the answer:
    // a 2026 window is not "Today" when now is 2020.
    expect(formatTimeframeLabel(Timeframe.DAILY, todayISO, new Date('2020-01-01T00:00:00.000')))
      .toBe('Mar 15, 2026');
  });

  it('the two agree on every non-today window', () => {
    const past = '2026-03-14T00:00:00.000';
    expect(formatTimeframeLabel(Timeframe.DAILY, past, today))
      .toBe(formatWindowLabel(Timeframe.DAILY, past));
  });
});
