import { evaluateCompound } from '../../src/algorithms/compoundEvaluation';
import { computeBoardStatsUpdate } from '../../src/algorithms/derivationPass';
import type { CompoundWindowContext, WindowEvaluationContext } from '../../src/algorithms/taskEvents';
import type { Task, TaskEvent, CompoundChild, Board, BoardTask } from '../../src/types';
import { TaskType, OperatorType, Timeframe, BoardStatus, CenterSquareType } from '../../src/constants/enums';

/**
 * windowedEvaluation.test.ts — Windowed Completion PR A additive window-context
 * params on evaluateCompound + computeBoardStatsUpdate
 * (docs/WINDOWED_COMPLETION.md §Semantics per task type). The overriding proof
 * here is the LIFETIME DEFAULT: with no context the behavior is byte-identical
 * to before (also covered exhaustively by the 861 pre-existing tests). The new
 * cases exercise the windowed branch, host-window inheritance, and the
 * derived-counting-child carve-out.
 */

const WINDOW_START = '2026-07-01T00:00:00.000Z';
const IN_WINDOW = '2026-07-05T12:00:00.000Z';
const PRE_WINDOW = '2026-06-20T12:00:00.000Z';

function makeTask(overrides: Partial<Task>): Task {
  return {
    id: 'task-x',
    userId: 'user-1',
    title: 'T',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function completion(taskId: string, occurredAt: string): TaskEvent {
  return {
    id: `ev-c-${taskId}-${occurredAt}`,
    userId: 'user-1',
    taskId,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

function link(compoundTaskId: string, childTaskId: string, childIndex: number): CompoundChild {
  return {
    id: `link-${compoundTaskId}-${childTaskId}`,
    compoundTaskId,
    childTaskId,
    childIndex,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
  };
}

describe('evaluateCompound — lifetime default (no window context)', () => {
  it('reads child.isCompleted cache unchanged when windowContext is omitted', () => {
    const parent = makeTask({ id: 'p', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const a = makeTask({ id: 'a', isCompleted: true });
    const b = makeTask({ id: 'b', isCompleted: true });
    const children = { p: [link('p', 'a', 0), link('p', 'b', 1)] };
    const taskById = { p: parent, a, b };
    expect(evaluateCompound(parent, children, taskById)).toBe(true);

    b.isCompleted = false;
    expect(evaluateCompound(parent, children, taskById)).toBe(false);
  });
});

describe('evaluateCompound — windowed', () => {
  it('AND compound: both children in-window complete → complete', () => {
    const parent = makeTask({ id: 'p', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const a = makeTask({ id: 'a', isCompleted: false });
    const b = makeTask({ id: 'b', isCompleted: false });
    const children = { p: [link('p', 'a', 0), link('p', 'b', 1)] };
    const taskById = { p: parent, a, b };
    const ctx: CompoundWindowContext = {
      windowStart: WINDOW_START,
      eventsByTaskId: {
        a: [completion('a', IN_WINDOW)],
        b: [completion('b', IN_WINDOW)],
      },
    };
    expect(evaluateCompound(parent, children, taskById, ctx)).toBe(true);
  });

  it('AND compound: one child completed only pre-window → incomplete (bleed fixed)', () => {
    const parent = makeTask({ id: 'p', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const a = makeTask({ id: 'a', isCompleted: true }); // lifetime cache says complete…
    const b = makeTask({ id: 'b', isCompleted: true });
    const children = { p: [link('p', 'a', 0), link('p', 'b', 1)] };
    const taskById = { p: parent, a, b };
    const ctx: CompoundWindowContext = {
      windowStart: WINDOW_START,
      eventsByTaskId: {
        a: [completion('a', IN_WINDOW)],
        b: [completion('b', PRE_WINDOW)], // …but this window is empty for b
      },
    };
    expect(evaluateCompound(parent, children, taskById, ctx)).toBe(false);
  });

  it('nested compound inherits the same host window', () => {
    // parent AND [ inner(OR[a,b]) ]
    const parent = makeTask({ id: 'p', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const inner = makeTask({ id: 'inner', type: TaskType.COMPOUND, operator: OperatorType.OR });
    const a = makeTask({ id: 'a' });
    const b = makeTask({ id: 'b' });
    const children = {
      p: [link('p', 'inner', 0)],
      inner: [link('inner', 'a', 0), link('inner', 'b', 1)],
    };
    const taskById = { p: parent, inner, a, b };

    // Only b has an in-window completion → OR satisfied → parent AND satisfied.
    const ctxSat: CompoundWindowContext = {
      windowStart: WINDOW_START,
      eventsByTaskId: { a: [completion('a', PRE_WINDOW)], b: [completion('b', IN_WINDOW)] },
    };
    expect(evaluateCompound(parent, children, taskById, ctxSat)).toBe(true);

    // Both only pre-window → inner OR empty in-window → parent incomplete.
    const ctxUnsat: CompoundWindowContext = {
      windowStart: WINDOW_START,
      eventsByTaskId: { a: [completion('a', PRE_WINDOW)], b: [completion('b', PRE_WINDOW)] },
    };
    expect(evaluateCompound(parent, children, taskById, ctxUnsat)).toBe(false);
  });

  it('derived-counting child resolves via its lifetime cache (carve-out), not events', () => {
    const parent = makeTask({ id: 'p', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const derived = makeTask({
      id: 'd',
      type: TaskType.COUNTING,
      maxCount: 10,
      sharedCounterId: 'src-1',
      baseline: 0,
      isCompleted: true, // cache says complete
    });
    const children = { p: [link('p', 'd', 0)] };
    const taskById = { p: parent, d: derived };
    // No events for the derived task — windowed mode still honors the cache.
    const ctx: CompoundWindowContext = { windowStart: WINDOW_START, eventsByTaskId: {} };
    expect(evaluateCompound(parent, children, taskById, ctx)).toBe(true);

    derived.isCompleted = false;
    expect(evaluateCompound(parent, children, taskById, ctx)).toBe(false);
  });
});

// ─── computeBoardStatsUpdate window context ─────────────────────────────────

function makeBoard(overrides: Partial<Board>): Board {
  return {
    id: 'board-1',
    userId: 'user-1',
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: WINDOW_START,
    endDate: '2026-07-01T23:59:59.999Z',
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function placement(taskId: string, row: number, col: number): BoardTask {
  return {
    id: `bt-${taskId}`,
    boardId: 'board-1',
    taskId,
    row,
    col,
    createdAt: WINDOW_START,
    updatedAt: WINDOW_START,
    version: 1,
    isCenter: false,
    isDeleted: false,
  };
}

describe('computeBoardStatsUpdate — window context', () => {
  it('lifetime default: a task completed pre-window still reads complete (today’s behavior)', () => {
    const t = makeTask({ id: 't', isCompleted: true });
    const board = makeBoard({});
    const result = computeBoardStatsUpdate(board, [placement('t', 0, 0)], {}, { t }, [], undefined);
    expect(result.completedTasks).toBe(1);
  });

  it('windowed: the same pre-window completion goes grey (bleed fix)', () => {
    const t = makeTask({ id: 't', isCompleted: true });
    const board = makeBoard({});
    const windowCtx: WindowEvaluationContext = {
      eventsByTaskId: { t: [completion('t', PRE_WINDOW)] },
    };
    const result = computeBoardStatsUpdate(board, [placement('t', 0, 0)], {}, { t }, [], windowCtx);
    expect(result.completedTasks).toBe(0);
  });

  it('windowed: a placed event-owning task absent from the events map defaults to no events (grey)', () => {
    const t = makeTask({ id: 't', isCompleted: true });
    const board = makeBoard({});
    const windowCtx: WindowEvaluationContext = { eventsByTaskId: {} }; // no entry for `t`
    const result = computeBoardStatsUpdate(board, [placement('t', 0, 0)], {}, { t }, [], windowCtx);
    expect(result.completedTasks).toBe(0);
  });

  it('windowed: an in-window completion is green', () => {
    const t = makeTask({ id: 't', isCompleted: false });
    const board = makeBoard({});
    const windowCtx: WindowEvaluationContext = {
      eventsByTaskId: { t: [completion('t', IN_WINDOW)] },
    };
    const result = computeBoardStatsUpdate(board, [placement('t', 0, 0)], {}, { t }, [], windowCtx);
    expect(result.completedTasks).toBe(1);
  });

  it('windowed: derived-counting square reads its isCompleted cache (carve-out)', () => {
    const derived = makeTask({
      id: 'd',
      type: TaskType.COUNTING,
      maxCount: 10,
      sharedCounterId: 'src-1',
      baseline: 0,
      isCompleted: true,
    });
    const board = makeBoard({});
    const windowCtx: WindowEvaluationContext = { eventsByTaskId: {} };
    const result = computeBoardStatsUpdate(board, [placement('d', 0, 0)], {}, { d: derived }, [], windowCtx);
    expect(result.completedTasks).toBe(1);
  });

  it('windowed: plain counting square sums in-window increments', () => {
    const c = makeTask({ id: 'c', type: TaskType.COUNTING, maxCount: 3, isCompleted: false });
    const board = makeBoard({});
    const inc = (occurredAt: string, delta: number): TaskEvent => ({
      ...completion('c', occurredAt),
      id: `inc-${occurredAt}`,
      kind: 'increment',
      delta,
    });
    const windowCtx: WindowEvaluationContext = {
      eventsByTaskId: { c: [inc(IN_WINDOW, 2), inc('2026-07-06T00:00:00.000Z', 1)] },
    };
    const result = computeBoardStatsUpdate(board, [placement('c', 0, 0)], {}, { c }, [], windowCtx);
    expect(result.completedTasks).toBe(1);
  });
});
