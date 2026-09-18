import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { computeStatusLabel, displayedCountFor } from '../taskCountDisplay';
import { isInProgress } from '../useTasksFilters';
import type { TaskLibrary } from '../../createPage/useTaskLibrary';

/**
 * Board Sources §Member rules B2 (web) — RB7, the linked-count read audit.
 *
 * A linked counting task stores its ROOT's lifetime total in `currentCount`
 * (the propagation mirror) and its window's starting value in `baseline`.
 * Every library surface that printed `currentCount` raw was therefore
 * printing the root's lifetime number on a per-window row: a member of a
 * root at 12 with a baseline of 10 shows `2 / 5`, never `12`. The board
 * surfaces already derived it (`db/adapters.ts`); these are the four reads
 * that did not.
 */

const NOW = '2026-09-18T10:00:00.000Z';

function task(over: Partial<Task> = {}): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Run 5 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 5,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

/** The root at 12, a window that opened at 10, a personal goal of 5. */
const LINKED = task({ sharedCounterId: 'root-1', baseline: 10, maxCount: 5, currentCount: 12 });
/** A root/standalone counter: `currentCount` IS its own value. */
const ROOT = task({ currentCount: 12, maxCount: 20 });

const EMPTY_LIBRARY = {
  taskMap: {},
  compoundChildrenByCompound: {},
} as unknown as TaskLibrary;

describe('displayedCountFor', () => {
  it('baseline-adjusts a linked task (the root total is not the member’s count)', () => {
    expect(displayedCountFor(LINKED)).toBe(2);
  });

  it('returns the raw count for a root / standalone counter', () => {
    expect(displayedCountFor(ROOT)).toBe(12);
  });

  it('clamps below the baseline to 0 and never clamps overshoot', () => {
    expect(displayedCountFor(task({ sharedCounterId: 'r', baseline: 20, currentCount: 5 }))).toBe(0);
    expect(
      displayedCountFor(task({ sharedCounterId: 'r', baseline: 0, maxCount: 5, currentCount: 9 })),
    ).toBe(9);
  });
});

describe('computeStatusLabel', () => {
  it('shows the member’s windowed progress, not the root’s lifetime total', () => {
    expect(computeStatusLabel(LINKED)).toBe('2 / 5');
  });

  it('leaves a root counter’s label unchanged', () => {
    expect(computeStatusLabel(ROOT)).toBe('12 / 20');
  });

  it('shows no progress label for a linked member still at its baseline', () => {
    expect(
      computeStatusLabel(task({ sharedCounterId: 'r', baseline: 12, maxCount: 5, currentCount: 12 })),
    ).toBe('');
  });

  it('completion still wins over any count', () => {
    expect(computeStatusLabel(task({ ...LINKED, isCompleted: true }))).toBe('Completed');
  });
});

describe('isInProgress (status filter)', () => {
  it('treats a linked member above its baseline as in progress', () => {
    expect(isInProgress(LINKED, EMPTY_LIBRARY)).toBe(true);
  });

  it('does NOT treat a linked member at its baseline as in progress (the root’s history is not its progress)', () => {
    const untouched = task({ sharedCounterId: 'r', baseline: 12, maxCount: 5, currentCount: 12 });
    expect(isInProgress(untouched, EMPTY_LIBRARY)).toBe(false);
  });

  it('is unchanged for a root counter', () => {
    expect(isInProgress(ROOT, EMPTY_LIBRARY)).toBe(true);
  });
});
