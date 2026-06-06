import { CreateTaskInputSchema, UpdateTaskInputSchema } from '../../src/validation/schemas';
import { TaskType } from '../../src/constants/enums';

/**
 * Tests for the Phase 2 `sharedCounterFieldsConsistent` Zod refinement.
 *
 * The refinement governs `sharedCounterId` + `baseline` on both
 * `CreateTaskInputSchema` and `UpdateTaskInputSchema`. Shape rules:
 *
 *   1. Both null/undefined → accepted (non-linked task).
 *   2. sharedCounterId set + baseline set (>= 0 integer) → accepted.
 *   3. sharedCounterId set + baseline null/absent → REJECTED.
 *   4. sharedCounterId null/absent + baseline set → REJECTED.
 *   5. baseline present but negative → REJECTED (baseline is non-negative).
 */

// ── Helpers ───────────────────────────────────────────────────────────────────

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

// ── CreateTaskInputSchema — sharedCounterFieldsConsistent ────────────────────

describe('CreateTaskInputSchema — sharedCounterId + baseline refinement', () => {
  it('accepts when both sharedCounterId and baseline are absent', () => {
    const result = CreateTaskInputSchema.safeParse(validCounting());
    expect(result.success).toBe(true);
  });

  it('accepts when both sharedCounterId and baseline are null', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: null, baseline: null }),
    );
    expect(result.success).toBe(true);
  });

  it('accepts when sharedCounterId is set and baseline is 0 (Inherit mode)', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: 'source-task-id-123', baseline: 0 }),
    );
    expect(result.success).toBe(true);
  });

  it('accepts when sharedCounterId is set and baseline is a positive integer (Start from zero mode)', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: 'source-task-id-456', baseline: 200 }),
    );
    expect(result.success).toBe(true);
  });

  it('rejects when sharedCounterId is set but baseline is null', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: 'source-task-id-789', baseline: null }),
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages.some((m) => m.includes('sharedCounterId and baseline must both be set'))).toBe(true);
    }
  });

  it('rejects when sharedCounterId is set but baseline is absent', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: 'source-task-id-abc' }),
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages.some((m) => m.includes('sharedCounterId and baseline must both be set'))).toBe(true);
    }
  });

  it('rejects when baseline is set but sharedCounterId is null', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: null, baseline: 0 }),
    );
    // null sharedCounterId + baseline 0 → inconsistent (null treated as absent)
    expect(result.success).toBe(false);
  });

  it('rejects when baseline is set but sharedCounterId is absent', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ baseline: 50 }),
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages.some((m) => m.includes('sharedCounterId and baseline must both be set'))).toBe(true);
    }
  });

  it('rejects when baseline is a negative integer', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: 'source-id', baseline: -1 }),
    );
    // Negative baseline fails the z.number().int().min(0) constraint.
    expect(result.success).toBe(false);
  });

  it('rejects when baseline is a non-integer float', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: 'source-id', baseline: 1.5 }),
    );
    // Non-integer baseline fails the z.number().int() constraint.
    expect(result.success).toBe(false);
  });
});

// ── UpdateTaskInputSchema — sharedCounterFieldsConsistent ────────────────────

describe('UpdateTaskInputSchema — sharedCounterId + baseline refinement', () => {
  it('accepts an empty patch (no shared-counter fields)', () => {
    const result = UpdateTaskInputSchema.safeParse({ title: 'Updated title' });
    expect(result.success).toBe(true);
  });

  it('accepts clearing both fields with null sentinels', () => {
    const result = UpdateTaskInputSchema.safeParse({
      sharedCounterId: null,
      baseline: null,
    });
    expect(result.success).toBe(true);
  });

  it('accepts setting both sharedCounterId and baseline', () => {
    const result = UpdateTaskInputSchema.safeParse({
      sharedCounterId: 'source-id',
      baseline: 0,
    });
    expect(result.success).toBe(true);
  });

  it('rejects setting sharedCounterId without baseline', () => {
    const result = UpdateTaskInputSchema.safeParse({
      sharedCounterId: 'source-id',
    });
    expect(result.success).toBe(false);
  });

  it('rejects setting baseline without sharedCounterId', () => {
    const result = UpdateTaskInputSchema.safeParse({
      baseline: 100,
    });
    expect(result.success).toBe(false);
  });
});
