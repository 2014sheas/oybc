import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type Task } from '@oybc/shared';
import { db } from '../../db/internal';

/**
 * A log writes one `taskEvents` row, which re-runs every live query that reads
 * the table. The board must pay for exactly ONE full scan per log (the board's
 * own window context) — not a second one hidden in the task library, and not a
 * workspace-wide `boardTasks` scan nothing reads.
 *
 * `useLiveQuery` is stubbed to capture each hook's querier (the function Dexie
 * re-runs on a change); running every captured querier once is one emission.
 */
const queriers: Array<() => unknown> = [];
vi.mock('dexie-react-hooks', () => ({
  useLiveQuery: (querier: () => unknown): undefined => {
    queriers.push(querier);
    return undefined;
  },
}));

const { useBoardPlayData } = await import('../useBoardPlayData');
const { useTaskLibrary, useLibraryEventsByTaskId } = await import('../../pages/createPage/useTaskLibrary');

const NOW = '2026-01-01T00:00:00.000Z';
const board: Board = {
  id: 'b1', userId: 'u', name: 'B', status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
  startDate: NOW, endDate: '2099-01-01T00:00:00.000Z', centerSquareType: CenterSquareType.NONE,
  isRandomized: false, totalTasks: 1, completedTasks: 0, linesCompleted: 0, completedLineIds: [], createdAt: NOW, updatedAt: NOW,
  version: 1, isDeleted: false,
};
const counting = {
  id: 't1', userId: 'u', title: 'Read', type: TaskType.COUNTING, action: 'Read', unit: 'pages', maxCount: 20, currentCount: 0,
  isCompleted: false, totalCompletions: 0, totalInstances: 1, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
} as Task;

/** Renders `hook` once (capturing its queriers) and runs them all once — one live-query emission. */
async function emit(hook: () => unknown): Promise<void> {
  queriers.length = 0;
  function Harness(): null {
    hook();
    return null;
  }
  renderToStaticMarkup(React.createElement(Harness));
  await Promise.all(queriers.map((q) => q()));
}

let eventScans: ReturnType<typeof vi.spyOn>;
let boardTaskScans: ReturnType<typeof vi.spyOn>;

beforeEach(async () => {
  await db.tasks.add(counting);
  eventScans = vi.spyOn(db.taskEvents, 'toArray');
  boardTaskScans = vi.spyOn(db.boardTasks, 'filter');
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([db.tasks, db.taskEvents, db.boardTasks, db.compoundChildren].map((t) => t.clear()));
});

describe('taskEvents scans per emission', () => {
  it('the board data hook scans taskEvents ONCE (its own window context), not once more for the task library', async () => {
    await emit(() => useBoardPlayData(board, 'u'));
    expect(eventScans).toHaveBeenCalledTimes(1);
  });

  it('the board data hook no longer scans every placement in the workspace', async () => {
    await emit(() => useBoardPlayData(board, 'u'));
    expect(boardTaskScans).not.toHaveBeenCalled();
  });

  it('useTaskLibrary does not touch taskEvents at all', async () => {
    await emit(() => useTaskLibrary('u'));
    expect(eventScans).not.toHaveBeenCalled();
  });

  it('the opt-in library events hook is the one that scans, once', async () => {
    await emit(() => useLibraryEventsByTaskId());
    expect(eventScans).toHaveBeenCalledTimes(1);
  });
});
