import { describe, expect, it } from 'vitest';
import { TaskType, Timeframe, type Task } from '@oybc/shared';
import { visibleCounterTasks } from '../useSharedCounterGroups';

/**
 * §Member rules (B3, RC9) — which tasks the Counters surfaces group.
 *
 * A per-window DERIVED counter carries its board window's `endDate`, so a
 * counter that has ridden a few daily boards accumulates members that are
 * over. The hub hides them by default (the Tasks tab's own rule, via the
 * same `isTaskExpired` predicate) and the "Show expired tasks" toggle
 * brings them back.
 *
 * The one rule that is NOT the Tasks tab's: a ROOT is never hidden.
 * `buildSharedCounterGroups` is vector-pinned and unchanged — filtering
 * happens before it.
 */

const NOW = new Date('2026-09-18T12:00:00.000Z');
const CREATED = '2026-01-01T00:00:00.000Z';

function makeTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.COUNTING,
    maxCount: 10,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: CREATED,
    updatedAt: CREATED,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

/** A window-stamped derived member of `root`, whose window has closed. */
function expiredMember(id: string, root: string): Task {
  return makeTask(id, {
    sharedCounterId: root,
    createdInWizard: true,
    timeframe: Timeframe.DAILY,
    startDate: '2026-09-10T00:00:00.000',
    endDate: '2026-09-10T23:59:59.999',
  });
}

/** A derived member whose window is still open. */
function liveMember(id: string, root: string): Task {
  return makeTask(id, {
    sharedCounterId: root,
    createdInWizard: true,
    timeframe: Timeframe.DAILY,
    startDate: '2026-09-18T00:00:00.000',
    endDate: '2026-09-18T23:59:59.999',
  });
}

describe('visibleCounterTasks — the Counters hub expired filter (B3 RC9)', () => {
  it('hides an expired member by default and keeps it with the flag', () => {
    const root = makeTask('root-1');
    const live = liveMember('m-live', 'root-1');
    const stale = expiredMember('m-stale', 'root-1');
    const tasks = [root, live, stale];

    expect(visibleCounterTasks(tasks, false, NOW).map((t) => t.id)).toEqual([
      'root-1',
      'm-live',
    ]);
    expect(visibleCounterTasks(tasks, true, NOW)).toBe(tasks);
    expect(visibleCounterTasks(tasks, true, NOW).map((t) => t.id)).toEqual([
      'root-1',
      'm-live',
      'm-stale',
    ]);
  });

  it('NEVER hides a root, even one whose own endDate is in the past', () => {
    // A timeboxed counter the user made themselves: expired by the Tasks
    // tab's rule, but it IS the counter — hiding it would delete the whole
    // group from the hub instead of tidying one row out of it.
    const root = makeTask('root-2', {
      timeframe: Timeframe.MONTHLY,
      startDate: '2026-07-01T00:00:00.000',
      endDate: '2026-07-31T23:59:59.999',
    });
    const stale = expiredMember('m-stale', 'root-2');

    expect(visibleCounterTasks([root, stale], false, NOW).map((t) => t.id)).toEqual([
      'root-2',
    ]);
  });

  it('keeps members with no endDate at all', () => {
    const root = makeTask('root-3');
    const openEnded = makeTask('m-open', { sharedCounterId: 'root-3' });

    expect(visibleCounterTasks([root, openEnded], false, NOW).map((t) => t.id)).toEqual([
      'root-3',
      'm-open',
    ]);
  });
});
