import * as fs from 'fs';
import * as path from 'path';
import {
  isBoardSealable,
  isBoardClosingOut,
  isBoardPastBackstop,
  isBoardEnded,
  isBoardClosed,
  computeAutoCloseDeadlineMs,
} from '../../src/algorithms/sealing';
import { toLocalISO } from '../../src/algorithms/calendarBoundaries';
import type { Board } from '../../src/types/board';
import { BoardStatus, Timeframe, CenterSquareType } from '../../src/constants/enums';

/**
 * sealing.test.ts — Windowed Completion PR C board-sealing detection predicates
 * (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle + Backstop, §Migration step
 * 3, §Edge cases) and the Board Edit redesign slice 4 next-window auto-close
 * rule + ended/closed predicates (fixture-driven): the gates the seal
 * transaction + auto-close check + migration all consult.
 */


function makeBoard(overrides: Partial<Board>): Board {
  return {
    id: 'board-1',
    userId: 'user-1',
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: '2026-07-01T00:00:00.000Z',
    endDate: '2026-07-02T00:00:00.000Z',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-07-01T00:00:00.000Z',
    updatedAt: '2026-07-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('isBoardSealable', () => {
  it('an active, expired, non-indefinite, unsealed board is sealable', () => {
    expect(isBoardSealable(makeBoard({}))).toBe(true);
  });

  it('a soft-deleted board is never sealable', () => {
    expect(isBoardSealable(makeBoard({ isDeleted: true }))).toBe(false);
  });

  it('an already-sealed board is not sealable (idempotence)', () => {
    expect(isBoardSealable(makeBoard({ sealedAt: '2026-07-02T06:00:00.000Z' }))).toBe(false);
  });

  it('a DRAFT board is not sealable', () => {
    expect(isBoardSealable(makeBoard({ status: BoardStatus.DRAFT }))).toBe(false);
  });

  it('an indefinite board (no endDate) is not sealable', () => {
    expect(isBoardSealable(makeBoard({ timeframe: Timeframe.INDEFINITE, endDate: undefined }))).toBe(
      false,
    );
  });

  it('an ARCHIVED board seals normally (docs §Edge cases)', () => {
    expect(isBoardSealable(makeBoard({ status: BoardStatus.ARCHIVED }))).toBe(true);
  });
});

describe('isBoardClosingOut (the prompt set)', () => {
  const endMs = new Date('2026-07-02T00:00:00.000Z').getTime();

  it('is true once the window has ended and the board is unsealed', () => {
    expect(isBoardClosingOut(makeBoard({}), endMs + 1)).toBe(true);
  });

  it('is false before the window ends', () => {
    expect(isBoardClosingOut(makeBoard({}), endMs - 1)).toBe(false);
  });

  it('is false for a non-sealable board even after its window ends', () => {
    expect(isBoardClosingOut(makeBoard({ status: BoardStatus.DRAFT }), endMs + 1)).toBe(false);
  });
});

// ── Auto-close (Board Edit redesign slice 4, D4 / R5) — fixture-driven ─────
//
// autoCloseDeadlineVectors.json is the SAME file iOS runs through its Swift
// twins (apps/ios/OYBCTests/AutoCloseDeadlineVectorTests.swift). All inputs
// are local-ISO wall-clock strings, so expectations hold in any time zone.

interface VectorBoard {
  isDeleted?: boolean;
  status?: string;
  timeframe: string;
  startDate: string;
  endDate: string | null;
  sealedAt?: string | null;
  activatedAt?: string | null;
  reopenedAt?: string | null;
}
interface AutoCloseFixture {
  deadlines: Array<{ name: string; board: VectorBoard; expectedDeadline: string | null }>;
  pastBackstop: Array<{ name: string; board: VectorBoard; now: string; expected: boolean }>;
  lifecycle: Array<{
    name: string;
    board: VectorBoard;
    now: string;
    ended: boolean;
    closed: boolean;
  }>;
}

const autoClose = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/autoCloseDeadlineVectors.json'), 'utf8'),
) as AutoCloseFixture;

/** Vector board → a full Board (nulls become absent, like a decoded row). */
function vectorBoard(v: VectorBoard): Board {
  return makeBoard({
    isDeleted: v.isDeleted ?? false,
    status: (v.status ?? 'active') as BoardStatus,
    timeframe: v.timeframe as Timeframe,
    startDate: v.startDate,
    endDate: v.endDate ?? undefined,
    sealedAt: v.sealedAt ?? undefined,
    activatedAt: v.activatedAt ?? undefined,
    reopenedAt: v.reopenedAt ?? undefined,
  });
}

