import { CreateTaskInputSchema, CreateTaskStepInputSchema } from '../../src/validation/schemas';
import { TaskType } from '../../src/constants/enums';

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Returns the smallest valid NORMAL task input.
 * Use this as a base and spread overrides for each individual test.
 */
function validNormal(overrides: Record<string, unknown> = {}) {
  return {
    title: 'Walk the dog',
    type: TaskType.NORMAL,
    ...overrides,
  };
}

/**
 * Returns a valid COUNTING task input (all three required extra fields present).
 */
function validCounting(overrides: Record<string, unknown> = {}) {
  return {
    title: 'Read pages',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'pages',
    maxCount: 100,
    ...overrides,
  };
}

/**
 * Returns a valid PROGRESS task input with one step.
 */
function validProgress(overrides: Record<string, unknown> = {}) {
  return {
    title: 'Finish project',
    type: TaskType.PROGRESS,
    steps: [{ title: 'Draft outline', type: TaskType.NORMAL }],
    ...overrides,
  };
}

// ── Happy path ────────────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — happy path', () => {
  it('accepts a minimal valid NORMAL task', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal());
    expect(result.success).toBe(true);
  });

  it('accepts a NORMAL task with an optional description', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ description: 'Take the dog around the block' })
    );
    expect(result.success).toBe(true);
  });

  it('accepts a valid COUNTING task with action, unit, and maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(validCounting());
    expect(result.success).toBe(true);
  });

  it('accepts a valid PROGRESS task with at least one step', () => {
    const result = CreateTaskInputSchema.safeParse(validProgress());
    expect(result.success).toBe(true);
  });

  it('accepts a PROGRESS task with multiple steps', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({
        steps: [
          { title: 'Step one', type: TaskType.NORMAL },
          { title: 'Step two', type: TaskType.NORMAL },
        ],
      })
    );
    expect(result.success).toBe(true);
  });

  it('preserves parsed values on success', () => {
    const input = validCounting();
    const result = CreateTaskInputSchema.safeParse(input);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.title).toBe('Read pages');
      expect(result.data.type).toBe(TaskType.COUNTING);
      expect(result.data.maxCount).toBe(100);
    }
  });
});

// ── title field ───────────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — title', () => {
  it('rejects an empty title', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal({ title: '' }));
    expect(result.success).toBe(false);
  });

  it('rejects a missing title', () => {
    const { title: _omitted, ...withoutTitle } = validNormal() as {
      title: string;
      type: TaskType;
    };
    const result = CreateTaskInputSchema.safeParse(withoutTitle);
    expect(result.success).toBe(false);
  });

  it('accepts a title of exactly 1 character', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal({ title: 'A' }));
    expect(result.success).toBe(true);
  });

  it('accepts a title of exactly 200 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ title: 'A'.repeat(200) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a title of 201 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ title: 'A'.repeat(201) })
    );
    expect(result.success).toBe(false);
  });
});

// ── description field ─────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — description', () => {
  it('accepts input with no description field (optional)', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal());
    expect(result.success).toBe(true);
  });

  it('accepts an empty string description', () => {
    // Zod .optional() does not enforce min(1) on description — empty string is valid
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ description: '' })
    );
    expect(result.success).toBe(true);
  });

  it('accepts a description of exactly 1000 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ description: 'B'.repeat(1000) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a description of 1001 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ description: 'B'.repeat(1001) })
    );
    expect(result.success).toBe(false);
  });
});

// ── type field ────────────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — type', () => {
  it('accepts TaskType.NORMAL', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal({ type: TaskType.NORMAL }));
    expect(result.success).toBe(true);
  });

  it('accepts TaskType.COUNTING (with required extra fields)', () => {
    const result = CreateTaskInputSchema.safeParse(validCounting());
    expect(result.success).toBe(true);
  });

  it('accepts TaskType.PROGRESS (with required steps)', () => {
    const result = CreateTaskInputSchema.safeParse(validProgress());
    expect(result.success).toBe(true);
  });

  it('rejects an unrecognised type string', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ type: 'checkbox' })
    );
    expect(result.success).toBe(false);
  });

  it('rejects an empty type string', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal({ type: '' }));
    expect(result.success).toBe(false);
  });

  it('rejects a missing type field', () => {
    const { type: _omitted, ...withoutType } = validNormal() as {
      title: string;
      type: TaskType;
    };
    const result = CreateTaskInputSchema.safeParse(withoutType);
    expect(result.success).toBe(false);
  });
});

