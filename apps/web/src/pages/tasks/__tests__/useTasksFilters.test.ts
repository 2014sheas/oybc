import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { matchesSearch } from '../useTasksFilters';

/**
 * The Tasks-tab search predicate. Twin of iOS
 * `TasksTabViewModelTests.test_matchesSearch_*`.
 *
 * Since the 2026-09-22 ruling a shared-counter family root's row renders the
 * pair-derived label ("Read pages"), not its stored title ("Read 35 pages"),
 * so search has to match BOTH: what the user sees, and what is stored.
 */
function counting(over: Partial<Task> = {}): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Read 35 pages',
    type: TaskType.COUNTING,
    action: 'Read',
    unit: 'pages',
    maxCount: 35,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-09-01T12:00:00.000Z',
    updatedAt: '2026-09-01T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

describe('matchesSearch', () => {
  it('matches the generic counter label a family row actually displays', () => {
    // "Read pages" appears nowhere in the stored title "Read 35 pages" —
    // "pages" does, so use a query that ONLY the derived name satisfies.
    expect(matchesSearch(counting(), 'read pages')).toBe(true);
  });

  it('still matches the stored title, counts and all', () => {
    expect(matchesSearch(counting(), 'read 35')).toBe(true);
  });

  it('matches the description', () => {
    expect(matchesSearch(counting({ description: 'before bed' }), 'before bed')).toBe(true);
  });

  it('does not match an unrelated query', () => {
    expect(matchesSearch(counting(), 'run miles')).toBe(false);
  });

  it('does not consult the derived name for a non-counting task', () => {
    const normal = counting({ type: TaskType.NORMAL, title: 'Stretch' });
    expect(matchesSearch(normal, 'read pages')).toBe(false);
  });

  it('an empty query matches everything', () => {
    expect(matchesSearch(counting(), '')).toBe(true);
  });
});
