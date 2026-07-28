import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { resolveDeriveLinkTarget } from './deriveCounterLink';

const NOW = '2026-07-18T10:00:00.000Z';

function counterTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'src1',
    userId: 'u1',
    title: 'Do 200 push-ups',
    type: TaskType.COUNTING,
    action: 'Do',
    unit: 'push-ups',
    maxCount: 200,
    currentCount: 120,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as unknown as Task;
}

describe('resolveDeriveLinkTarget — R1 counters refresh "Derive smaller version" link', () => {
  it('links straight to the source when the source is a plain (non-derived) counter', () => {
    const source = counterTask({ id: 'src1', currentCount: 120 });
    const result = resolveDeriveLinkTarget(source);
    expect(result).toEqual({ sharedCounterId: 'src1', baseline: 120 });
  });

  it('ignores a stale/irrelevant rootTask argument when the source is not itself derived', () => {
    const source = counterTask({ id: 'src1', currentCount: 120 });
    // A caller might pass a lookup result even when it isn't needed; the
    // source's own currentCount must still win (never the passed rootTask).
    const irrelevantRoot = counterTask({ id: 'other', currentCount: 9999 });
    const result = resolveDeriveLinkTarget(source, irrelevantRoot);
    expect(result).toEqual({ sharedCounterId: 'src1', baseline: 120 });
  });

  it('links to the ROOT counter (not the derived task itself) when the source is itself a linked/derived task', () => {
    // `source` is a derived task pointing at 'root1' — its own currentCount
    // (30) is its LOCAL window, not the lifetime total.
    const source = counterTask({
      id: 'derived1',
      sharedCounterId: 'root1',
      baseline: 50,
      currentCount: 30,
    });
    const rootTask = counterTask({ id: 'root1', currentCount: 500, sharedCounterId: undefined });
    const result = resolveDeriveLinkTarget(source, rootTask);
    // Links to the ROOT id, and baselines off the ROOT's lifetime count —
    // never the derived source's own local currentCount (30).
    expect(result).toEqual({ sharedCounterId: 'root1', baseline: 500 });
  });

  it('falls back to the source itself when the root task could not be resolved (best-effort)', () => {
    const source = counterTask({
      id: 'derived1',
      sharedCounterId: 'root1',
      baseline: 50,
      currentCount: 30,
    });
    const result = resolveDeriveLinkTarget(source, undefined);
    expect(result).toEqual({ sharedCounterId: 'root1', baseline: 30 });
  });

  it('treats a missing/undefined currentCount as 0 (fresh counter, never logged)', () => {
    const source = counterTask({ id: 'src1', currentCount: undefined });
    const result = resolveDeriveLinkTarget(source);
    expect(result).toEqual({ sharedCounterId: 'src1', baseline: 0 });
  });
});
