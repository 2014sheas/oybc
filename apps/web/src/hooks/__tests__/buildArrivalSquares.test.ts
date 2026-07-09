import { describe, expect, it } from 'vitest';
import { TaskType, type BoardTask, type Task } from '@oybc/shared';
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
    });
    expect(squares).toEqual([
      { taskId: 'lnk', counterId: 'src', counterName: 'Push-ups', displayed: 15 },
    ]);
  });

  it('names the counter from a titleless source via generateCounterTaskTitle', () => {
    const source = makeTask({ id: 'src', title: '', action: 'Run', maxCount: 5, unit: 'miles', currentCount: 2 });
    const linked = makeTask({ id: 'lnk', sharedCounterId: 'src', baseline: 0, currentCount: 2 });
    const squares = buildArrivalSquares({
      boardTasks: [bt('src')],
      taskMap: { src: source, lnk: linked },
      sharedCounterSourceIds: new Set(['src']),
    });
    expect(squares[0].counterName).not.toBe('');
    expect(squares[0].counterId).toBe('src');
  });

  it('excludes standalone (unlinked) counting tasks and non-counting tasks', () => {
    const standalone = makeTask({ id: 'solo', title: 'Solo', currentCount: 3 });
    const normal = makeTask({ id: 'norm', title: 'Normal', type: TaskType.NORMAL });
    const squares = buildArrivalSquares({
      boardTasks: [bt('solo'), bt('norm')],
      taskMap: { solo: standalone, norm: normal },
      sharedCounterSourceIds: new Set(),
    });
    expect(squares).toEqual([]);
  });

  it('skips placements whose task is missing from the map', () => {
    const squares = buildArrivalSquares({
      boardTasks: [bt('ghost')],
      taskMap: {},
      sharedCounterSourceIds: new Set(['ghost']),
    });
    expect(squares).toEqual([]);
  });
});
