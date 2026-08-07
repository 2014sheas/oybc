import {
  BoardSchema,
  TaskSchema,
  TaskStepSchema,
  BoardTaskSchema,
  CompositeTaskSchema,
  CompositeNodeSchema,
} from '../../src/validation/schemas';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
} from '../../src/constants/enums';

/**
 * These schemas gate documents pulled from Firestore before they reach
 * the local source-of-truth database (Dexie on web, GRDB on iOS). The
 * audit flagged that web's `applyRemoteSubdoc` used to cast raw remote
 * data as `SyncableEntity` with no validation — this suite protects the
 * invariants the pull path now depends on.
 *
 * The key failure modes covered:
 *   - missing required fields
 *   - version < 1 (would always lose LWW and could corrupt the resolver)
 *   - invalid enum values (would break UI rendering on read)
 *   - type drift (string where number expected, etc.)
 *
 * Anything accepted here will be written to the local DB, so the bar
 * is "everything the code downstream assumes is true."
 */

function validBoard(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000001',
    userId: 'user-1',
    name: 'Daily Goals',
    status: BoardStatus.DRAFT,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: '2026-04-17T00:00:00.000Z',
    endDate: '2026-04-18T00:00:00.000Z',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-04-17T00:00:00.000Z',
    updatedAt: '2026-04-17T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function validTask(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000002',
    userId: 'user-1',
    title: 'Walk the dog',
    type: TaskType.NORMAL,
    totalCompletions: 0,
    totalInstances: 0,
    isCompleted: false,
    createdAt: '2026-04-17T00:00:00.000Z',
    updatedAt: '2026-04-17T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('BoardSchema pull validation', () => {
  it('accepts a well-formed board', () => {
    expect(BoardSchema.safeParse(validBoard()).success).toBe(true);
  });

  it('rejects a board with version = 0', () => {
    const result = BoardSchema.safeParse(validBoard({ version: 0 }));
    expect(result.success).toBe(false);
  });

  it('rejects a board with negative version', () => {
    const result = BoardSchema.safeParse(validBoard({ version: -3 }));
    expect(result.success).toBe(false);
  });

  it('rejects a board with a non-UUID id', () => {
    const result = BoardSchema.safeParse(validBoard({ id: 'not-a-uuid' }));
    expect(result.success).toBe(false);
  });

  it('rejects a board with an unknown status enum', () => {
    const result = BoardSchema.safeParse(validBoard({ status: 'weird' }));
    expect(result.success).toBe(false);
  });

  it('rejects a board with a missing userId', () => {
    const base = validBoard();
    delete (base as Record<string, unknown>).userId;
    expect(BoardSchema.safeParse(base).success).toBe(false);
  });

  it('rejects a board with a boardSize outside {3,4,5}', () => {
    const result = BoardSchema.safeParse(validBoard({ boardSize: 7 }));
    expect(result.success).toBe(false);
  });

  it('accepts a board with local-ISO startDate/endDate (no Z/offset suffix)', () => {
    // Real clients write `startDate`/`endDate` via `toLocalISO()` for
    // calendar-bound boards, which omits the timezone suffix. The
    // default `z.string().datetime()` rejects those; we use a permissive
    // form on the timeframe bounds so pull validation doesn't drop
    // every real board on arrival.
    const result = BoardSchema.safeParse(
      validBoard({
        startDate: '2026-04-17T00:00:00.000',
        endDate: '2026-04-17T23:59:59.999',
      })
    );
    expect(result.success).toBe(true);
  });

  it('accepts a board whose endDate precedes startDate (entity schema does not refine date ordering)', () => {
    // The create-input schema refines this; the entity schema doesn't,
    // so both orderings parse. This test pins that behavior so we
    // notice if it changes. Misordered persisted rows aren't valuable
    // in practice, but reject-on-read here would block legitimate sync
    // of historical data written under an older schema.
    const result = BoardSchema.safeParse(
      validBoard({
        startDate: '2026-04-18T00:00:00.000Z',
        endDate: '2026-04-17T00:00:00.000Z',
      })
    );
    expect(result.success).toBe(true);
  });

  it('accepts an indefinite board with no endDate', () => {
    const base = validBoard({ timeframe: Timeframe.INDEFINITE });
    delete (base as Record<string, unknown>).endDate;
    expect(BoardSchema.safeParse(base).success).toBe(true);
  });

  it('coerces a legacy custom_free center to FREE instead of rejecting', () => {
    // CUSTOM_FREE was a shipped center type; a doc synced from an unmigrated
    // peer still carries the raw string. It must normalize, not fail safeParse
    // (which would skip the doc forever). Mirrors iOS's decode fallback.
    const result = BoardSchema.safeParse(validBoard({ centerSquareType: 'custom_free' }));
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.centerSquareType).toBe(CenterSquareType.FREE);
    }
  });

  it('accepts a board with timeframe INDEFINITE (new enum value)', () => {
    expect(
      BoardSchema.safeParse(validBoard({ timeframe: Timeframe.INDEFINITE })).success
    ).toBe(true);
  });
});

