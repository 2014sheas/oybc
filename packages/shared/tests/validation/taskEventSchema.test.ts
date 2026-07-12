import { TaskEventSchema } from '../../src/validation/schemas';

/**
 * taskEventSchema.test.ts — Windowed Completion PR A row-shape validation
 * (docs/WINDOWED_COMPLETION.md §New entity → Zod). The type-based
 * "event-owning tasks only" rule lives in isEventOwningTask (a TaskEvent row
 * carries no task type); this suite covers the invariants enforceable from the
 * row alone: delta ⇄ kind, occurredAt required, sync-metadata shape.
 */

function validCompletion(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-0000000000e1',
    userId: 'user-1',
    taskId: '00000000-0000-0000-0000-0000000000t1',
    kind: 'completion',
    occurredAt: '2026-07-05T12:00:00.000Z',
    createdAt: '2026-07-05T12:00:00.000Z',
    updatedAt: '2026-07-05T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function validIncrement(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-0000000000e2',
    userId: 'user-1',
    taskId: '10000000-0000-0000-0000-000000000001',
    kind: 'increment',
    delta: 3,
    occurredAt: '2026-07-05T12:00:00.000Z',
    createdAt: '2026-07-05T12:00:00.000Z',
    updatedAt: '2026-07-05T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// The completion fixture uses a non-UUID taskId placeholder in one field; fix it
// to a real UUID so only the field under test can fail.
function completion(overrides: Record<string, unknown> = {}) {
  return validCompletion({ taskId: '10000000-0000-0000-0000-000000000001', ...overrides });
}

describe('TaskEventSchema', () => {
  it('accepts a well-formed completion event (no delta)', () => {
    expect(TaskEventSchema.safeParse(completion()).success).toBe(true);
  });

  it('accepts a well-formed increment event with a positive delta', () => {
    expect(TaskEventSchema.safeParse(validIncrement()).success).toBe(true);
  });

  it('accepts an increment event with a negative delta (decrement)', () => {
    expect(TaskEventSchema.safeParse(validIncrement({ delta: -2 })).success).toBe(true);
  });

  it('rejects a completion event that carries a delta', () => {
    expect(TaskEventSchema.safeParse(completion({ delta: 1 })).success).toBe(false);
  });

  it('rejects an increment event with no delta', () => {
    const base = validIncrement();
    delete (base as Record<string, unknown>).delta;
    expect(TaskEventSchema.safeParse(base).success).toBe(false);
  });

  it('rejects an increment event with delta = 0', () => {
    expect(TaskEventSchema.safeParse(validIncrement({ delta: 0 })).success).toBe(false);
  });

  it('rejects an increment event with a non-integer delta', () => {
    expect(TaskEventSchema.safeParse(validIncrement({ delta: 1.5 })).success).toBe(false);
  });

  it('rejects an unknown kind', () => {
    expect(TaskEventSchema.safeParse(completion({ kind: 'toggle' })).success).toBe(false);
  });

  it('rejects a missing occurredAt', () => {
    const base = completion();
    delete (base as Record<string, unknown>).occurredAt;
    expect(TaskEventSchema.safeParse(base).success).toBe(false);
  });

  it('rejects a non-UUID id', () => {
    expect(TaskEventSchema.safeParse(completion({ id: 'not-a-uuid' })).success).toBe(false);
  });

  it('rejects a non-UUID taskId', () => {
    expect(TaskEventSchema.safeParse(completion({ taskId: 'nope' })).success).toBe(false);
  });

  it('rejects version = 0', () => {
    expect(TaskEventSchema.safeParse(completion({ version: 0 })).success).toBe(false);
  });

  it('accepts an optional boardId (UUID) and rejects a non-UUID boardId', () => {
    expect(
      TaskEventSchema.safeParse(completion({ boardId: '20000000-0000-0000-0000-000000000002' }))
        .success,
    ).toBe(true);
    expect(TaskEventSchema.safeParse(completion({ boardId: 'nope' })).success).toBe(false);
  });

  it('accepts a soft-deleted (tombstoned) event with deletedAt', () => {
    expect(
      TaskEventSchema.safeParse(
        completion({ isDeleted: true, deletedAt: '2026-07-06T00:00:00.000Z' }),
      ).success,
    ).toBe(true);
  });
});
