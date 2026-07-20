import {
  CreatePoolInputSchema,
  UpdatePoolInputSchema,
  PoolSchema,
} from '../../src/validation/schemas';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const POOL_ID = '00000000-0000-0000-0000-000000000400';
const USER_ID = '00000000-0000-0000-0000-000000000001';

function uuid(n: number): string {
  return `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
}

function validPool(overrides: Record<string, unknown> = {}) {
  return {
    id: POOL_ID,
    userId: USER_ID,
    name: 'Morning Kickstart',
    taskIds: [uuid(1), uuid(2), uuid(3)],
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// ─── PoolSchema ────────────────────────────────────────────────────────────────

describe('PoolSchema', () => {
  it('accepts a valid pool', () => {
    expect(() => PoolSchema.parse(validPool())).not.toThrow();
  });

  it('round-trips through parse', () => {
    const input = validPool();
    expect(PoolSchema.parse(input)).toEqual(input);
  });

  it('accepts an empty taskIds array (created empty, filled later)', () => {
    expect(() => PoolSchema.parse(validPool({ taskIds: [] }))).not.toThrow();
  });

  it('rejects duplicate taskIds', () => {
    expect(() =>
      PoolSchema.parse(validPool({ taskIds: [uuid(1), uuid(1)] })),
    ).toThrow(/duplicates/i);
  });

  it('rejects non-UUID taskIds', () => {
    expect(() =>
      PoolSchema.parse(validPool({ taskIds: ['not-a-uuid'] })),
    ).toThrow();
  });

  it('rejects empty name', () => {
    expect(() => PoolSchema.parse(validPool({ name: '' }))).toThrow();
  });

  it('rejects a name longer than 120 chars', () => {
    expect(() => PoolSchema.parse(validPool({ name: 'x'.repeat(121) }))).toThrow();
  });

  it('rejects version < 1', () => {
    expect(() => PoolSchema.parse(validPool({ version: 0 }))).toThrow();
  });
});

// ─── CreatePoolInputSchema ──────────────────────────────────────────────────────

describe('CreatePoolInputSchema', () => {
  it('accepts a minimal create input', () => {
    expect(() =>
      CreatePoolInputSchema.parse({ name: 'Morning Kickstart', taskIds: [uuid(1)] }),
    ).not.toThrow();
  });

  it('accepts an empty taskIds array', () => {
    expect(() =>
      CreatePoolInputSchema.parse({ name: 'Empty pool', taskIds: [] }),
    ).not.toThrow();
  });

  it('trims and rejects a whitespace-only name', () => {
    expect(() =>
      CreatePoolInputSchema.parse({ name: '   ', taskIds: [] }),
    ).toThrow();
  });

  it('rejects duplicate taskIds', () => {
    expect(() =>
      CreatePoolInputSchema.parse({
        name: 'Dup pool',
        taskIds: [uuid(1), uuid(2), uuid(1)],
      }),
    ).toThrow(/duplicates/i);
  });
});

// ─── UpdatePoolInputSchema ──────────────────────────────────────────────────────

describe('UpdatePoolInputSchema', () => {
  it('accepts a taskIds-only update', () => {
    expect(() =>
      UpdatePoolInputSchema.parse({ taskIds: [uuid(1), uuid(2)] }),
    ).not.toThrow();
  });

  it('accepts a name-only update', () => {
    expect(() => UpdatePoolInputSchema.parse({ name: 'Renamed' })).not.toThrow();
  });

  it('accepts an empty patch (no-op)', () => {
    expect(() => UpdatePoolInputSchema.parse({})).not.toThrow();
  });

  it('rejects duplicates in a taskIds update', () => {
    expect(() =>
      UpdatePoolInputSchema.parse({ taskIds: [uuid(1), uuid(1)] }),
    ).toThrow(/duplicates/i);
  });

  it('ignores extraneous keys per Zod default', () => {
    expect(() =>
      UpdatePoolInputSchema.parse({
        taskIds: [uuid(1)],
        userId: USER_ID,
      } as Record<string, unknown>),
    ).not.toThrow();
  });
});
