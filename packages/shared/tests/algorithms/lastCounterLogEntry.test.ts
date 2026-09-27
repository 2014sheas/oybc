import * as fs from 'fs';
import * as path from 'path';
import {
  selectLastIncrementEntry,
  selectClosedBoardLateLogs,
  type ClosedBoardLateLogBoard,
} from '../../src/algorithms/lastCounterLogEntry';
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

  it('late log: picks the most recently WRITTEN entry (max createdAt) even when its occurredAt is older', () => {
    // A late log on an ended board is stamped at that board's endDate (in the
    // past), so it has the OLDER occurredAt but was the entry the user made last.
    const events = [
      ev({ id: 'today-log', occurredAt: '2026-07-20T09:00:00.000', createdAt: '2026-07-20T09:00:00.000' }),
      ev({ id: 'late-log', occurredAt: '2026-07-19T23:59:59.999', createdAt: '2026-07-20T10:00:00.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('late-log');
  });

  it('tie-breaks equal createdAt by max occurredAt', () => {
    const events = [
      ev({ id: 'earlier-occurred', occurredAt: '2026-07-19T09:00:00.000', createdAt: '2026-07-20T09:00:00.000' }),
      ev({ id: 'later-occurred', occurredAt: '2026-07-20T08:00:00.000', createdAt: '2026-07-20T09:00:00.000' }),
    ];
    expect(selectLastIncrementEntry(events, SOURCE)?.id).toBe('later-occurred');
  });

  it('equal occurredAt: picks the max createdAt', () => {
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

// ── Closed-board late logs (Board Edit redesign slice 4, D10 / R2) ──────────
//
// sealReDerivationVectors.json#closedBoardLateLogs — the SAME vectors iOS runs
// in apps/ios/OYBCTests/SealImmunityVectorTests.swift.

interface ClosedBoardLateLogVector {
  name: string;
  board: ClosedBoardLateLogBoard;
  taskId: string;
  events: TaskEvent[];
  expectedIds: string[];
}

const closedBoardLateLogVectors = (
  JSON.parse(
    fs.readFileSync(path.join(__dirname, '../fixtures/sealReDerivationVectors.json'), 'utf8'),
  ) as { closedBoardLateLogs: ClosedBoardLateLogVector[] }
).closedBoardLateLogs;

describe('selectClosedBoardLateLogs (sealReDerivationVectors.json#closedBoardLateLogs)', () => {
  it('fixture section is present and non-trivial', () => {
    expect(closedBoardLateLogVectors.length).toBeGreaterThanOrEqual(5);
  });

  for (const v of closedBoardLateLogVectors) {
    it(v.name, () => {
      const picked = selectClosedBoardLateLogs(v.events, v.board, v.taskId);
      expect(picked.map((e) => e.id)).toEqual(v.expectedIds);
    });
  }

  it('matches a UTC late-log stamp against a local-ISO endDate by instant', () => {
    const endDate = '2026-09-15T23:59:59.999';
    const board = { id: 'board-1', endDate, sealedAt: '2026-09-17T00:00:00.000Z' };
    const late = ev({
      id: 'late',
      boardId: 'board-1',
      occurredAt: new Date(endDate).toISOString(),
      createdAt: '2026-09-18T10:00:00.000Z',
    });
    expect(selectClosedBoardLateLogs([late], board, SOURCE).map((e) => e.id)).toEqual(['late']);
  });

  it('an unparseable endDate or sealedAt yields no late logs', () => {
    const late = ev({
      id: 'late',
      boardId: 'board-1',
      occurredAt: '2026-09-15T23:59:59.999Z',
      createdAt: '2026-09-18T10:00:00.000Z',
    });
    expect(
      selectClosedBoardLateLogs([late], { id: 'board-1', endDate: 'x', sealedAt: '2026-09-17T00:00:00.000Z' }, SOURCE),
    ).toEqual([]);
    expect(
      selectClosedBoardLateLogs([late], { id: 'board-1', endDate: '2026-09-15T23:59:59.999Z', sealedAt: 'x' }, SOURCE),
    ).toEqual([]);
  });

  it('does not mutate the input array', () => {
    const events = [
      ev({ id: 'a', boardId: 'b', occurredAt: '2026-09-15T23:59:59.999Z', createdAt: '2026-09-18T10:00:00.000Z' }),
      ev({ id: 'z', boardId: 'b', occurredAt: '2026-09-15T23:59:59.999Z', createdAt: '2026-09-19T10:00:00.000Z' }),
    ];
    const board = { id: 'b', endDate: '2026-09-15T23:59:59.999Z', sealedAt: '2026-09-17T00:00:00.000Z' };
    expect(selectClosedBoardLateLogs(events, board, SOURCE).map((e) => e.id)).toEqual(['z', 'a']);
    expect(events.map((e) => e.id)).toEqual(['a', 'z']);
  });
});
