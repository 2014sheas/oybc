import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { isSquarePickerCandidate } from '../squarePickerCandidates';

/**
 * Loose-ends sweep (2026-09-09), moved to `squarePickerCandidates.ts` in
 * Board Edit redesign slice 3 (D13) — the add/replace picker's candidate
 * rule: never offer a task already in the DRAFT, nor a shared-counter
 * family-mate of one (the one-counter-per-board rule), except that the
 * outgoing square's own slot is replaceable — replacing "Read 20" →
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

describe('isSquarePickerCandidate', () => {
  it('excludes a task already in the draft (add mode)', () => {
    expect(isSquarePickerCandidate(task('a'), { placedTaskIds: new Set(['a']) })).toBe(false);
    expect(isSquarePickerCandidate(task('b'), { placedTaskIds: new Set(['a']) })).toBe(true);
  });

  it('excludes a family-mate of a drafted counter (add mode)', () => {
    const args = { placedTaskIds: new Set(['r20']), counterFamilyByTaskId: FAM };
    expect(isSquarePickerCandidate(task('r50', { type: TaskType.COUNTING }), args)).toBe(false);
  });

  it('replace mode: the outgoing square frees its own family slot', () => {
    const args = {
      currentTaskId: 'r20',
      placedTaskIds: new Set(['r20', 'a']),
      counterFamilyByTaskId: FAM,
    };
    // Replacing r20 with its family-mate r50 is legitimate…
    expect(isSquarePickerCandidate(task('r50', { type: TaskType.COUNTING }), args)).toBe(true);
    // …but never with itself, and never with another drafted task.
    expect(isSquarePickerCandidate(task('r20', { type: TaskType.COUNTING }), args)).toBe(false);
    expect(isSquarePickerCandidate(task('a'), args)).toBe(false);
  });

  it('replace mode: a family drafted elsewhere on the board still blocks', () => {
    const args = {
      currentTaskId: 'a',
      placedTaskIds: new Set(['a', 'r20']),
      counterFamilyByTaskId: FAM,
    };
    expect(isSquarePickerCandidate(task('r50', { type: TaskType.COUNTING }), args)).toBe(false);
  });

  it('legacy call sites without placement data behave as before', () => {
    expect(isSquarePickerCandidate(task('a'), { currentTaskId: 'a' })).toBe(false);
    expect(isSquarePickerCandidate(task('b'), { currentTaskId: 'a' })).toBe(true);
  });
});
