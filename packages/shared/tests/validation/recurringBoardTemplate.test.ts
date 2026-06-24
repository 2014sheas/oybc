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

  it('accepts CenterSquareType.FREE / CUSTOM_FREE / NONE', () => {
    for (const c of [
      CenterSquareType.FREE,
      CenterSquareType.CUSTOM_FREE,
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

  it('CUSTOM_FREE center requires centerSquareCustomName', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({ centerSquareType: CenterSquareType.CUSTOM_FREE }),
      ),
    ).toThrow();
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({
          centerSquareType: CenterSquareType.CUSTOM_FREE,
          centerSquareCustomName: 'My center',
        }),
      ),
    ).not.toThrow();
  });

  it('CUSTOM_FREE center rejects whitespace-only centerSquareCustomName', () => {
    expect(() =>
      CreateRecurringBoardTemplateInputSchema.parse(
        validCreateInput({
          centerSquareType: CenterSquareType.CUSTOM_FREE,
          centerSquareCustomName: '   ',
        }),
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

  it('rejects a patch that sets centerSquareType=CUSTOM_FREE without a non-blank centerSquareCustomName', () => {
    // Setting CUSTOM_FREE without a label in the same patch would create a
    // template whose center cell has no displayable text — the refinement
    // requires both fields travel together.
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        centerSquareType: CenterSquareType.CUSTOM_FREE,
      }),
    ).toThrow();
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        centerSquareType: CenterSquareType.CUSTOM_FREE,
        centerSquareCustomName: '   ',
      }),
    ).toThrow();
  });

  it('accepts a patch that sets CUSTOM_FREE WITH a non-blank centerSquareCustomName', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        centerSquareType: CenterSquareType.CUSTOM_FREE,
        centerSquareCustomName: 'My center',
      }),
    ).not.toThrow();
  });

  it('accepts a patch that switches AWAY from CUSTOM_FREE without a label (label becomes irrelevant)', () => {
    expect(() =>
      UpdateRecurringBoardTemplateInputSchema.parse({
        centerSquareType: CenterSquareType.FREE,
      }),
    ).not.toThrow();
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
