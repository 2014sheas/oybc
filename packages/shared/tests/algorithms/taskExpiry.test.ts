import { isTaskExpired } from '../../src/algorithms/taskExpiry';
import { TaskType, Timeframe } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: '00000000-0000-0000-0000-000000000001',
    userId: 'u1',
    title: 'sample',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('isTaskExpired', () => {
  const NOW = new Date('2026-05-18T12:00:00.000Z');

  it('returns false for indefinite tasks (no endDate)', () => {
    expect(isTaskExpired(makeTask(), NOW)).toBe(false);
  });

  it('returns true when endDate is in the past', () => {
    expect(
      isTaskExpired(
        makeTask({
          timeframe: Timeframe.WEEKLY,
          startDate: '2026-05-04T00:00:00.000Z',
          endDate: '2026-05-10T23:59:59.999Z',
        }),
        NOW,
      ),
    ).toBe(true);
  });

  it('returns false when endDate is in the future', () => {
    expect(
      isTaskExpired(
        makeTask({
          timeframe: Timeframe.WEEKLY,
          startDate: '2026-05-18T00:00:00.000Z',
          endDate: '2026-05-25T23:59:59.999Z',
        }),
        NOW,
      ),
    ).toBe(false);
  });

  it('returns false when now exactly equals endDate (boundary inclusive)', () => {
    const endIso = NOW.toISOString();
    expect(
      isTaskExpired(
        makeTask({ endDate: endIso }),
        NOW,
      ),
    ).toBe(false);
  });

  it('returns false when endDate is unparseable (defensive)', () => {
    expect(
      isTaskExpired(makeTask({ endDate: 'not-a-date' }), NOW),
    ).toBe(false);
  });

  // ── Local-ISO without timezone (output of `toLocalISO`) ────────────────
  // The wizard writes `Board.endDate` via `toLocalISO()`, which produces
  // e.g. "2026-05-25T23:59:59.999" (no Z / offset). The Dexie/GRDB
  // backfill migrations copy that verbatim onto `Task.endDate`.

  describe('local-ISO without timezone', () => {
    it('returns true when the local-ISO endDate is in the past', () => {
      expect(
        isTaskExpired(
          makeTask({ endDate: '2026-05-10T23:59:59.999' }),
          NOW,
        ),
      ).toBe(true);
    });

    it('returns false when the local-ISO endDate is in the future', () => {
      expect(
        isTaskExpired(
          makeTask({ endDate: '2026-05-25T23:59:59.999' }),
          NOW,
        ),
      ).toBe(false);
    });
  });

  // ── Calendar-only YYYY-MM-DD ───────────────────────────────────────────
  // Comments on `TaskSchema` (schemas.ts) explicitly allow Tasks to carry
  // a calendar-only `endDate`. `new Date('YYYY-MM-DD')` would parse to
  // UTC midnight — which expires the task up to a day early for users
  // east of UTC. Our predicate must interpret it as local end-of-day.

  describe('calendar-only YYYY-MM-DD', () => {
    it('returns true when the YYYY-MM-DD endDate is several days in the past', () => {
      expect(
        isTaskExpired(makeTask({ endDate: '2026-05-10' }), NOW),
      ).toBe(true);
    });

    it('returns false when the YYYY-MM-DD endDate is the current local day', () => {
      // NOW is mid-day on 2026-05-18 UTC. In any timezone where 2026-05-18
      // is still "today", end-of-day on that date is in the future, so
      // the task is NOT yet expired. (If `new Date('2026-05-18')` were
      // used instead, this would yield UTC midnight 2026-05-18 — already
      // in the past — and the assertion would fail east of UTC.)
      expect(
        isTaskExpired(makeTask({ endDate: '2026-05-18' }), NOW),
      ).toBe(false);
    });

    it('returns false when the YYYY-MM-DD endDate is in the future', () => {
      expect(
        isTaskExpired(makeTask({ endDate: '2026-05-25' }), NOW),
      ).toBe(false);
    });
  });
});
