import {
  CreateCoreBoardDefaultInputSchema,
  UpdateCoreBoardDefaultInputSchema,
  CoreBoardDefaultSchema,
} from '../../src/validation/schemas';
import { Timeframe } from '../../src/constants/enums';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const ROW_ID = '00000000-0000-0000-0000-000000000500';
const USER_ID = '00000000-0000-0000-0000-000000000001';

function uuid(n: number): string {
  return `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
}

function validRow(overrides: Record<string, unknown> = {}) {
  return {
    id: ROW_ID,
    userId: USER_ID,
    timeframe: Timeframe.DAILY,
    corePoolIds: [uuid(1)],
    coreDefaultTaskIds: [uuid(2), uuid(3)],
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// ─── CoreBoardDefaultSchema ──────────────────────────────────────────────────

describe('CoreBoardDefaultSchema', () => {
  it('accepts a valid row', () => {
    expect(() => CoreBoardDefaultSchema.parse(validRow())).not.toThrow();
  });

  it('round-trips through parse', () => {
    const input = validRow();
    expect(CoreBoardDefaultSchema.parse(input)).toEqual(input);
  });

  it('accepts empty corePoolIds and coreDefaultTaskIds ("No default tasks" is valid)', () => {
    expect(() =>
      CoreBoardDefaultSchema.parse(validRow({ corePoolIds: [], coreDefaultTaskIds: [] })),
    ).not.toThrow();
  });

  it('rejects Timeframe.CUSTOM', () => {
    expect(() =>
      CoreBoardDefaultSchema.parse(validRow({ timeframe: Timeframe.CUSTOM })),
    ).toThrow();
  });

  it('rejects duplicate corePoolIds', () => {
    expect(() =>
      CoreBoardDefaultSchema.parse(validRow({ corePoolIds: [uuid(1), uuid(1)] })),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate coreDefaultTaskIds', () => {
    expect(() =>
      CoreBoardDefaultSchema.parse(
        validRow({ coreDefaultTaskIds: [uuid(2), uuid(2)] }),
      ),
    ).toThrow(/duplicates/i);
  });

  it('rejects non-UUID entries', () => {
    expect(() =>
      CoreBoardDefaultSchema.parse(validRow({ corePoolIds: ['not-a-uuid'] })),
    ).toThrow();
  });

  it('rejects version < 1', () => {
    expect(() => CoreBoardDefaultSchema.parse(validRow({ version: 0 }))).toThrow();
  });
});

// ─── CreateCoreBoardDefaultInputSchema ────────────────────────────────────────

describe('CreateCoreBoardDefaultInputSchema', () => {
  it('accepts a minimal create input', () => {
    expect(() =>
      CreateCoreBoardDefaultInputSchema.parse({
        timeframe: Timeframe.WEEKLY,
        corePoolIds: [],
        coreDefaultTaskIds: [],
      }),
    ).not.toThrow();
  });

  it('rejects Timeframe.CUSTOM', () => {
    expect(() =>
      CreateCoreBoardDefaultInputSchema.parse({
        timeframe: Timeframe.CUSTOM,
        corePoolIds: [],
        coreDefaultTaskIds: [],
      }),
    ).toThrow();
  });

  it('rejects duplicate corePoolIds', () => {
    expect(() =>
      CreateCoreBoardDefaultInputSchema.parse({
        timeframe: Timeframe.MONTHLY,
        corePoolIds: [uuid(1), uuid(1)],
        coreDefaultTaskIds: [],
      }),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate coreDefaultTaskIds', () => {
    expect(() =>
      CreateCoreBoardDefaultInputSchema.parse({
        timeframe: Timeframe.MONTHLY,
        corePoolIds: [],
        coreDefaultTaskIds: [uuid(2), uuid(2)],
      }),
    ).toThrow(/duplicates/i);
  });
});

// ─── UpdateCoreBoardDefaultInputSchema ────────────────────────────────────────

describe('UpdateCoreBoardDefaultInputSchema', () => {
  it('accepts an empty patch (no-op)', () => {
    expect(() => UpdateCoreBoardDefaultInputSchema.parse({})).not.toThrow();
  });

  it('accepts a corePoolIds-only patch', () => {
    expect(() =>
      UpdateCoreBoardDefaultInputSchema.parse({ corePoolIds: [uuid(1)] }),
    ).not.toThrow();
  });

  it('accepts a coreDefaultTaskIds-only patch', () => {
    expect(() =>
      UpdateCoreBoardDefaultInputSchema.parse({ coreDefaultTaskIds: [uuid(2)] }),
    ).not.toThrow();
  });

  it('rejects duplicates in a corePoolIds patch', () => {
    expect(() =>
      UpdateCoreBoardDefaultInputSchema.parse({ corePoolIds: [uuid(1), uuid(1)] }),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicates in a coreDefaultTaskIds patch', () => {
    expect(() =>
      UpdateCoreBoardDefaultInputSchema.parse({
        coreDefaultTaskIds: [uuid(2), uuid(2)],
      }),
    ).toThrow(/duplicates/i);
  });

  it('skips the dedupe checks when the corresponding field is omitted', () => {
    expect(() =>
      UpdateCoreBoardDefaultInputSchema.parse({}),
    ).not.toThrow();
  });
});