describe('TaskSchema pull validation', () => {
  it('accepts a well-formed task', () => {
    expect(TaskSchema.safeParse(validTask()).success).toBe(true);
  });

  it('rejects a task with version = 0', () => {
    expect(TaskSchema.safeParse(validTask({ version: 0 })).success).toBe(false);
  });

  it('rejects a task with missing userId', () => {
    const base = validTask();
    delete (base as Record<string, unknown>).userId;
    expect(TaskSchema.safeParse(base).success).toBe(false);
  });

  it('rejects a task with unknown type enum', () => {
    expect(TaskSchema.safeParse(validTask({ type: 'composite-new' })).success).toBe(false);
  });

  it('rejects a task with empty title', () => {
    expect(TaskSchema.safeParse(validTask({ title: '' })).success).toBe(false);
  });

  it('rejects a task whose title exceeds 200 chars', () => {
    const longTitle = 'a'.repeat(201);
    expect(TaskSchema.safeParse(validTask({ title: longTitle })).success).toBe(false);
  });
});

describe('TaskStepSchema pull validation', () => {
  const validStep = () => ({
    id: '00000000-0000-0000-0000-000000000003',
    taskId: '00000000-0000-0000-0000-000000000004',
    stepIndex: 0,
    title: 'Step 1',
    type: TaskType.NORMAL,
    createdAt: '2026-04-17T00:00:00.000Z',
    updatedAt: '2026-04-17T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  });

  it('accepts a well-formed step', () => {
    expect(TaskStepSchema.safeParse(validStep()).success).toBe(true);
  });

  it('rejects a step with a negative stepIndex', () => {
    expect(TaskStepSchema.safeParse({ ...validStep(), stepIndex: -1 }).success).toBe(false);
  });

  it('rejects a step with version = 0', () => {
    expect(TaskStepSchema.safeParse({ ...validStep(), version: 0 }).success).toBe(false);
  });
});

describe('BoardTaskSchema pull validation', () => {
  const validBoardTask = () => ({
    id: '00000000-0000-0000-0000-000000000005',
    boardId: '00000000-0000-0000-0000-000000000006',
    taskId: '00000000-0000-0000-0000-000000000007',
    row: 0,
    col: 1,
    isCenter: false,
    createdAt: '2026-04-17T00:00:00.000Z',
    updatedAt: '2026-04-17T00:00:00.000Z',
    version: 1,
  });

  it('accepts a well-formed board task', () => {
    expect(BoardTaskSchema.safeParse(validBoardTask()).success).toBe(true);
  });

  it('rejects a board task with a negative row', () => {
    expect(BoardTaskSchema.safeParse({ ...validBoardTask(), row: -1 }).success).toBe(false);
  });

  it('rejects a board task with version = 0', () => {
    expect(BoardTaskSchema.safeParse({ ...validBoardTask(), version: 0 }).success).toBe(false);
  });

  // Board-integrity PR-2 (Part 3) — a malformed/malicious remote payload with
  // an out-of-sane-range row/col must not decode on pull.
  it('rejects a pulled board task with a row past the sane upper bound (25)', () => {
    expect(BoardTaskSchema.safeParse({ ...validBoardTask(), row: 25 }).success).toBe(false);
  });
});

describe('CompositeTaskSchema / CompositeNodeSchema pull validation', () => {
  const validComposite = () => ({
    id: '00000000-0000-0000-0000-000000000008',
    userId: 'user-1',
    title: 'Master task',
    rootNodeId: '00000000-0000-0000-0000-000000000009',
    createdAt: '2026-04-17T00:00:00.000Z',
    updatedAt: '2026-04-17T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  });

  const validNode = () => ({
    id: '00000000-0000-0000-0000-000000000009',
    compositeTaskId: '00000000-0000-0000-0000-000000000008',
    nodeIndex: 0,
    nodeType: 'leaf',
    createdAt: '2026-04-17T00:00:00.000Z',
    updatedAt: '2026-04-17T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  });

  it('accepts a well-formed composite task', () => {
    expect(CompositeTaskSchema.safeParse(validComposite()).success).toBe(true);
  });

  it('rejects a composite task with missing userId', () => {
    const base = validComposite();
    delete (base as Record<string, unknown>).userId;
    expect(CompositeTaskSchema.safeParse(base).success).toBe(false);
  });

  it('accepts a well-formed leaf node', () => {
    expect(CompositeNodeSchema.safeParse(validNode()).success).toBe(true);
  });

  it('rejects a node with an unknown nodeType', () => {
    expect(CompositeNodeSchema.safeParse({ ...validNode(), nodeType: 'branch' }).success).toBe(false);
  });
});
