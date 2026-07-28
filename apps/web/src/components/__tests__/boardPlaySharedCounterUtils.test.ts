import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import {
  resolveSharedCounterDefaultAmount,
  resolveSharedCounterSourceId,
  resolveCreditedCounterName,
} from '../boardPlaySharedCounterUtils';

function makeTask(over: Partial<Task> & Pick<Task, 'id'>): Task {
  return {
    userId: 'u1',
    title: '',
    type: TaskType.COUNTING,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...over,
  };
}

describe('resolveSharedCounterSourceId', () => {
  it('resolves a LINKED task to its sharedCounterId', () => {
    const linked = makeTask({ id: 'lnk', sharedCounterId: 'src' });
    expect(resolveSharedCounterSourceId(linked, new Set())).toBe('src');
  });

  it('resolves a SOURCE task (member of sharedCounterSourceIds) to its own id', () => {
    const source = makeTask({ id: 'src' });
    expect(resolveSharedCounterSourceId(source, new Set(['src']))).toBe('src');
  });

  it('returns null for a standalone (unlinked, non-source) task', () => {
    const solo = makeTask({ id: 'solo' });
    expect(resolveSharedCounterSourceId(solo, new Set())).toBeNull();
  });

  it('prefers sharedCounterId over source-set membership when (defensively) both are set', () => {
    const weird = makeTask({ id: 'weird', sharedCounterId: 'other-src' });
    expect(resolveSharedCounterSourceId(weird, new Set(['weird']))).toBe('other-src');
  });
});

describe('resolveSharedCounterDefaultAmount', () => {
  it('returns the source task defaultLogAmount when set', () => {
    const source = makeTask({ id: 'src', defaultLogAmount: 25 });
    expect(resolveSharedCounterDefaultAmount(source)).toBe(25);
  });

  it('falls back to 1 when defaultLogAmount is unset', () => {
    const source = makeTask({ id: 'src' });
    expect(resolveSharedCounterDefaultAmount(source)).toBe(1);
  });

  it('falls back to 1 when the source task is undefined', () => {
    expect(resolveSharedCounterDefaultAmount(undefined)).toBe(1);
  });
});

describe('resolveCreditedCounterName', () => {
  it('prefers the pair-derived name over a stored title when both are present', () => {
    const source = makeTask({ id: 'src', title: 'My push-up counter', action: 'Do', unit: 'push-ups' });
    expect(resolveCreditedCounterName(source)).toBe('Push-ups');
  });

  it('uses the verb + noun form for a non-"Do" action', () => {
    const source = makeTask({ id: 'src', title: 'ignored', action: 'Run', unit: 'miles' });
    expect(resolveCreditedCounterName(source)).toBe('Run miles');
  });

  it('falls back to the stored title when the pair is empty', () => {
    const source = makeTask({ id: 'src', title: 'Push-ups' });
    expect(resolveCreditedCounterName(source)).toBe('Push-ups');
  });

  it('returns an empty string when both the pair and the title are empty', () => {
    const source = makeTask({ id: 'src', title: '' });
    expect(resolveCreditedCounterName(source)).toBe('');
  });

  it('returns an empty string when the source task is undefined', () => {
    expect(resolveCreditedCounterName(undefined)).toBe('');
  });
});
