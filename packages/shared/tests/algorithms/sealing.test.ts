import {
  isBoardSealable,
  isBoardClosingOut,
  isBoardPastBackstop,
} from '../../src/algorithms/sealing';
import type { Board } from '../../src/types/board';
import { BoardStatus, Timeframe, CenterSquareType } from '../../src/constants/enums';

/**
 * sealing.test.ts — Windowed Completion PR C board-sealing detection predicates
 * (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle + Backstop, §Migration step
 * 3, §Edge cases). The timeframe-scaled backstop FORMULA itself is covered by
 * taskEvents.test.ts; here we cover the gates the seal transaction + backstop
 * check + migration all consult.
 */

const H = 60 * 60 * 1000;

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

describe('isBoardPastBackstop', () => {
  const start = '2026-07-01T00:00:00.000Z';
  const end = '2026-07-02T00:00:00.000Z'; // daily → backstop 6h
  const endMs = new Date(end).getTime();

  it('is false at the endDate (still inside the backstop grace)', () => {
    expect(isBoardPastBackstop(makeBoard({ startDate: start, endDate: end }), endMs)).toBe(false);
  });

  it('is false within the 6h daily backstop window', () => {
    expect(isBoardPastBackstop(makeBoard({ startDate: start, endDate: end }), endMs + 5 * H)).toBe(
      false,
    );
  });

  it('is true once past endDate + 6h', () => {
    expect(isBoardPastBackstop(makeBoard({ startDate: start, endDate: end }), endMs + 6 * H + 1)).toBe(
      true,
    );
  });

  it('draft-grace: a board activated after its window expired keys off activatedAt', () => {
    // Window ended 2026-07-02; but the draft was only activated 2026-07-05.
    const activatedAt = '2026-07-05T00:00:00.000Z';
    const activatedMs = new Date(activatedAt).getTime();
    const board = makeBoard({ startDate: start, endDate: end, activatedAt });
    // Just after the original endDate + 6h it must NOT be past backstop —
    // the grace cycle keys off activatedAt, not endDate.
    expect(isBoardPastBackstop(board, endMs + 6 * H + 1)).toBe(false);
    // It only auto-seals once past activatedAt + 6h.
    expect(isBoardPastBackstop(board, activatedMs + 6 * H - 1)).toBe(false);
    expect(isBoardPastBackstop(board, activatedMs + 6 * H + 1)).toBe(true);
  });

  it('is false for an indefinite board (deadline is null)', () => {
    const board = makeBoard({ timeframe: Timeframe.INDEFINITE, endDate: undefined });
    expect(isBoardPastBackstop(board, Date.now())).toBe(false);
  });

  it('is false for an already-sealed board', () => {
    const board = makeBoard({ startDate: start, endDate: end, sealedAt: end });
    expect(isBoardPastBackstop(board, endMs + 100 * H)).toBe(false);
  });
});
