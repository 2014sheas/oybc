/**
 * linkableCounter.test.ts — "add a new task to an existing counter" match.
 *
 * Matches a new counting task's action+unit to an existing counter (source /
 * standalone), preferring the most-established one. iOS `LinkableCounter.swift`
 * port mirrors these.
 */

import { findLinkableCounter } from '../../src/algorithms/linkableCounter';
import { TaskType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';

interface Opts {
  action?: string;
  unit?: string;
  currentCount?: number;
  sharedCounterId?: string | null;
  isDeleted?: boolean;
  type?: TaskType;
}

function task(id: string, o: Opts = {}): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: o.type ?? TaskType.COUNTING,
    action: o.action,
    unit: o.unit,
    maxCount: 30,
    currentCount: o.currentCount,
    sharedCounterId: o.sharedCounterId ?? null,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-07-01T12:00:00.000Z',
    updatedAt: '2026-07-01T12:00:00.000Z',
    version: 1,
    isDeleted: o.isDeleted ?? false,
  };
}

describe('findLinkableCounter', () => {
  it('returns null when action or unit is blank', () => {
    const tasks = [task('a', { action: 'Push-ups', unit: 'reps' })];
    expect(findLinkableCounter({ action: '', unit: 'reps' }, tasks)).toBeNull();
    expect(findLinkableCounter({ action: 'Push-ups', unit: '' }, tasks)).toBeNull();
  });

  it('returns null when nothing matches', () => {
    const tasks = [task('a', { action: 'Push-ups', unit: 'reps' })];
    expect(findLinkableCounter({ action: 'Sit-ups', unit: 'reps' }, tasks)).toBeNull();
  });

  it('matches a standalone counting task by action+unit (case/space-insensitive)', () => {
    const tasks = [task('src', { action: 'Push-ups', unit: 'reps', currentCount: 512 })];
    const r = findLinkableCounter({ action: '  push-UPS ', unit: 'REPS' }, tasks);
    expect(r).not.toBeNull();
    expect(r!.counterId).toBe('src');
    expect(r!.name).toBe('Push-ups');
    expect(r!.lifetime).toBe(512);
    expect(r!.memberCount).toBe(1);
  });

  it('does NOT match on unit alone — different action is a different counter', () => {
    const tasks = [task('pu', { action: 'Push-ups', unit: 'reps' })];
    expect(findLinkableCounter({ action: 'Sit-ups', unit: 'reps' }, tasks)).toBeNull();
  });

  it('links to the source (not a derived task) and counts members', () => {
    const src = task('src', { action: 'Push-ups', unit: 'reps', currentCount: 100 });
    const d1 = task('d1', { action: 'Push-ups', unit: 'reps', sharedCounterId: 'src' });
    const d2 = task('d2', { action: 'Push-ups', unit: 'reps', sharedCounterId: 'src' });
    const r = findLinkableCounter({ action: 'Push-ups', unit: 'reps' }, [src, d1, d2]);
    expect(r!.counterId).toBe('src'); // never a derived task
    expect(r!.memberCount).toBe(3); // source + 2 linkers
  });

  it('prefers the most-established counter when several match', () => {
    // standalone (0 linkers) vs an established source (2 linkers)
    const solo = task('solo', { action: 'Run', unit: 'km', currentCount: 999 });
    const src = task('src', { action: 'Run', unit: 'km', currentCount: 10 });
    const d1 = task('d1', { action: 'Run', unit: 'km', sharedCounterId: 'src' });
    const d2 = task('d2', { action: 'Run', unit: 'km', sharedCounterId: 'src' });
    const r = findLinkableCounter({ action: 'Run', unit: 'km' }, [solo, src, d1, d2]);
    expect(r!.counterId).toBe('src'); // 3 members beats the higher-count solo
  });

  it('excludes the task being edited', () => {
    const self = task('self', { action: 'Push-ups', unit: 'reps' });
    expect(
      findLinkableCounter({ action: 'Push-ups', unit: 'reps', excludeTaskId: 'self' }, [self]),
    ).toBeNull();
  });

  it('ignores deleted and non-counting tasks', () => {
    const del = task('del', { action: 'Push-ups', unit: 'reps', isDeleted: true });
    const normal = task('norm', { action: 'Push-ups', unit: 'reps', type: TaskType.NORMAL });
    expect(findLinkableCounter({ action: 'Push-ups', unit: 'reps' }, [del, normal])).toBeNull();
  });
});
