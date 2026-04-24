import {
  TaskSchema,
  BoardTaskSchema,
  CompoundChildSchema,
  CreateCompoundChildInputSchema,
} from '../../src/validation/schemas';
import { TaskType, OperatorType } from '../../src/constants/enums';

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Returns the smallest valid COMPOUND task (all required fields).
 * Spread overrides per test.
 */
function validCompoundTask(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000010',
    userId: 'user-1',
    title: 'Compound goal',
    type: TaskType.COMPOUND,
    operator: OperatorType.AND,
    totalCompletions: 0,
    totalInstances: 0,
    isCompleted: false,
    createdAt: '2026-04-23T12:00:00.000Z',
    updatedAt: '2026-04-23T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/**
 * Returns the smallest valid NORMAL task (for testing non-compound branch).
 */
function validNormalTask(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000011',
    userId: 'user-1',
    title: 'Walk the dog',
    type: TaskType.NORMAL,
    totalCompletions: 0,
    totalInstances: 0,
    isCompleted: false,
    createdAt: '2026-04-23T12:00:00.000Z',
    updatedAt: '2026-04-23T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/**
 * Returns a valid COUNTING task.
 */
function validCountingTask(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000012',
    userId: 'user-1',
    title: 'Read 100 pages',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'pages',
    maxCount: 100,
    totalCompletions: 0,
    totalInstances: 0,
    isCompleted: false,
    createdAt: '2026-04-23T12:00:00.000Z',
    updatedAt: '2026-04-23T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/**
 * Returns a valid board task placement (no completion fields).
 */
function validBoardTask(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000020',
    boardId: '00000000-0000-0000-0000-000000000021',
    taskId: '00000000-0000-0000-0000-000000000022',
    row: 0,
    col: 1,
    isCenter: false,
    createdAt: '2026-04-23T12:00:00.000Z',
    updatedAt: '2026-04-23T12:00:00.000Z',
    version: 1,
    ...overrides,
  };
}

/**
 * Returns a valid CompoundChild record.
 */
function validCompoundChild(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-000000000030',
    compoundTaskId: '00000000-0000-0000-0000-000000000031',
    childTaskId: '00000000-0000-0000-0000-000000000032',
    childIndex: 0,
    createdAt: '2026-04-23T12:00:00.000Z',
    updatedAt: '2026-04-23T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

/**
 * Returns a valid CreateCompoundChildInput.
 */
function validCreateCompoundChild(overrides: Record<string, unknown> = {}) {
  return {
    compoundTaskId: '00000000-0000-0000-0000-000000000031',
    childTaskId: '00000000-0000-0000-0000-000000000032',
    childIndex: 0,
    ...overrides,
  };
}

// ── TaskSchema — compound operator branch ─────────────────────────────────────

describe('TaskSchema — compound operator refines', () => {
  it('accepts a compound task with operator=AND', () => {
    const result = TaskSchema.safeParse(validCompoundTask({ operator: OperatorType.AND }));
    expect(result.success).toBe(true);
  });

  it('accepts a compound task with operator=OR (no threshold required)', () => {
    const result = TaskSchema.safeParse(validCompoundTask({ operator: OperatorType.OR }));
    expect(result.success).toBe(true);
  });

  it('accepts a compound task with operator=M_OF_N and threshold=2', () => {
    const result = TaskSchema.safeParse(
      validCompoundTask({ operator: OperatorType.M_OF_N, threshold: 2 })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a compound task with no operator', () => {
    const result = TaskSchema.safeParse(validCompoundTask({ operator: undefined }));
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages).toContain("Task with type='compound' must have an operator");
    }
  });

  it('rejects a compound task with operator=M_OF_N but no threshold', () => {
    const result = TaskSchema.safeParse(
      validCompoundTask({ operator: OperatorType.M_OF_N, threshold: undefined })
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages).toContain("Task with operator='M_OF_N' must have a threshold");
    }
  });

  it('accepts a NORMAL task without operator (operator is optional for non-compound)', () => {
    const result = TaskSchema.safeParse(validNormalTask());
    expect(result.success).toBe(true);
  });

  it('accepts a COUNTING task without operator', () => {
    const result = TaskSchema.safeParse(validCountingTask());
    expect(result.success).toBe(true);
  });
});

// ── TaskSchema — global completion fields ─────────────────────────────────────

describe('TaskSchema — completion fields', () => {
  it('accepts isCompleted=true with completedAt', () => {
    const result = TaskSchema.safeParse(
      validNormalTask({
        isCompleted: true,
        completedAt: '2026-04-23T12:00:00.000Z',
      })
    );
    expect(result.success).toBe(true);
  });

  it('accepts isCompleted=false with no completedAt', () => {
    const result = TaskSchema.safeParse(validNormalTask({ isCompleted: false }));
    expect(result.success).toBe(true);
  });

  it('rejects a task with isCompleted missing (required field)', () => {
    const base = validNormalTask();
    delete (base as Record<string, unknown>).isCompleted;
    const result = TaskSchema.safeParse(base);
    expect(result.success).toBe(false);
  });

  it('accepts a task with currentCount=0', () => {
    const result = TaskSchema.safeParse(validCountingTask({ currentCount: 0 }));
    expect(result.success).toBe(true);
  });

  it('accepts a task with a positive currentCount', () => {
    const result = TaskSchema.safeParse(validCountingTask({ currentCount: 42 }));
    expect(result.success).toBe(true);
  });

  it('rejects a task with currentCount=-1 (must be nonnegative)', () => {
    const result = TaskSchema.safeParse(validCountingTask({ currentCount: -1 }));
    expect(result.success).toBe(false);
  });
});

// ── BoardTaskSchema — simplified (no completion fields) ───────────────────────

describe('BoardTaskSchema — post-simplification', () => {
  it('accepts a valid placement with no completion fields', () => {
    const result = BoardTaskSchema.safeParse(validBoardTask());
    expect(result.success).toBe(true);
  });

  it('silently strips an extra isCompleted field (Zod default strip behavior)', () => {
    // Default Zod object validation strips unknown keys — passing isCompleted
    // does not cause failure; it is simply discarded on parse.
    const result = BoardTaskSchema.safeParse(
      validBoardTask({ isCompleted: true })
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect((result.data as Record<string, unknown>).isCompleted).toBeUndefined();
    }
  });

  it('rejects a board task with a negative row', () => {
    const result = BoardTaskSchema.safeParse(validBoardTask({ row: -1 }));
    expect(result.success).toBe(false);
  });

  it('rejects a board task with version=0', () => {
    const result = BoardTaskSchema.safeParse(validBoardTask({ version: 0 }));
    expect(result.success).toBe(false);
  });
});

// ── CompoundChildSchema ───────────────────────────────────────────────────────

describe('CompoundChildSchema', () => {
  it('accepts a valid compound child record', () => {
    const result = CompoundChildSchema.safeParse(validCompoundChild());
    expect(result.success).toBe(true);
  });

  it('rejects a self-referencing child (compoundTaskId === childTaskId)', () => {
    const sharedId = '00000000-0000-0000-0000-000000000031';
    const result = CompoundChildSchema.safeParse(
      validCompoundChild({ compoundTaskId: sharedId, childTaskId: sharedId })
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages).toContain(
        'CompoundChild must not self-reference (compoundTaskId == childTaskId)'
      );
    }
  });

  it('rejects a negative childIndex', () => {
    const result = CompoundChildSchema.safeParse(validCompoundChild({ childIndex: -1 }));
    expect(result.success).toBe(false);
  });

  it('accepts childIndex=0 (zero is a valid nonnegative index)', () => {
    const result = CompoundChildSchema.safeParse(validCompoundChild({ childIndex: 0 }));
    expect(result.success).toBe(true);
  });

  it('accepts a deleted child record with deletedAt set', () => {
    const result = CompoundChildSchema.safeParse(
      validCompoundChild({ isDeleted: true, deletedAt: '2026-04-23T12:00:00.000Z' })
    );
    expect(result.success).toBe(true);
  });
});