describe('computeAutoCloseDeadlineMs (autoCloseDeadlineVectors.json#deadlines)', () => {
  it('fixture section is present and non-trivial', () => {
    expect(autoClose.deadlines.length).toBeGreaterThanOrEqual(15);
  });

  for (const v of autoClose.deadlines) {
    it(v.name, () => {
      const deadline = computeAutoCloseDeadlineMs(vectorBoard(v.board));
      if (v.expectedDeadline == null) {
        expect(deadline).toBeNull();
      } else {
        expect(deadline).not.toBeNull();
        expect(toLocalISO(new Date(deadline as number))).toBe(v.expectedDeadline);
        expect(deadline).toBe(new Date(v.expectedDeadline).getTime());
      }
    });
  }

  it('an unparseable endDate never auto-closes', () => {
    expect(
      computeAutoCloseDeadlineMs({
        timeframe: Timeframe.DAILY,
        startDate: '2026-09-15T00:00:00.000',
        endDate: 'not-a-date',
      }),
    ).toBeNull();
  });

  it('an unparseable activatedAt is ignored', () => {
    const board = {
      timeframe: Timeframe.DAILY,
      startDate: '2026-09-15T00:00:00.000',
      endDate: '2026-09-15T23:59:59.999',
    };
    expect(computeAutoCloseDeadlineMs({ ...board, activatedAt: 'garbage' })).toBe(
      computeAutoCloseDeadlineMs(board),
    );
  });

  it('an unparseable custom startDate floors the grace to 1 day', () => {
    expect(
      computeAutoCloseDeadlineMs({
        timeframe: Timeframe.CUSTOM,
        startDate: 'garbage',
        endDate: '2026-07-10T12:00:00.000',
      }),
    ).toBe(new Date('2026-07-11T12:00:00.000').getTime());
  });
});

describe('isBoardPastBackstop — next-window auto-close (autoCloseDeadlineVectors.json#pastBackstop)', () => {
  it('fixture section is present and non-trivial', () => {
    expect(autoClose.pastBackstop.length).toBeGreaterThanOrEqual(8);
  });

  for (const v of autoClose.pastBackstop) {
    it(v.name, () => {
      expect(isBoardPastBackstop(vectorBoard(v.board), new Date(v.now).getTime())).toBe(v.expected);
    });
  }
});

describe('isBoardEnded / isBoardClosed (autoCloseDeadlineVectors.json#lifecycle)', () => {
  it('fixture section is present and non-trivial', () => {
    expect(autoClose.lifecycle.length).toBeGreaterThanOrEqual(8);
  });

  for (const v of autoClose.lifecycle) {
    it(v.name, () => {
      const board = vectorBoard(v.board);
      expect(isBoardEnded(board, new Date(v.now).getTime())).toBe(v.ended);
      expect(isBoardClosed(board)).toBe(v.closed);
    });
  }
});

// ── Sealed-window tombstone immunity (docs Decision 9 + §Write paths) ─────────
import { buildSealImmuneWindows, isEventSealImmune } from '../../src/algorithms/taskEvents';

/** The occurredAt-only immunity check: an event with no `boardId` (a heal /
 *  backfill mint, never a late log) is immune iff a window holds it. */
function isOccurredAtSealImmune(
  occurredAt: string,
  windows: Parameters<typeof isEventSealImmune>[1],
): boolean {
  return isEventSealImmune({ occurredAt, createdAt: occurredAt, boardId: undefined }, windows);
}

