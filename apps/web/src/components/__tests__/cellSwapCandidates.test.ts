import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { isSwapCandidate } from '../CellSwapModal';

/**
 * Loose-ends sweep (2026-09-09) — the add/swap picker's candidate rule:
 * never offer a task the board already carries, nor a shared-counter
 * family-mate of one (the one-counter-per-board rule), except that the
 * outgoing square's own slot is replaceable — swapping "Read 20" →
 * "Read 50" is legitimate.
 */

const NOW = '2026-09-09T00:00:00.000Z';

function task(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u',
    title: id,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

const FAM = { r20: 'root', r50: 'root' };

describe('isSwapCandidate', () => {
  it('excludes a task already placed on the board (add mode)', () => {
    expect(isSwapCandidate(task('a'), { placedTaskIds: new Set(['a']) })).toBe(false);
    expect(isSwapCandidate(task('b'), { placedTaskIds: new Set(['a']) })).toBe(true);
  });

  it('excludes a family-mate of a placed counter (add mode)', () => {
    const args = { placedTaskIds: new Set(['r20']), counterFamilyByTaskId: FAM };
    expect(isSwapCandidate(task('r50', { type: TaskType.COUNTING }), args)).toBe(false);
  });

  it('swap mode: the outgoing square frees its own family slot', () => {
    const args = {
      currentTaskId: 'r20',
      placedTaskIds: new Set(['r20', 'a']),
      counterFamilyByTaskId: FAM,
    };
    // Replacing r20 with its family-mate r50 is legitimate…
    expect(isSwapCandidate(task('r50', { type: TaskType.COUNTING }), args)).toBe(true);
    // …but never with itself, and never with another placed task.
    expect(isSwapCandidate(task('r20', { type: TaskType.COUNTING }), args)).toBe(false);
    expect(isSwapCandidate(task('a'), args)).toBe(false);
  });

  it('swap mode: a family placed elsewhere on the board still blocks', () => {
    const args = {
      currentTaskId: 'a',
      placedTaskIds: new Set(['a', 'r20']),
      counterFamilyByTaskId: FAM,
    };
    expect(isSwapCandidate(task('r50', { type: TaskType.COUNTING }), args)).toBe(false);
  });

  it('legacy call sites without placement data behave as before', () => {
    expect(isSwapCandidate(task('a'), { currentTaskId: 'a' })).toBe(false);
    expect(isSwapCandidate(task('b'), { currentTaskId: 'a' })).toBe(true);
  });
});