// ── CreateCompoundChildInputSchema ────────────────────────────────────────────

describe('CreateCompoundChildInputSchema', () => {
  it('accepts a valid create input', () => {
    const result = CreateCompoundChildInputSchema.safeParse(validCreateCompoundChild());
    expect(result.success).toBe(true);
  });

  it('rejects a self-referencing input (compoundTaskId === childTaskId)', () => {
    const sharedId = '00000000-0000-0000-0000-000000000031';
    const result = CreateCompoundChildInputSchema.safeParse(
      validCreateCompoundChild({ compoundTaskId: sharedId, childTaskId: sharedId })
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages).toContain(
        'CompoundChild must not self-reference (compoundTaskId == childTaskId)'
      );
    }
  });

  it('rejects a non-UUID compoundTaskId', () => {
    const result = CreateCompoundChildInputSchema.safeParse(
      validCreateCompoundChild({ compoundTaskId: 'not-a-uuid' })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a negative childIndex', () => {
    const result = CreateCompoundChildInputSchema.safeParse(
      validCreateCompoundChild({ childIndex: -1 })
    );
    expect(result.success).toBe(false);
  });

  it('accepts childIndex=0', () => {
    const result = CreateCompoundChildInputSchema.safeParse(
      validCreateCompoundChild({ childIndex: 0 })
    );
    expect(result.success).toBe(true);
  });
});