// ── action field ──────────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — action (optional field)', () => {
  it('accepts input with no action field', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal());
    expect(result.success).toBe(true);
  });

  it('accepts an action of exactly 50 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ action: 'C'.repeat(50) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects an action of 51 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ action: 'C'.repeat(51) })
    );
    expect(result.success).toBe(false);
  });
});

// ── unit field ────────────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — unit (optional field)', () => {
  it('accepts input with no unit field', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal());
    expect(result.success).toBe(true);
  });

  it('accepts a unit of exactly 50 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ unit: 'D'.repeat(50) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a unit of 51 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ unit: 'D'.repeat(51) })
    );
    expect(result.success).toBe(false);
  });
});

// ── maxCount field ────────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — maxCount (optional field)', () => {
  it('accepts input with no maxCount field', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal());
    expect(result.success).toBe(true);
  });

  it('accepts a positive integer maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal({ maxCount: 50 }));
    expect(result.success).toBe(true);
  });

  it('rejects maxCount of zero', () => {
    // z.number().int().positive() requires > 0
    const result = CreateTaskInputSchema.safeParse(validNormal({ maxCount: 0 }));
    expect(result.success).toBe(false);
  });

  it('rejects a negative maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ maxCount: -5 })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a non-integer maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(
      validNormal({ maxCount: 10.5 })
    );
    expect(result.success).toBe(false);
  });
});

// ── COUNTING refine ───────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — COUNTING type refinement', () => {
  it('rejects a COUNTING task missing action', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ action: undefined })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a COUNTING task missing unit', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ unit: undefined })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a COUNTING task missing maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ maxCount: undefined })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a COUNTING task missing all three extra fields', () => {
    const result = CreateTaskInputSchema.safeParse({
      title: 'Count something',
      type: TaskType.COUNTING,
    });
    expect(result.success).toBe(false);
  });

  it('includes the correct error message when COUNTING fields are missing', () => {
    const result = CreateTaskInputSchema.safeParse({
      title: 'Count something',
      type: TaskType.COUNTING,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages).toContain(
        'Counting tasks must have action, unit, and maxCount'
      );
    }
  });

  it('accepts a COUNTING task when all required fields are present', () => {
    const result = CreateTaskInputSchema.safeParse(validCounting());
    expect(result.success).toBe(true);
  });
});

// ── PROGRESS refine ───────────────────────────────────────────────────────────

describe('CreateTaskInputSchema — PROGRESS type refinement', () => {
  it('rejects a PROGRESS task with no steps field', () => {
    const result = CreateTaskInputSchema.safeParse({
      title: 'Multi-step task',
      type: TaskType.PROGRESS,
    });
    expect(result.success).toBe(false);
  });

  it('rejects a PROGRESS task with an empty steps array', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({ steps: [] })
    );
    expect(result.success).toBe(false);
  });

  it('includes the correct error message when steps are missing', () => {
    const result = CreateTaskInputSchema.safeParse({
      title: 'Multi-step task',
      type: TaskType.PROGRESS,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages).toContain(
        'Progress tasks must have at least one step'
      );
    }
  });

  it('accepts a PROGRESS task with exactly one step', () => {
    const result = CreateTaskInputSchema.safeParse(validProgress());
    expect(result.success).toBe(true);
  });

  it('does not require steps for a NORMAL task', () => {
    const result = CreateTaskInputSchema.safeParse(validNormal());
    expect(result.success).toBe(true);
  });

  it('does not require steps for a COUNTING task', () => {
    const result = CreateTaskInputSchema.safeParse(validCounting());
    expect(result.success).toBe(true);
  });
});

// ── steps array validation ────────────────────────────────────────────────────

describe('CreateTaskInputSchema — steps array (CreateTaskStepInputSchema)', () => {
  it('rejects a step with an empty title', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({
        steps: [{ title: '', type: TaskType.NORMAL }],
      })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a step with a title exceeding 200 characters', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({
        steps: [{ title: 'E'.repeat(201), type: TaskType.NORMAL }],
      })
    );
    expect(result.success).toBe(false);
  });

  it('rejects a step with an invalid type', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({
        steps: [{ title: 'Valid step', type: 'unknown' }],
      })
    );
    expect(result.success).toBe(false);
  });

  it('accepts a step with a positive integer maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({
        steps: [{ title: 'Counted step', type: TaskType.COUNTING, action: 'Do', unit: 'times', maxCount: 5 }],
      })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a step with a non-positive maxCount', () => {
    const result = CreateTaskInputSchema.safeParse(
      validProgress({
        steps: [{ title: 'Bad step', type: TaskType.COUNTING, maxCount: 0 }],
      })
    );
    expect(result.success).toBe(false);
  });
});

