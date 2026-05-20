import {
  CreateDefaultPoolInputSchema,
  UpdateDefaultPoolInputSchema,
  DefaultPoolSchema,
} from '../../src/validation/schemas';
import { Timeframe } from '../../src/constants/enums';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const POOL_ID = '00000000-0000-0000-0000-000000000300';
const USER_ID = '00000000-0000-0000-0000-000000000001';

function uuid(n: number): string {
  return `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
}

function validPool(overrides: Record<string, unknown> = {}) {
  return {
    id: POOL_ID,
    userId: USER_ID,
    timeframe: Timeframe.WEEKLY,
    taskIds: [uuid(1), uuid(2), uuid(3)],
    createdAt: '2026-05-17T00:00:00.000Z',
    updatedAt: '2026-05-17T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// ─── DefaultPoolSchema ────────────────────────────────────────────────────────

describe('DefaultPoolSchema', () => {
  it('accepts a valid pool', () => {
    expect(() => DefaultPoolSchema.parse(validPool())).not.toThrow();
  });

  it('round-trips through parse', () => {
    const input = validPool();
    expect(DefaultPoolSchema.parse(input)).toEqual(input);
  });

  it('accepts an empty taskIds array (set-up-then-clear is allowed)', () => {
    expect(() => DefaultPoolSchema.parse(validPool({ taskIds: [] }))).not.toThrow();
  });

  it('rejects Timeframe.CUSTOM', () => {
    expect(() =>
      DefaultPoolSchema.parse(validPool({ timeframe: Timeframe.CUSTOM })),
    ).toThrow();
  });

  it('rejects non-UUID taskIds', () => {
    expect(() =>
      DefaultPoolSchema.parse(validPool({ taskIds: ['not-a-uuid'] })),
    ).toThrow();
  });

  it('rejects version < 1', () => {
    expect(() => DefaultPoolSchema.parse(validPool({ version: 0 }))).toThrow();
  });
});

// ─── CreateDefaultPoolInputSchema ─────────────────────────────────────────────

describe('CreateDefaultPoolInputSchema', () => {
  it('accepts a minimal create input', () => {
    expect(() =>
      CreateDefaultPoolInputSchema.parse({
        timeframe: Timeframe.DAILY,
        taskIds: [uuid(1)],
      }),
    ).not.toThrow();
  });

  it('accepts an empty taskIds array (pool created empty, filled later)', () => {
    expect(() =>
      CreateDefaultPoolInputSchema.parse({
        timeframe: Timeframe.DAILY,
        taskIds: [],
      }),
    ).not.toThrow();
  });

  it('rejects duplicate taskIds', () => {
    expect(() =>
      CreateDefaultPoolInputSchema.parse({
        timeframe: Timeframe.WEEKLY,
        taskIds: [uuid(1), uuid(2), uuid(1)],
      }),
    ).toThrow(/duplicates/i);
  });

  it('rejects Timeframe.CUSTOM', () => {
    expect(() =>
      CreateDefaultPoolInputSchema.parse({
        timeframe: Timeframe.CUSTOM,
        taskIds: [uuid(1)],
      }),
    ).toThrow();
  });
});

// ─── UpdateDefaultPoolInputSchema ─────────────────────────────────────────────

describe('UpdateDefaultPoolInputSchema', () => {
  it('accepts a taskIds-only update', () => {
    expect(() =>
      UpdateDefaultPoolInputSchema.parse({ taskIds: [uuid(1), uuid(2)] }),
    ).not.toThrow();
  });

  it('accepts an empty patch (no-op)', () => {
    expect(() => UpdateDefaultPoolInputSchema.parse({})).not.toThrow();
  });

  it('rejects duplicates in a taskIds update', () => {
    expect(() =>
      UpdateDefaultPoolInputSchema.parse({ taskIds: [uuid(1), uuid(1)] }),
    ).toThrow(/duplicates/i);
  });

  it('ignores extraneous keys per Zod default', () => {
    expect(() =>
      UpdateDefaultPoolInputSchema.parse({
        taskIds: [uuid(1)],
        timeframe: Timeframe.MONTHLY,
        userId: USER_ID,
      } as Record<string, unknown>),
    ).not.toThrow();
  });
});
