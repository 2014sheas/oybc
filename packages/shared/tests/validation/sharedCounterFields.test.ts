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

// Canonical UUID fixtures — avoids the "source-task-id-xxx" non-UUID strings
// that would fail the z.string().uuid() constraint added in the PR #96 review.
const UUID_A = '11111111-1111-4111-8111-111111111111';
const UUID_B = '22222222-2222-4222-8222-222222222222';
const UUID_C = '33333333-3333-4333-8333-333333333333';
const UUID_D = '44444444-4444-4444-8444-444444444444';

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
      validCounting({ sharedCounterId: UUID_A, baseline: 0 }),
    );
    expect(result.success).toBe(true);
  });

  it('accepts when sharedCounterId is set and baseline is a positive integer (Start from zero mode)', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: UUID_B, baseline: 200 }),
    );
    expect(result.success).toBe(true);
  });

  it('rejects when sharedCounterId is set but baseline is null', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: UUID_C, baseline: null }),
    );
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(messages.some((m) => m.includes('sharedCounterId and baseline must both be set'))).toBe(true);
    }
  });

  it('rejects when sharedCounterId is set but baseline is absent', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: UUID_D }),
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
      validCounting({ sharedCounterId: UUID_A, baseline: -1 }),
    );
    // Negative baseline fails the z.number().int().min(0) constraint.
    expect(result.success).toBe(false);
  });

  it('rejects when baseline is a non-integer float', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: UUID_A, baseline: 1.5 }),
    );
    // Non-integer baseline fails the z.number().int() constraint.
    expect(result.success).toBe(false);
  });

  it('rejects when sharedCounterId is an empty string (not a UUID)', () => {
    const result = CreateTaskInputSchema.safeParse(
      validCounting({ sharedCounterId: '', baseline: 0 }),
    );
    // Empty string fails z.string().uuid() — the "" ?? null bug that motivated
    // adding the UUID constraint (PR #96 review comment #1).
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
      sharedCounterId: UUID_A,
      baseline: 0,
    });
    expect(result.success).toBe(true);
  });

  it('rejects setting sharedCounterId without baseline', () => {
    const result = UpdateTaskInputSchema.safeParse({
      sharedCounterId: UUID_A,
    });
    expect(result.success).toBe(false);
  });

  it('rejects setting baseline without sharedCounterId', () => {
    const result = UpdateTaskInputSchema.safeParse({
      baseline: 100,
    });
    expect(result.success).toBe(false);
  });

  // Regression: Issue #3 — asymmetric null-sentinel patch must be rejected.
  // A patch of `{ baseline: null }` without `sharedCounterId: null` would
  // leave the DB row with sharedCounterId set but baseline cleared — invalid.
  it('rejects clearing baseline with null while sharedCounterId remains set (asymmetric clear)', () => {
    const result = UpdateTaskInputSchema.safeParse({
      sharedCounterId: '123e4567-e89b-12d3-a456-426614174000',
      baseline: null,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      const messages = result.error.errors.map((e) => e.message);
      expect(
        messages.some((m) =>
          m.includes('Clearing baseline requires clearing sharedCounterId') ||
          m.includes('sharedCounterId and baseline must both be set'),
        ),
      ).toBe(true);
    }
  });

  // Complement: clearing both fields together is valid.
  it('accepts clearing both sharedCounterId and baseline with null sentinels', () => {
    const result = UpdateTaskInputSchema.safeParse({
      sharedCounterId: null,
      baseline: null,
    });
    expect(result.success).toBe(true);
  });
});
