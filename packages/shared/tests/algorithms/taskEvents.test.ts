import * as fs from 'fs';
import * as path from 'path';
import {
  resolveTaskWindowState,
  isEventOwningTask,
  backstopWindowMs,
  computeBackstopDeadlineMs,
  BACKSTOP_MAX_MS,
} from '../../src/algorithms/taskEvents';
import type { Task, TaskEvent, TaskEventKind } from '../../src/types';
import { TaskType } from '../../src/constants/enums';

/**
 * taskEvents.test.ts — Windowed Completion PR A pure evaluators
 * (docs/WINDOWED_COMPLETION.md §Semantics per task type + §Sealing).
 *
 * `resolveTaskWindowState` is fixture-driven from
 * `tests/fixtures/taskWindowStateVectors.json` — the SAME file the deferred
 * iOS `TaskWindowStateVectorTests.swift` (PR B) will run through the Swift
 * mirror. `isEventOwningTask` + the backstop helpers are hand-tested here.
 */

const H = 60 * 60 * 1000;

function makeTask(overrides: Partial<Task>): Task {
  return {
    id: '00000000-0000-0000-0000-000000000000',
    userId: 'user-1',
    title: 'T',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-07-01T00:00:00.000Z',
    updatedAt: '2026-07-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makeEvent(overrides: Partial<TaskEvent>): TaskEvent {
  return {
    id: '00000000-0000-0000-0000-0000000000ee',
    userId: 'user-1',
    taskId: '00000000-0000-0000-0000-000000000000',
    kind: 'completion',
    occurredAt: '2026-07-01T00:00:00.000Z',
    createdAt: '2026-07-01T00:00:00.000Z',
    updatedAt: '2026-07-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// ─── resolveTaskWindowState (fixture-driven) ────────────────────────────────

interface VectorEvent {
  kind: TaskEventKind;
  delta: number | null;
  occurredAt: string;
  isDeleted: boolean;
}
interface Vector {
  name: string;
  task: { type: string; maxCount: number | null };
  windowStart: string | null;
  events: VectorEvent[];
  expected: { isCompleted: boolean; count: number };
}
const fixture: { vectors: Vector[] } = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/taskWindowStateVectors.json'), 'utf8'),
);

describe('resolveTaskWindowState (fixture-driven, tests/fixtures/taskWindowStateVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const task = makeTask({
        type: v.task.type as TaskType,
        maxCount: v.task.maxCount ?? undefined,
      });
      const events = v.events.map((e) =>
        makeEvent({
          kind: e.kind,
          delta: e.delta ?? undefined,
          occurredAt: e.occurredAt,
          isDeleted: e.isDeleted,
        }),
      );
      const result = resolveTaskWindowState(task, events, v.windowStart);
      expect(result).toEqual(v.expected);
    });
  }

  it('a caller passing already-non-deleted events resolves identically (defensive isDeleted filter)', () => {
    const task = makeTask({ type: TaskType.NORMAL });
    const live = [makeEvent({ kind: 'completion', occurredAt: '2026-07-05T00:00:00.000Z' })];
    expect(resolveTaskWindowState(task, live, '2026-07-01T00:00:00.000Z')).toEqual({
      isCompleted: true,
      count: 1,
    });
  });

  it('counting task with undefined maxCount never completes (defensive)', () => {
    const task = makeTask({ type: TaskType.COUNTING, maxCount: undefined });
    const events = [makeEvent({ kind: 'increment', delta: 100, occurredAt: '2026-07-05T00:00:00.000Z' })];
    const result = resolveTaskWindowState(task, events, '2026-07-01T00:00:00.000Z');
    expect(result.isCompleted).toBe(false);
    expect(result.count).toBe(100);
  });

  it('counting: an increment event missing its delta contributes 0 (defensive ?? 0)', () => {
    const task = makeTask({ type: TaskType.COUNTING, maxCount: 1 });
    const events = [
      makeEvent({ kind: 'increment', delta: undefined, occurredAt: '2026-07-05T00:00:00.000Z' }),
    ];
    const result = resolveTaskWindowState(task, events, '2026-07-01T00:00:00.000Z');
    expect(result).toEqual({ isCompleted: false, count: 0 });
  });

  it('normal: increment events are ignored by the completion branch', () => {
    const task = makeTask({ type: TaskType.NORMAL });
    const events = [
      makeEvent({ kind: 'increment', delta: 5, occurredAt: '2026-07-05T00:00:00.000Z' }),
    ];
    const result = resolveTaskWindowState(task, events, '2026-07-01T00:00:00.000Z');
    expect(result).toEqual({ isCompleted: false, count: 0 });
  });
});

