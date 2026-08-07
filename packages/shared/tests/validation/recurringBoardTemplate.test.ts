import {
  RecurringBoardTemplateSchema,
  CreateRecurringBoardTemplateInputSchema,
  UpdateRecurringBoardTemplateInputSchema,
  BoardSchema,
} from '../../src/validation/schemas';
import {
  Timeframe,
  CenterSquareType,
  BoardStatus,
} from '../../src/constants/enums';

// ─── Helpers ──────────────────────────────────────────────────────────────────

const TEMPLATE_ID = '00000000-0000-0000-0000-000000000200';
const USER_ID = '00000000-0000-0000-0000-000000000001';

function uuid(n: number): string {
  return `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
}

function validTemplate(overrides: Record<string, unknown> = {}) {
  return {
    id: TEMPLATE_ID,
    userId: USER_ID,
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 5 as const,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: Array.from({ length: 24 }, (_, i) => uuid(i + 1)),
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function validCreateInput(overrides: Record<string, unknown> = {}) {
  return {
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 5 as const,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: Array.from({ length: 24 }, (_, i) => uuid(i + 1)),
    isActive: true,
    ...overrides,
  };
}

function validBoard(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000100',
    userId: USER_ID,
    name: 'Daily — May 7, 2026',
    status: BoardStatus.ACTIVE,
    boardSize: 5,
    timeframe: Timeframe.DAILY,
    startDate: '2026-05-07T00:00:00.000',
    endDate: '2026-05-07T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-05-07T00:00:00.000Z',
    updatedAt: '2026-05-07T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// ─── RecurringBoardTemplateSchema ─────────────────────────────────────────────

describe('RecurringBoardTemplateSchema', () => {
  it('accepts a valid template', () => {
    expect(() => RecurringBoardTemplateSchema.parse(validTemplate())).not.toThrow();
  });

  it('rejects Timeframe.CUSTOM (incompatible with computed-window recurrence)', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(validTemplate({ timeframe: Timeframe.CUSTOM })),
    ).toThrow();
  });

  it('rejects Timeframe.INDEFINITE (no window cadence to recur on)', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(validTemplate({ timeframe: Timeframe.INDEFINITE })),
    ).toThrow();
  });

  it('rejects CenterSquareType.CHOSEN (MVP excludes it)', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({ centerSquareType: CenterSquareType.CHOSEN }),
      ),
    ).toThrow();
  });

  it('accepts CenterSquareType.FREE / NONE', () => {
    for (const c of [
      CenterSquareType.FREE,
      CenterSquareType.NONE,
    ]) {
      expect(() =>
        RecurringBoardTemplateSchema.parse(validTemplate({ centerSquareType: c })),
      ).not.toThrow();
    }
  });

  it('lastSpawnedWindowKey accepts null OR an ISO-shaped string', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(validTemplate({ lastSpawnedWindowKey: null })),
    ).not.toThrow();
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({ lastSpawnedWindowKey: '2026-05-07T00:00:00.000' }),
      ),
    ).not.toThrow();
  });

  it('rejects invalid id (non-UUID)', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(validTemplate({ id: 'not-a-uuid' })),
    ).toThrow();
  });

  it('full template schema allows empty seedTaskIds (mid-edit pull tolerance)', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(validTemplate({ seedTaskIds: [] })),
    ).not.toThrow();
  });

  it('CreateInput schema rejects empty seedTaskIds (must reference at least one task at create time)', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(validCreateInput({ seedTaskIds: [] })),
    ).toThrow();
  });

  it('rejects boardSize outside {3, 4, 5}', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(validTemplate({ boardSize: 6 })),
    ).toThrow();
  });

  // ─── P1 — generalized-source fields (additive, optional) ────────────────────

  it('accepts a record with poolIds/manualTaskIds/removedTaskIds absent (genuinely un-migrated shape)', () => {
    expect(() => RecurringBoardTemplateSchema.parse(validTemplate())).not.toThrow();
  });

  it('accepts a migrated record (poolIds set, manual/removed empty)', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({ poolIds: [uuid(1)], manualTaskIds: [], removedTaskIds: [] }),
      ),
    ).not.toThrow();
  });

  it('accepts a record with manualTaskIds and removedTaskIds populated', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({
          poolIds: [uuid(1), uuid(2)],
          manualTaskIds: [uuid(3)],
          removedTaskIds: [uuid(4)],
        }),
      ),
    ).not.toThrow();
  });

  it('rejects duplicate poolIds', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({ poolIds: [uuid(1), uuid(1)] }),
      ),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate manualTaskIds', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({ manualTaskIds: [uuid(1), uuid(1)] }),
      ),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate removedTaskIds', () => {
    expect(() =>
      RecurringBoardTemplateSchema.parse(
        validTemplate({ removedTaskIds: [uuid(1), uuid(1)] }),
      ),
    ).toThrow(/duplicates/i);
  });
});

// ─── CreateRecurringBoardTemplateInputSchema ──────────────────────────────────

describe('CreateRecurringBoardTemplateInputSchema', () => {
  it('accepts a valid input', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(validCreateInput()),
    ).not.toThrow();
  });

  it('rejects empty/whitespace name', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(validCreateInput({ name: '   ' })),
    ).toThrow();
  });

  it('rejects name longer than 120 chars', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({ name: 'x'.repeat(121) }),
      ),
    ).toThrow();
  });

  it('rejects duplicate seedTaskIds', () => {
    const dupId = uuid(1);
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({
          seedTaskIds: [dupId, dupId, ...Array.from({ length: 22 }, (_, i) => uuid(i + 100))],
        }),
      ),
    ).toThrow();
  });

  // ─── P1 — generalized-source fields (additive, optional) ────────────────────

  it('accepts poolIds/manualTaskIds/removedTaskIds when provided', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({
          poolIds: [uuid(1)],
          manualTaskIds: [uuid(2)],
          removedTaskIds: [uuid(3)],
        }),
      ),
    ).not.toThrow();
  });

  it('rejects duplicate poolIds', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({ poolIds: [uuid(1), uuid(1)] }),
      ),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate manualTaskIds', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({ manualTaskIds: [uuid(1), uuid(1)] }),
      ),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate removedTaskIds', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({ removedTaskIds: [uuid(1), uuid(1)] }),
      ),
    ).toThrow(/duplicates/i);
  });
});

// ─── UpdateRecurringBoardTemplateInputSchema ──────────────────────────────────

describe('UpdateRecurringBoardTemplateInputSchema', () => {
  it('accepts an empty patch (no-op update)', () => {
    expect(() => UpdateRecurringBoardTemplateInputSchema.parse({})).not.toThrow();
  });

  it('accepts a partial patch (one field at a time)', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({ isActive: false }),
    ).not.toThrow();
  });

  it('rejects duplicate seedTaskIds when seedTaskIds is provided', () => {
    const dup = uuid(1);
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({ seedTaskIds: [dup, dup] }),
    ).toThrow();
  });

  it('skips the dedupe check when seedTaskIds is omitted', () => {
    // Sanity: an update that omits seedTaskIds entirely should not invoke the
    // dedupe refinement (otherwise it would always pass — this test guards
    // against accidental over-validation).
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({ name: 'Renamed' }),
    ).not.toThrow();
  });

  it('accepts a patch that sets centerSquareType=FREE', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        centerSquareType: CenterSquareType.FREE,
      }),
    ).not.toThrow();
  });

  // ─── P1 — generalized-source fields (additive, optional) ────────────────────

  it('accepts a poolIds/manualTaskIds/removedTaskIds patch', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        poolIds: [uuid(1)],
        manualTaskIds: [uuid(2)],
        removedTaskIds: [uuid(3)],
      }),
    ).not.toThrow();
  });

  it('rejects duplicate poolIds in a patch', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({ poolIds: [uuid(1), uuid(1)] }),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate manualTaskIds in a patch', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        manualTaskIds: [uuid(1), uuid(1)],
      }),
    ).toThrow(/duplicates/i);
  });

  it('rejects duplicate removedTaskIds in a patch', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        removedTaskIds: [uuid(1), uuid(1)],
      }),
    ).toThrow(/duplicates/i);
  });
});

// ─── BoardSchema.spawnedFromTemplateId (Phase 6.2 additive) ───────────────────

describe('BoardSchema.spawnedFromTemplateId', () => {
  it('accepts a Board without spawnedFromTemplateId (forward-compat for pre-6.2 peers)', () => {
    expect(() => BoardSchema.parse(validBoard())).not.toThrow();
  });

  it('accepts a Board with spawnedFromTemplateId (UUID)', () => {
    expect(() =>
      BoardSchema.parse(validBoard({ spawnedFromTemplateId: uuid(42) })),
    ).not.toThrow();
  });

  it('rejects spawnedFromTemplateId that is not a UUID', () => {
    expect(() =>
      BoardSchema.parse(validBoard({ spawnedFromTemplateId: 'not-a-uuid' })),
    ).toThrow();
  });
});