describe('sealed-window tombstone immunity', () => {
  const sealedBoards = [
    // endDate absent → open-ended → the bound is sealedAt.
    { startDate: '2026-07-01T00:00:00.000Z', sealedAt: '2026-07-02T06:00:00.000Z' },
    { startDate: '2026-07-05T00:00:00.000Z', endDate: null, sealedAt: '2026-07-06T06:00:00.000Z' },
  ];
  const windows = buildSealImmuneWindows(sealedBoards);

  it('builds one ms-bounded window per sealed board', () => {
    expect(windows).toEqual([
      {
        startMs: new Date('2026-07-01T00:00:00.000Z').getTime(),
        endMs: new Date('2026-07-02T06:00:00.000Z').getTime(),
        sealedAtMs: new Date('2026-07-02T06:00:00.000Z').getTime(),
      },
      {
        startMs: new Date('2026-07-05T00:00:00.000Z').getTime(),
        endMs: new Date('2026-07-06T06:00:00.000Z').getTime(),
        sealedAtMs: new Date('2026-07-06T06:00:00.000Z').getTime(),
      },
    ]);
  });

  it('an event inside a sealed window is immune', () => {
    expect(isOccurredAtSealImmune('2026-07-01T12:00:00.000Z', windows)).toBe(true);
    expect(isOccurredAtSealImmune('2026-07-05T18:00:00.000Z', windows)).toBe(true);
  });

  it('bounds are inclusive on both ends (boundary instants belong to the frozen record)', () => {
    expect(isOccurredAtSealImmune('2026-07-01T00:00:00.000Z', windows)).toBe(true); // == startDate
    expect(isOccurredAtSealImmune('2026-07-02T06:00:00.000Z', windows)).toBe(true); // == sealedAt
  });

  it('an event outside every sealed window is NOT immune (tombstonable)', () => {
    expect(isOccurredAtSealImmune('2026-06-30T23:59:59.999Z', windows)).toBe(false); // pre-window
    expect(isOccurredAtSealImmune('2026-07-02T06:00:00.001Z', windows)).toBe(false); // post-seal overtime
    expect(isOccurredAtSealImmune('2026-07-04T12:00:00.000Z', windows)).toBe(false); // between windows
  });

  describe('F1: bound = min(endDate, sealedAt) — the set that built the sealed record', () => {
    const ended = buildSealImmuneWindows([
      {
        startDate: '2026-09-23T00:00:00.000Z',
        endDate: '2026-09-23T23:59:59.999Z',
        sealedAt: '2026-09-24T07:00:00.000Z',
      },
    ]);

    it('clamps the upper bound to endDate when the seal lands later', () => {
      expect(ended).toEqual([
        {
          startMs: new Date('2026-09-23T00:00:00.000Z').getTime(),
          endMs: new Date('2026-09-23T23:59:59.999Z').getTime(),
          sealedAtMs: new Date('2026-09-24T07:00:00.000Z').getTime(),
        },
      ]);
    });

    it('an overtime-gap event (endDate < t <= sealedAt) is NOT immune', () => {
      expect(isOccurredAtSealImmune('2026-09-24T01:00:00.000Z', ended)).toBe(false);
      expect(isOccurredAtSealImmune('2026-09-24T07:00:00.000Z', ended)).toBe(false); // == sealedAt
    });

    it('an event at t <= endDate stays immune', () => {
      expect(isOccurredAtSealImmune('2026-09-23T23:59:59.999Z', ended)).toBe(true); // == endDate
      expect(isOccurredAtSealImmune('2026-09-23T12:00:00.000Z', ended)).toBe(true);
    });

    it('a seal before endDate keeps sealedAt as the bound', () => {
      const early = buildSealImmuneWindows([
        { startDate: '2026-09-23T00:00:00.000Z', endDate: '2026-09-23T23:59:59.999Z', sealedAt: '2026-09-23T18:00:00.000Z' },
      ]);
      expect(early[0].endMs).toBe(new Date('2026-09-23T18:00:00.000Z').getTime());
    });

    it('an unparseable endDate is open-ended (bound = sealedAt)', () => {
      const bad = buildSealImmuneWindows([
        { startDate: '2026-09-23T00:00:00.000Z', endDate: 'not-a-date', sealedAt: '2026-09-24T07:00:00.000Z' },
      ]);
      expect(bad[0].endMs).toBe(new Date('2026-09-24T07:00:00.000Z').getTime());
    });
  });

  it('no sealed boards → nothing is immune', () => {
    expect(isOccurredAtSealImmune('2026-07-01T12:00:00.000Z', [])).toBe(false);
    expect(buildSealImmuneWindows([])).toEqual([]);
  });
});

// ── Late-log-aware immunity (Board Edit redesign slice 4, D10 / R2) ─────────
//
// sealReDerivationVectors.json#sealImmunity — the SAME vectors iOS runs in
// apps/ios/OYBCTests/SealImmunityVectorTests.swift.

interface SealImmunityVector {
  name: string;
  windows: Array<{ startDate: string; endDate: string | null; sealedAt: string }>;
  event: { occurredAt: string; createdAt: string; boardId: string | null };
  expectedImmune: boolean;
}

const sealImmunityVectors = (
  JSON.parse(
    fs.readFileSync(path.join(__dirname, '../fixtures/sealReDerivationVectors.json'), 'utf8'),
  ) as { sealImmunity: SealImmunityVector[] }
).sealImmunity;

describe('isEventSealImmune (sealReDerivationVectors.json#sealImmunity)', () => {
  it('fixture section is present and non-trivial', () => {
    expect(sealImmunityVectors.length).toBeGreaterThanOrEqual(8);
  });

  for (const v of sealImmunityVectors) {
    it(v.name, () => {
      const windows = buildSealImmuneWindows(v.windows);
      const event = {
        occurredAt: v.event.occurredAt,
        createdAt: v.event.createdAt,
        boardId: v.event.boardId ?? undefined,
      };
      expect(isEventSealImmune(event, windows)).toBe(v.expectedImmune);
    });
  }
});