// ─── isEventOwningTask ──────────────────────────────────────────────────────

describe('isEventOwningTask', () => {
  it('NORMAL owns events', () => {
    expect(isEventOwningTask({ type: TaskType.NORMAL, sharedCounterId: null })).toBe(true);
  });

  it('plain COUNTING (no sharedCounterId) owns events', () => {
    expect(isEventOwningTask({ type: TaskType.COUNTING, sharedCounterId: null })).toBe(true);
    expect(isEventOwningTask({ type: TaskType.COUNTING, sharedCounterId: undefined })).toBe(true);
  });

  it('derived COUNTING (sharedCounterId set) does NOT own events', () => {
    expect(
      isEventOwningTask({ type: TaskType.COUNTING, sharedCounterId: 'src-1' }),
    ).toBe(false);
  });

  it('COMPOUND and ACHIEVEMENT do NOT own events', () => {
    expect(isEventOwningTask({ type: TaskType.COMPOUND, sharedCounterId: null })).toBe(false);
    expect(isEventOwningTask({ type: TaskType.ACHIEVEMENT, sharedCounterId: null })).toBe(false);
  });
});

// ─── backstop formula ───────────────────────────────────────────────────────

describe('backstopWindowMs (docs §Sealing — min(48h, windowLength/4))', () => {
  it('daily window (~24h) → ~6h', () => {
    const ms = backstopWindowMs('2026-07-01T00:00:00.000Z', '2026-07-02T00:00:00.000Z');
    expect(ms).toBe(6 * H);
  });

  it('weekly window (7d) → 42h', () => {
    const ms = backstopWindowMs('2026-07-01T00:00:00.000Z', '2026-07-08T00:00:00.000Z');
    expect(ms).toBe(42 * H);
  });

  it('monthly window (31d) → capped at 48h', () => {
    const ms = backstopWindowMs('2026-07-01T00:00:00.000Z', '2026-08-01T00:00:00.000Z');
    expect(ms).toBe(BACKSTOP_MAX_MS);
  });

  it('yearly window → capped at 48h', () => {
    const ms = backstopWindowMs('2026-01-01T00:00:00.000Z', '2027-01-01T00:00:00.000Z');
    expect(ms).toBe(BACKSTOP_MAX_MS);
  });

  it('custom window of exactly 8 days → 48h (boundary of the cap)', () => {
    const ms = backstopWindowMs('2026-07-01T00:00:00.000Z', '2026-07-09T00:00:00.000Z');
    expect(ms).toBe(48 * H);
  });

  it('custom window of 4 days → 24h (below the cap, scales)', () => {
    const ms = backstopWindowMs('2026-07-01T00:00:00.000Z', '2026-07-05T00:00:00.000Z');
    expect(ms).toBe(24 * H);
  });

  it('malformed window (endDate <= startDate) floors at 0', () => {
    const ms = backstopWindowMs('2026-07-02T00:00:00.000Z', '2026-07-01T00:00:00.000Z');
    expect(ms).toBe(0);
  });
});

describe('computeBackstopDeadlineMs (docs §Sealing — keyed off max(endDate, activatedAt))', () => {
  it('returns null for an indefinite board (no endDate)', () => {
    expect(computeBackstopDeadlineMs('2026-07-01T00:00:00.000Z', null)).toBeNull();
    expect(computeBackstopDeadlineMs('2026-07-01T00:00:00.000Z', undefined)).toBeNull();
  });

  it('daily board with no activatedAt keys off endDate + 6h', () => {
    const start = '2026-07-01T00:00:00.000Z';
    const end = '2026-07-02T00:00:00.000Z';
    const deadline = computeBackstopDeadlineMs(start, end);
    expect(deadline).toBe(new Date(end).getTime() + 6 * H);
  });

  it('draft activated AFTER its window expired keys off activatedAt (one full prompt cycle)', () => {
    const start = '2026-07-01T00:00:00.000Z';
    const end = '2026-07-02T00:00:00.000Z';
    const activatedAt = '2026-07-05T00:00:00.000Z'; // well past endDate
    const deadline = computeBackstopDeadlineMs(start, end, activatedAt);
    expect(deadline).toBe(new Date(activatedAt).getTime() + 6 * H);
  });

  it('activatedAt before endDate is ignored (endDate wins the max)', () => {
    const start = '2026-07-01T00:00:00.000Z';
    const end = '2026-07-02T00:00:00.000Z';
    const activatedAt = '2026-07-01T06:00:00.000Z'; // before endDate
    const deadline = computeBackstopDeadlineMs(start, end, activatedAt);
    expect(deadline).toBe(new Date(end).getTime() + 6 * H);
  });
});
