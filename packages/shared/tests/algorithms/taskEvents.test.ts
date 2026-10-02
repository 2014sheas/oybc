import * as fs from 'fs';
import * as path from 'path';
import {
  resolveTaskWindowState,
  resolveLinkedCounterDisplay,
  lateLogOccurredAt,
  boardWindowEnd,
  isEventOwningTask,
  SEED_EVENT_OCCURRED_AT,
} from '../../src/algorithms/taskEvents';
import type { Task, TaskEvent, TaskEventKind } from '../../src/types';
import { TaskType } from '../../src/constants/enums';

/**
 * taskEvents.test.ts — Windowed Completion PR A pure evaluators
 * (docs/WINDOWED_COMPLETION.md §Semantics per task type + §Sealing).
 *
 * `resolveTaskWindowState` is fixture-driven from
 * `tests/fixtures/taskWindowStateVectors.json` — the SAME file run by iOS
 * `TaskEventVectorTests.swift` through the Swift mirror. `isEventOwningTask` is hand-tested here.
 */


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
  /** Optional inclusive upper bound (2026-09-24 amendment); absent = none. */
  windowEnd?: string | null;
  events: VectorEvent[];
  expected: { isCompleted: boolean; count: number };
}
interface LateLogVector {
  name: string;
  board: { endDate: string | null; sealedAt: string | null };
  nowIso: string;
  expected: 'now' | 'endDate';
}
interface LinkedDisplayVector {
  name: string;
  task: {
    type: string;
    maxCount: number | null;
    sharedCounterId: string | null;
    startDate: string | null;
    endDate: string | null;
    createdInWizard: boolean | null;
    baseline: number | null;
    currentCount: number | null;
    isCompleted: boolean;
  };
  eventsByTaskId: Record<string, VectorEvent[]> | null;
  sealedAt: string | null;
  /** Optional (owner rule 2026-10-01) — the placing board's window for a
   *  non-window-stamped row; absent or null = no window. */
  window?: { startDate: string; endDate: string | null } | null;
  expected: { displayed: number; isCompleted: boolean };
}
const fixture: {
  vectors: Vector[];
  linkedCounterDisplay: LinkedDisplayVector[];
  lateLogOccurredAt: LateLogVector[];
} = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/taskWindowStateVectors.json'), 'utf8'),
);

// ─── lateLogOccurredAt + boardWindowEnd (fixture-driven) ────────────────────

/** Canonical `Date.prototype.toISOString()` shape (UTC, millisecond precision). */
const CANONICAL_UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

describe('lateLogOccurredAt (fixture-driven, taskWindowStateVectors.json#lateLogOccurredAt)', () => {
  it('fixture group is non-empty and covers both outcomes', () => {
    const outcomes = new Set(fixture.lateLogOccurredAt.map((v) => v.expected));
    expect(outcomes).toEqual(new Set(['now', 'endDate']));
  });

  for (const v of fixture.lateLogOccurredAt) {
    it(v.name, () => {
      const board = { endDate: v.board.endDate ?? undefined, sealedAt: v.board.sealedAt ?? undefined };
      const result = lateLogOccurredAt(board, v.nowIso);
      if (v.expected === 'now') {
        expect(result).toBe(v.nowIso);
      } else {
        // Same INSTANT as the board's endDate, re-encoded as a UTC event
        // timestamp — compared by ms (a local-ISO endDate never string-equals).
        expect(result).toMatch(CANONICAL_UTC_ISO);
        expect(new Date(result).getTime()).toBe(new Date(v.board.endDate as string).getTime());
        expect(result).not.toBe(v.nowIso);
      }
    });
  }
});

describe('boardWindowEnd', () => {
  it('returns the board endDate verbatim', () => {
    expect(boardWindowEnd({ endDate: '2026-09-20T23:59:59.999' })).toBe('2026-09-20T23:59:59.999');
  });
  it('returns null for an indefinite board (no endDate)', () => {
    expect(boardWindowEnd({ endDate: undefined })).toBeNull();
  });
});

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
      const result = resolveTaskWindowState(task, events, v.windowStart, v.windowEnd ?? null);
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

  it('a seed event at SEED_EVENT_OCCURRED_AT counts toward lifetime but never toward any window (P5)', () => {
    const task = makeTask({ type: TaskType.COUNTING, maxCount: 50 });
    const seed = makeEvent({
      kind: 'increment',
      delta: 500,
      occurredAt: SEED_EVENT_OCCURRED_AT,
    });
    const lifetime = resolveTaskWindowState(task, [seed], null);
    expect(lifetime.count).toBe(500);
    const windowed = resolveTaskWindowState(task, [seed], '2026-07-01T00:00:00.000Z');
    expect(windowed.count).toBe(0);
    expect(windowed.isCompleted).toBe(false);
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

// The old `min(48h, len/4)` backstop formula (backstopWindowMs /
// computeBackstopDeadlineMs) was replaced by the next-window auto-close rule
// (Board Edit redesign slice 4, D4) — see sealing.test.ts + the
// autoCloseDeadlineVectors.json fixture.

// ─── resolveLinkedCounterDisplay (fixture-driven) ───────────────────────────

describe('resolveLinkedCounterDisplay (fixture-driven, taskWindowStateVectors.json#linkedCounterDisplay)', () => {
  it('fixture section is present and non-trivial', () => {
    expect(fixture.linkedCounterDisplay.length).toBeGreaterThanOrEqual(8);
  });

  for (const v of fixture.linkedCounterDisplay) {
    it(v.name, () => {
      const task = makeTask({
        type: v.task.type as TaskType,
        maxCount: v.task.maxCount ?? undefined,
        sharedCounterId: v.task.sharedCounterId ?? undefined,
        startDate: v.task.startDate ?? undefined,
        endDate: v.task.endDate ?? undefined,
        createdInWizard: v.task.createdInWizard ?? undefined,
        baseline: v.task.baseline ?? undefined,
        currentCount: v.task.currentCount ?? undefined,
        isCompleted: v.task.isCompleted,
      });
      let eventsByTaskId: Record<string, TaskEvent[]> | null = null;
      if (v.eventsByTaskId) {
        eventsByTaskId = {};
        for (const [taskId, evs] of Object.entries(v.eventsByTaskId)) {
          eventsByTaskId[taskId] = evs.map((e, i) =>
            makeEvent({
              id: `${taskId}-${i}`,
              taskId,
              kind: e.kind,
              delta: e.delta ?? undefined,
              occurredAt: e.occurredAt,
              isDeleted: e.isDeleted,
            }),
          );
        }
      }
      expect(resolveLinkedCounterDisplay(task, eventsByTaskId, v.sealedAt, v.window ?? null)).toEqual(v.expected);
    });
  }
});
