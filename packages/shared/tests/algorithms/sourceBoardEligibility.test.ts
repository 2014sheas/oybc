import { isEligibleSourceBoard, type SourceBoardCandidate } from '../../src/algorithms/boardSources';
import { BoardStatus } from '../../src/constants/enums';

const NOW = new Date('2026-09-16T12:00:00.000');
const DAY = 24 * 60 * 60 * 1000;

/** A board candidate; defaults to an ACTIVE, unsealed board whose window is open. */
function candidate(over: Partial<SourceBoardCandidate> = {}): SourceBoardCandidate {
  return {
    status: BoardStatus.ACTIVE,
    endDate: new Date(NOW.getTime() + 5 * DAY).toISOString(),
    sealedAt: undefined,
    isDeleted: false,
    ...over,
  } as SourceBoardCandidate;
}

/** An ISO timestamp `days` before NOW. */
function daysAgo(days: number): string {
  return new Date(NOW.getTime() - days * DAY).toISOString();
}

/**
 * Owner ruling 2026-09-24 (supersedes #482's 30-day lookback): "There is
 * no REAL use case for ended boards as sources." Eligible = not deleted,
 * not a draft/archived, not sealed, and the window is open (no endDate,
 * an unparseable endDate — fail open — or endDate >= now). The cross-
 * platform pin is `eligibilityVectors` in boardSourceVectors.json; these
 * are the readable unit cases. Swift twin: SourceBoardEligibilityTests.
 */
describe('isEligibleSourceBoard', () => {
  describe('ended boards are never sources', () => {
    it('EXCLUDES a board whose window ended yesterday', () => {
      expect(isEligibleSourceBoard(candidate({ endDate: daysAgo(1) }), NOW)).toBe(false);
    });

    it('EXCLUDES a board whose window ended a second ago (no lookback)', () => {
      const justEnded = new Date(NOW.getTime() - 1000).toISOString();
      expect(isEligibleSourceBoard(candidate({ endDate: justEnded }), NOW)).toBe(false);
    });

    it('EXCLUDES an ended COMPLETED board (the completedAt branch is retired)', () => {
      const b = candidate({ status: BoardStatus.COMPLETED, endDate: daysAgo(3) });
      expect(isEligibleSourceBoard(b, NOW)).toBe(false);
    });

    it('EXCLUDES a sealed board even when its window looks open', () => {
      expect(isEligibleSourceBoard(candidate({ sealedAt: daysAgo(0) }), NOW)).toBe(false);
    });
  });

  describe('open windows', () => {
    it('offers an active board whose window is still open', () => {
      expect(isEligibleSourceBoard(candidate(), NOW)).toBe(true);
    });

    it('offers a board whose window ends exactly now (inclusive)', () => {
      expect(isEligibleSourceBoard(candidate({ endDate: NOW.toISOString() }), NOW)).toBe(true);
    });

    it('offers a completed board whose window is still open', () => {
      expect(isEligibleSourceBoard(candidate({ status: BoardStatus.COMPLETED }), NOW)).toBe(true);
    });

    it('offers an INDEFINITE board (no end date) forever', () => {
      expect(isEligibleSourceBoard(candidate({ endDate: undefined }), NOW)).toBe(true);
    });

    it('fails open on an unparseable end date rather than hiding the board', () => {
      expect(isEligibleSourceBoard(candidate({ endDate: 'not-a-date' }), NOW)).toBe(true);
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
    // Open at NOW, ended a year later. If `now` were ignored, both agree.
    const b = candidate();
    const muchLater = new Date(NOW.getTime() + 365 * DAY);
    expect(isEligibleSourceBoard(b, NOW)).toBe(true);
    expect(isEligibleSourceBoard(b, muchLater)).toBe(false);
  });
});