// ── CreateTaskStepInputSchema (direct) ──────────────────────────────────────

/**
 * Returns a minimal valid NORMAL step input.
 */
function validStep(overrides: Record<string, unknown> = {}) {
  return {
    title: 'Draft outline',
    type: TaskType.NORMAL,
    ...overrides,
  };
}

/**
 * Returns a valid COUNTING step input with action, unit, and maxCount.
 */
function validCountingStep(overrides: Record<string, unknown> = {}) {
  return {
    title: 'Read chapters',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'chapters',
    maxCount: 10,
    ...overrides,
  };
}

describe('CreateTaskStepInputSchema — happy path', () => {
  it('accepts a minimal valid NORMAL step (title + type only)', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep());
    expect(result.success).toBe(true);
  });

  it('accepts a valid COUNTING step with action, unit, and maxCount', () => {
    const result = CreateTaskStepInputSchema.safeParse(validCountingStep());
    expect(result.success).toBe(true);
  });

  it('preserves parsed values on success', () => {
    const result = CreateTaskStepInputSchema.safeParse(validCountingStep());
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.title).toBe('Read chapters');
      expect(result.data.type).toBe(TaskType.COUNTING);
      expect(result.data.action).toBe('Read');
      expect(result.data.unit).toBe('chapters');
      expect(result.data.maxCount).toBe(10);
    }
  });

  it('accepts a PROGRESS type step (schema does not prevent recursion)', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ type: TaskType.PROGRESS })
    );
    expect(result.success).toBe(true);
  });
});

describe('CreateTaskStepInputSchema — title', () => {
  it('rejects an empty title', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ title: '' }));
    expect(result.success).toBe(false);
  });

  it('rejects a missing title', () => {
    const { title: _omitted, ...withoutTitle } = validStep();
    const result = CreateTaskStepInputSchema.safeParse(withoutTitle);
    expect(result.success).toBe(false);
  });

  it('accepts a title of exactly 1 character', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ title: 'X' }));
    expect(result.success).toBe(true);
  });

  it('accepts a title of exactly 200 characters', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ title: 'A'.repeat(200) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a title of 201 characters', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ title: 'A'.repeat(201) })
    );
    expect(result.success).toBe(false);
  });
});

describe('CreateTaskStepInputSchema — type', () => {
  it('rejects a missing type', () => {
    const { type: _omitted, ...withoutType } = validStep();
    const result = CreateTaskStepInputSchema.safeParse(withoutType);
    expect(result.success).toBe(false);
  });

  it('rejects an unrecognised type string', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ type: 'checkbox' })
    );
    expect(result.success).toBe(false);
  });

  it('rejects an empty type string', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ type: '' }));
    expect(result.success).toBe(false);
  });
});

describe('CreateTaskStepInputSchema — action (optional field)', () => {
  it('accepts input with no action field', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep());
    expect(result.success).toBe(true);
  });

  it('accepts an action of exactly 50 characters', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ action: 'C'.repeat(50) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects an action of 51 characters', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ action: 'C'.repeat(51) })
    );
    expect(result.success).toBe(false);
  });
});

describe('CreateTaskStepInputSchema — unit (optional field)', () => {
  it('accepts input with no unit field', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep());
    expect(result.success).toBe(true);
  });

  it('accepts a unit of exactly 50 characters', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ unit: 'D'.repeat(50) })
    );
    expect(result.success).toBe(true);
  });

  it('rejects a unit of 51 characters', () => {
    const result = CreateTaskStepInputSchema.safeParse(
      validStep({ unit: 'D'.repeat(51) })
    );
    expect(result.success).toBe(false);
  });
});

describe('CreateTaskStepInputSchema — maxCount (optional field)', () => {
  it('accepts input with no maxCount field', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep());
    expect(result.success).toBe(true);
  });

  it('accepts a positive integer maxCount', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ maxCount: 42 }));
    expect(result.success).toBe(true);
  });

  it('rejects maxCount of zero', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ maxCount: 0 }));
    expect(result.success).toBe(false);
  });

  it('rejects a negative maxCount', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ maxCount: -3 }));
    expect(result.success).toBe(false);
  });

  it('rejects a non-integer maxCount', () => {
    const result = CreateTaskStepInputSchema.safeParse(validStep({ maxCount: 2.5 }));
    expect(result.success).toBe(false);
  });
});
