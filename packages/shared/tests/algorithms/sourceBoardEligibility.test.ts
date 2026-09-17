import {
  isEligibleSourceBoard,
  SOURCE_BOARD_LOOKBACK_DAYS,
  type SourceBoardCandidate,
} from '../../src/algorithms/boardSources';
import { BoardStatus } from '../../src/constants/enums';

const NOW = new Date('2026-09-16T12:00:00.000');
const DAY = 24 * 60 * 60 * 1000;

/** A board candidate; defaults to an ACTIVE board whose window is open. */
function candidate(over: Partial<SourceBoardCandidate> = {}): SourceBoardCandidate {
  return {
    status: BoardStatus.ACTIVE,
    endDate: new Date(NOW.getTime() + 5 * DAY).toISOString(),
    completedAt: undefined,
    isDeleted: false,
    ...over,
  } as SourceBoardCandidate;
}

/** An ISO timestamp `days` before NOW. */
function daysAgo(days: number): string {
  return new Date(NOW.getTime() - days * DAY).toISOString();
}

describe('isEligibleSourceBoard', () => {
  describe('the defect being fixed: unbounded ACTIVE boards', () => {
    it('EXCLUDES an active board whose window closed long ago', () => {
      // The actual bug — a core board whose window passed without every
      // square filled stays ACTIVE forever and was offered indefinitely.
      const stale = candidate({ endDate: daysAgo(240) });
      expect(isEligibleSourceBoard(stale, NOW)).toBe(false);
    });

    it('still offers an active board whose window closed RECENTLY', () => {
      // "Build October's board from September's" must keep working even
      // though September's board was never marked complete.
      const lastMonth = candidate({ endDate: daysAgo(10) });
      expect(isEligibleSourceBoard(lastMonth, NOW)).toBe(true);
    });

    it('draws the line exactly at the lookback window', () => {
      const justInside = candidate({ endDate: daysAgo(SOURCE_BOARD_LOOKBACK_DAYS - 1) });
      const justOutside = candidate({ endDate: daysAgo(SOURCE_BOARD_LOOKBACK_DAYS + 1) });
      expect(isEligibleSourceBoard(justInside, NOW)).toBe(true);
      expect(isEligibleSourceBoard(justOutside, NOW)).toBe(false);
    });
  });

  describe('open windows', () => {
    it('offers an active board whose window is still open', () => {
      expect(isEligibleSourceBoard(candidate(), NOW)).toBe(true);
    });

    it('offers an INDEFINITE active board (no end date) forever', () => {
      // Its window never closes, so recency cannot apply.
      expect(isEligibleSourceBoard(candidate({ endDate: undefined }), NOW)).toBe(true);
    });

    it('fails open on an unparseable end date rather than hiding the board', () => {
      expect(isEligibleSourceBoard(candidate({ endDate: 'not-a-date' }), NOW)).toBe(true);
    });
  });

  describe('completed boards keep their existing rule', () => {
    it('offers one completed inside the window', () => {
      const b = candidate({ status: BoardStatus.COMPLETED, completedAt: daysAgo(3) });
      expect(isEligibleSourceBoard(b, NOW)).toBe(true);
    });

    it('drops one completed outside the window', () => {
      const b = candidate({ status: BoardStatus.COMPLETED, completedAt: daysAgo(90) });
      expect(isEligibleSourceBoard(b, NOW)).toBe(false);
    });

    it('drops one with a missing or unparseable completedAt', () => {
      expect(isEligibleSourceBoard(
        candidate({ status: BoardStatus.COMPLETED, completedAt: undefined }), NOW,
      )).toBe(false);
      expect(isEligibleSourceBoard(
        candidate({ status: BoardStatus.COMPLETED, completedAt: 'nope' }), NOW,
      )).toBe(false);
    });

    it('ignores endDate for a completed board — completedAt is what counts', () => {
      // A board completed yesterday whose window ended months ago is
      // still a fine source.
      const b = candidate({
        status: BoardStatus.COMPLETED,
        completedAt: daysAgo(1),
        endDate: daysAgo(200),
      });
      expect(isEligibleSourceBoard(b, NOW)).toBe(true);
    });
  });

  describe('never a source', () => {
    it('excludes drafts', () => {
      expect(isEligibleSourceBoard(candidate({ status: BoardStatus.DRAFT }), NOW)).toBe(false);
    });

    it('excludes archived boards', () => {
      expect(isEligibleSourceBoard(candidate({ status: BoardStatus.ARCHIVED }), NOW)).toBe(false);
    });

    it('excludes deleted boards whatever their status', () => {
      expect(isEligibleSourceBoard(candidate({ isDeleted: true }), NOW)).toBe(false);
    });
  });

  it('honours an explicit `now` rather than the wall clock', () => {
    // A board that ended 10 days before NOW is eligible at NOW, but not
    // when judged from a year later. If `now` were ignored, both agree.
    const b = candidate({ endDate: daysAgo(10) });
    const muchLater = new Date(NOW.getTime() + 365 * DAY);
    expect(isEligibleSourceBoard(b, NOW)).toBe(true);
    expect(isEligibleSourceBoard(b, muchLater)).toBe(false);
  });
});
