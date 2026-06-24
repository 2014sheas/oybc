import { CreateBoardInputSchema } from '../../src/validation/schemas';
import { isBoardIndefinite } from '../../src/types/board';
import { CenterSquareType, Timeframe } from '../../src/constants/enums';

// ─── CreateBoardInputSchema — indefinite (no endDate) ───────────────────────────

function validCreateInput(overrides: Record<string, unknown> = {}) {
  return {
    name: 'Ongoing list',
    boardSize: 5 as const,
    timeframe: Timeframe.DAILY,
    startDate: '2026-06-21T00:00:00.000',
    endDate: '2026-06-21T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    ...overrides,
  };
}

describe('CreateBoardInputSchema — indefinite boards', () => {
  it('parses an indefinite board with no endDate', () => {
    const input = validCreateInput({ timeframe: Timeframe.INDEFINITE });
    delete (input as Record<string, unknown>).endDate;
    expect(CreateBoardInputSchema.safeParse(input).success).toBe(true);
  });

  it('still rejects a present endDate that is not after startDate', () => {
    const result = CreateBoardInputSchema.safeParse(
      validCreateInput({
        startDate: '2026-06-21T00:00:00.000',
        endDate: '2026-06-20T00:00:00.000',
      }),
    );
    expect(result.success).toBe(false);
  });

  it('accepts a present endDate that is after startDate', () => {
    expect(CreateBoardInputSchema.safeParse(validCreateInput()).success).toBe(true);
  });
});

// ─── isBoardIndefinite predicate ────────────────────────────────────────────────

describe('isBoardIndefinite', () => {
  it('is true when timeframe is INDEFINITE', () => {
    expect(
      isBoardIndefinite({ timeframe: Timeframe.INDEFINITE, endDate: undefined }),
    ).toBe(true);
  });

  it('is true when endDate is absent even if timeframe is not INDEFINITE', () => {
    expect(isBoardIndefinite({ timeframe: Timeframe.CUSTOM, endDate: undefined })).toBe(true);
  });

  it('is false for a normal bounded board', () => {
    expect(
      isBoardIndefinite({ timeframe: Timeframe.DAILY, endDate: '2026-06-21T23:59:59.999' }),
    ).toBe(false);
  });

  // Defensive: even a stale INDEFINITE row that somehow still carries an endDate
  // is treated as indefinite (timeframe wins).
  it('is true for INDEFINITE timeframe even with a stray endDate', () => {
    expect(
      isBoardIndefinite({ timeframe: Timeframe.INDEFINITE, endDate: '2026-06-21T23:59:59.999' }),
    ).toBe(true);
  });
});
