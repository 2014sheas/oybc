import { computeSealedCompletedCells } from '../../src/algorithms/derivationPass';
import type { WindowEvaluationContext } from '../../src/algorithms/taskEvents';
import type { Task, TaskEvent, Board, BoardTask } from '../../src/types';
import { TaskType, Timeframe, BoardStatus, CenterSquareType } from '../../src/constants/enums';

/**
 * migrationSealConvergence.test.ts — Windowed Completion I-1 (docs
 * §Migration → "Migration bleed-greens converge to windowed truth").
 *
 * The migration seals expired boards from the PRE-migration rendered state
 * (lifetime `Task.isCompleted` / `currentCount` caches — NO window context), so
 * a board can be sealed with a "bleed" green: a square whose task was completed
 * BEFORE that board's window even opened. That green is the exact cross-window
 * bleed this whole design exists to fix, frozen for one migration.
 *
 * It is not permanent. The moment the first post-migration `taskEvent` for a
 * placed task lands (any synced activity), the pull-path re-derivation hook
 * recomputes the sealed snapshot from the WINDOWED event union bounded at the
 * board's `sealedAt` — and the bleed square flips grey, converging the frozen
 * record to windowed truth. This test exercises exactly that flip at the shared
 * kernel level (`computeSealedCompletedCells` lifetime → windowed), the pure
 * function both the migration seal and the re-derivation hook call.
 */

const START = '2026-07-01T00:00:00.000Z';
const END = '2026-07-01T23:59:59.999Z';

function board(): Board {
  return {
    id: 'b-1',
    userId: 'u-1',
    name: 'Daily',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
    endDate: END,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: undefined,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

/** A NORMAL task whose lifetime cache says "complete" (the bleed). */
function bleedNormalTask(): Task {
  return {
    id: 't-normal',
    userId: 'u-1',
    title: 'Meditate',
    type: TaskType.NORMAL,
    sharedCounterId: null,
    isCompleted: true, // lifetime bleed — set before this window opened
    totalCompletions: 1,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

/** A COUNTING task whose lifetime cache meets the goal (the bleed). */
function bleedCountingTask(): Task {
  return {
    id: 't-count',
    userId: 'u-1',
    title: 'Pushups',
    type: TaskType.COUNTING,
    maxCount: 3,
    sharedCounterId: null,
    isCompleted: true,
    currentCount: 3, // lifetime bleed
    totalCompletions: 1,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

function bt(id: string, taskId: string, row: number, col: number): BoardTask {
  return {
    id,
    boardId: 'b-1',
    taskId,
    row,
    col,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isCenter: false,
  };
}

function ev(id: string, taskId: string, kind: 'completion' | 'increment', occurredAt: string, delta?: number): TaskEvent {
  return {
    id,
    userId: 'u-1',
    taskId,
    kind,
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

describe('I-1 — migration bleed-greens converge to windowed truth on re-derivation', () => {
  const tasks = {
    't-normal': bleedNormalTask(),
    't-count': bleedCountingTask(),
  };
  const boardTasks = [bt('bt-1', 't-normal', 0, 0), bt('bt-2', 't-count', 0, 1)];

  it('migration seal (lifetime, no window context) keeps both bleed squares green', () => {
    // The migration path passes NO windowContext, so it reads the lifetime
    // isCompleted/currentCount caches — both squares bleed green (+ FREE center).
    const cells = computeSealedCompletedCells(board(), boardTasks, {}, tasks, []);
    expect(cells).toEqual([0, 1, 4]);
  });

  it('re-derivation (windowed) flips a NORMAL bleed square grey — event pre-dates the window', () => {
    // The only event for the normal task occurred BEFORE the board's window.
    // The counting task's increments all fall inside the window (accurate).
    const eventsByTaskId: Record<string, TaskEvent[]> = {
      't-normal': [ev('e1', 't-normal', 'completion', '2026-06-28T08:00:00.000Z')],
      't-count': [
        ev('e2', 't-count', 'increment', '2026-07-01T09:00:00.000Z', 2),
        ev('e3', 't-count', 'increment', '2026-07-01T10:00:00.000Z', 1),
      ],
    };
    const windowContext: WindowEvaluationContext = { eventsByTaskId };
    const cells = computeSealedCompletedCells(board(), boardTasks, {}, tasks, [], windowContext);
    // Normal bleed (cell 0) is gone; counting (cell 1, 3/3 in-window) stays; center stays.
    expect(cells).toEqual([1, 4]);
  });

  it('re-derivation (windowed) flips a COUNTING bleed square grey — increments pre-date the window', () => {
    const eventsByTaskId: Record<string, TaskEvent[]> = {
      't-normal': [ev('e1', 't-normal', 'completion', '2026-07-01T08:00:00.000Z')],
      't-count': [
        // Both increments happened before the window — windowed sum is 0 < goal.
        ev('e2', 't-count', 'increment', '2026-06-30T09:00:00.000Z', 2),
        ev('e3', 't-count', 'increment', '2026-06-30T10:00:00.000Z', 1),
      ],
    };
    const windowContext: WindowEvaluationContext = { eventsByTaskId };
    const cells = computeSealedCompletedCells(board(), boardTasks, {}, tasks, [], windowContext);
    // Counting bleed (cell 1) is gone; normal (cell 0, in-window completion) stays; center stays.
    expect(cells).toEqual([0, 4]);
  });

  it('re-derivation is deterministic — same union in any order yields the same converged snapshot', () => {
    const eventsByTaskId: Record<string, TaskEvent[]> = {
      't-count': [
        ev('e3', 't-count', 'increment', '2026-07-01T10:00:00.000Z', 1),
        ev('e2', 't-count', 'increment', '2026-07-01T09:00:00.000Z', 2),
      ],
    };
    const forward = computeSealedCompletedCells(board(), boardTasks, {}, tasks, [], { eventsByTaskId });
    const reversed = computeSealedCompletedCells(board(), boardTasks, {}, tasks, [], {
      eventsByTaskId: { 't-count': [...eventsByTaskId['t-count']].reverse() },
    });
    expect(forward).toEqual(reversed);
  });
});
