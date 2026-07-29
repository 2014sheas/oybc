import { describe, expect, it } from 'vitest';
import { TaskType, type BoardTask, type Task, type TaskEvent } from '@oybc/shared';
import type { SquareWindowContext } from '../../db/adapters';
import { buildArrivalSquares } from '../useCounterArrivals';

/**
 * Pure-adapter tests for `buildArrivalSquares` — the firebase-free bridge from
 * the board-play read-model to the shared `ArrivalSquare[]` that
 * `detectCounterArrivals` consumes. Covers member classification (source /
 * linked / excluded) and the displayed-count derivation.
 */

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

const WINDOW_START = '2026-01-01T00:00:00.000Z';

/** Window read-model: SOURCE counters resolve their count from in-window
 *  increment events (issue #377), exactly like the grid cell. */
function ctx(eventsByTaskId: Record<string, TaskEvent[]> = {}): SquareWindowContext {
  return { windowStart: WINDOW_START, eventsByTaskId };
}

function increment(taskId: string, delta: number, occurredAt = '2026-01-10T00:00:00.000Z'): TaskEvent {
  return {
    id: `ev-${taskId}-${occurredAt}-${delta}`,
    userId: 'u1',
    taskId,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  } as TaskEvent;
}

function bt(taskId: string, row = 0, col = 0): BoardTask {
  return {
    id: `bt-${taskId}`,
    boardId: 'board-1',
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  } as BoardTask;
}

describe('buildArrivalSquares', () => {
  it('emits a square for a shared-counter SOURCE with its raw currentCount', () => {
    const source = makeTask({ id: 'src', title: 'Push-ups', currentCount: 12, maxCount: 50 });
    const linked = makeTask({ id: 'lnk', sharedCounterId: 'src', baseline: 0, currentCount: 12 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source, lnk: linked },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx({ src: [increment('src', 12)] }),
    });
    expect(squares).toEqual([
      { taskId: 'src', counterId: 'src', counterName: 'Push-ups', displayed: 12 },
    ]);
  });

  it('emits a square for a LINKED member with baseline-adjusted displayed count', () => {
    const source = makeTask({ id: 'src', title: 'Push-ups', currentCount: 20 });
    // baseline 5 → displayed = max(0, 20 - 5) = 15
    const linked = makeTask({ id: 'lnk', sharedCounterId: 'src', baseline: 5, currentCount: 20, maxCount: 30 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('lnk')],
      taskMap: { src: source, lnk: linked },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx(),
    });
    expect(squares).toEqual([
      { taskId: 'lnk', counterId: 'src', counterName: 'Push-ups', displayed: 15 },
    ]);
  });

  it('names the counter from the pair-derived action + unit (verb elided for "Do")', () => {
    const source = makeTask({ id: 'src', title: '', action: 'Run', maxCount: 5, unit: 'miles', currentCount: 2 });
    const linked = makeTask({ id: 'lnk', sharedCounterId: 'src', baseline: 0, currentCount: 2 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source, lnk: linked },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx(),
    });
    expect(squares[0].counterName).toBe('Run miles');
    expect(squares[0].counterId).toBe('src');
  });

  it('R3: prefers the pair-derived name over a stored title when both are present', () => {
    // Copy contract — counter names are pair-derived, NEVER raw task.title,
    // even when a (stale or user-set) title exists alongside a real pair.
    const source = makeTask({ id: 'src', title: 'My push-up counter', action: 'Do', unit: 'push-ups', currentCount: 4 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx(),
    });
    expect(squares[0].counterName).toBe('Push-ups');
  });

  it('R3: falls back to the stored title when the pair is empty', () => {
    const source = makeTask({ id: 'src', title: 'Legacy counter name', currentCount: 4 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx(),
    });
    expect(squares[0].counterName).toBe('Legacy counter name');
  });

  it('excludes standalone (unlinked) counting tasks and non-counting tasks', () => {
    const standalone = makeTask({ id: 'solo', title: 'Solo', currentCount: 3 });
    const normal = makeTask({ id: 'norm', title: 'Normal', type: TaskType.NORMAL });
    const squares = buildArrivalSquares({
      boardTasks: [bt('solo'), bt('norm')],
      taskMap: { solo: standalone, norm: normal },
      sharedCounterSourceIds: new Set(),
      windowContext: ctx(),
    });
    expect(squares).toEqual([]);
  });

  it('skips placements whose task is missing from the map', () => {
    const squares = buildArrivalSquares({
      boardTasks: [bt('ghost')],
      taskMap: {},
      sharedCounterSourceIds: new Set(['ghost']),
      windowContext: ctx(),
    });
    expect(squares).toEqual([]);
  });

  it('P5: a flagged zero-link counter source participates via its own id', () => {
    // A promoted/hub-born counter (isCounter: true) with NO linked members
    // still shows up in sharedCounterSourceIds (per useBoardPlayData's
    // isCounter branch) — it should self-resolve to its own counterId.
    const source = makeTask({ id: 'src', title: 'Push-ups', isCounter: true, currentCount: 8 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx({ src: [increment('src', 8)] }),
    });
    expect(squares).toEqual([
      { taskId: 'src', counterId: 'src', counterName: 'Push-ups', displayed: 8 },
    ]);
  });

  it('issue #377: a SOURCE counter resolves WINDOWED, not from its lifetime cache', () => {
    // Lifetime currentCount says 12, but only 5 of it happened inside this
    // board's window — the arrival baseline must see 5, matching the grid
    // cell. Pre-fix (raw task.currentCount) this read 12.
    const source = makeTask({ id: 'src', title: 'Push-ups', currentCount: 12, maxCount: 50 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source },
      sharedCounterSourceIds: new Set(['src']),
      windowContext: ctx({
        src: [
          increment('src', 7, '2025-12-20T00:00:00.000Z'), // pre-window
          increment('src', 5, '2026-01-10T00:00:00.000Z'), // in-window
        ],
      }),
    });
    expect(squares[0].displayed).toBe(5);
  });
});
