import { selectLastIncrementEntry } from '../../src/algorithms/lastCounterLogEntry';
import { SEED_EVENT_OCCURRED_AT } from '../../src/algorithms/taskEvents';
import type { TaskEvent } from '../../src/types/taskEvent';

const SOURCE = 'source-task-1';

function ev(overrides: Partial<TaskEvent> & { id: string }): TaskEvent {
  return {
    userId: 'u1',
    taskId: SOURCE,
    kind: 'increment',
    delta: 1,
    occurredAt: '2026-07-20T09:00:00.000',
    createdAt: '2026-07-20T09:00:00.000',
    updatedAt: '2026-07-20T09:00:00.000',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('selectLastIncrementEntry', () => {
  it('returns null when there are no events', () => {
    expect(selectLastIncrementEntry([], SOURCE)).toBeNull();
  });

  it('returns null when the only event is the seed sentinel', () => {
    const events = [ev({ id: 'seed', occurredAt: SEED_EVENT_OCCURRED_AT })];
    expect(selectLastIncrementEntry(events, SOURCE)).toBeNull();
  });

  it('picks the single qualifying event', () => {
    const events = [ev({ id: 'e1' })];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('e1');
  });

  it('picks the event with the max occurredAt', () => {
    const events = [
      ev({ id: 'older', occurredAt: '2026-07-18T09:00:00.000' }),
      ev({ id: 'newer', occurredAt: '2026-07-20T09:00:00.000' }),
      ev({ id: 'middle', occurredAt: '2026-07-19T09:00:00.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('newer');
  });

  it('tie-breaks equal occurredAt by max createdAt', () => {
    const events = [
      ev({ id: 'first-written', occurredAt: '2026-07-20T09:00:00.000', createdAt: '2026-07-20T09:00:00.000' }),
      ev({ id: 'second-written', occurredAt: '2026-07-20T09:00:00.000', createdAt: '2026-07-20T09:00:05.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('second-written');
  });

  it('skips soft-deleted events', () => {
    const events = [
      ev({ id: 'deleted', occurredAt: '2026-07-20T12:00:00.000', isDeleted: true }),
      ev({ id: 'live', occurredAt: '2026-07-19T09:00:00.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('live');
  });

  it('skips the seed sentinel even when it is the most recent by occurredAt value', () => {
    const events = [
      ev({ id: 'seed', occurredAt: SEED_EVENT_OCCURRED_AT }),
      ev({ id: 'real', occurredAt: '2026-07-10T09:00:00.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('real');
  });

  it('skips completion-kind events', () => {
    const events = [ev({ id: 'completion', kind: 'completion', delta: undefined })];
    expect(selectLastIncrementEntry(events, SOURCE)).toBeNull();
  });

  it('skips events for a different task', () => {
    const events = [ev({ id: 'other', taskId: 'other-task' })];
    expect(selectLastIncrementEntry(events, SOURCE)).toBeNull();
  });

  it('ignores events from other tasks even when interleaved with the source task', () => {
    const events = [
      ev({ id: 'other-newer', taskId: 'other-task', occurredAt: '2026-07-21T09:00:00.000' }),
      ev({ id: 'source-entry', occurredAt: '2026-07-19T09:00:00.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('source-entry');
  });
});
