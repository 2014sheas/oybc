import { afterEach, describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type BoardTask, type Task } from '@oybc/shared';
import { db } from '../../db/internal';
import { buildSquareWindowContext } from '../../db/adapters';
import { useBoardPlay, type UseBoardPlayResult } from '../useBoardPlay';

/**
 * The sheet's write wrappers report whether they COMMITTED, and the standalone
 * count write reads the prior count inside the write (never a stale render).
 * The hook is rendered once with react-dom/server (node harness, no DOM) and
 * its returned callbacks are driven against fake-indexeddb.
 */

const NOW = '2026-01-01T00:00:00.000Z';
const BOARD_ID = 'board-1';
const TASK_ID = 'task-1';
const BT_ID = 'bt-1';

const board = (o: Partial<Board> = {}): Board => ({
  id: BOARD_ID, userId: 'u', name: 'B', status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
  startDate: '2026-01-01T00:00:00.000Z', endDate: '2099-01-01T00:00:00.000Z', centerSquareType: CenterSquareType.NONE,
  isRandomized: false, totalTasks: 1, completedTasks: 0, linesCompleted: 0, completedLineIds: [], createdAt: NOW, updatedAt: NOW,
  version: 1, isDeleted: false, ...o,
});
const counting: Task = {
  id: TASK_ID, userId: 'u', title: 'Read', type: TaskType.COUNTING, action: 'Read', unit: 'pages', maxCount: 20, currentCount: 0,
  isCompleted: false, totalCompletions: 0, totalInstances: 1, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
} as Task;
const placement: BoardTask = { id: BT_ID, boardId: BOARD_ID, taskId: TASK_ID, row: 0, col: 0, isCenter: false, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false };

/** Renders the hook once (a deliberately STALE snapshot: no events) and returns its result. */
function mount(playLocked = false): UseBoardPlayResult {
  const b = board();
  let out: UseBoardPlayResult | undefined;
  function Harness(): null {
    out = useBoardPlay({
      board: b, editMode: false, boardTasks: [placement], taskMap: { [TASK_ID]: counting }, compoundChildrenByCompound: {}, gridSize: 3,
      playLocked, squareWindowContext: buildSquareWindowContext([], b.startDate, b.endDate ?? null), sharedCounterSourceIds: new Set(),
      onFlash: () => {}, onCreditedToast: () => {}, setContextMenu: () => {},
    });
    return null;
  }
  renderToStaticMarkup(React.createElement(Harness));
  return out as UseBoardPlayResult;
}

async function seed(): Promise<void> {
  await db.boards.add(board());
  await db.tasks.add(counting);
  await db.boardTasks.add(placement);
}

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([db.boards, db.tasks, db.boardTasks, db.taskEvents, db.syncQueue, db.compoundChildren].map((t) => t.clear()));
});

describe('useBoardPlay write results', () => {
  it('logStandaloneCount reads the prior count inside the write: two logs from one stale render add up, and `before` is the true prior value', async () => {
    await seed();
    const play = mount();
    const first = await play.logStandaloneCount(BT_ID, 5);
    const second = await play.logStandaloneCount(BT_ID, 5);
    expect(first).toEqual({ before: 0, applied: 5 });
    expect(second).toEqual({ before: 5, applied: 5 });
    // Restoring `before` is exactly the prior value.
    expect(await play.handleComplete(BT_ID, { currentCount: second?.before })).toBe(true);
    const after = await play.logStandaloneCount(BT_ID, 1);
    expect(after?.before).toBe(5);
  });

  it('a removal clamps at zero and reports the amount actually applied; a no-op reports null', async () => {
    await seed();
    const play = mount();
    await play.logStandaloneCount(BT_ID, 3);
    expect(await play.logStandaloneCount(BT_ID, -10)).toEqual({ before: 3, applied: 3 });
    expect(await play.logStandaloneCount(BT_ID, -1)).toBeNull();
  });

  it('a locked board commits nothing', async () => {
    await seed();
    const play = mount(true);
    expect(await play.logStandaloneCount(BT_ID, 1)).toBeNull();
    expect(await play.handleSharedCounterIncrement(TASK_ID, 1)).toBe(0);
    expect(await play.handleSharedCounterDecrement(TASK_ID, 1)).toBe(0);
    expect(await play.handleCompoundChildToggle('x')).toBeNull();
    expect(await play.handleCompoundChildIncrement('x', 1, 1)).toBe(0);
    expect(await db.taskEvents.count()).toBe(0);
  });

  it('a second absolute-count write while one is in flight is dropped (null), not queued', async () => {
    await seed();
    const play = mount();
    const [a, b] = await Promise.all([play.logStandaloneCount(BT_ID, 1), play.logStandaloneCount(BT_ID, 1)]);
    expect([a, b].filter((r) => r !== null)).toHaveLength(1);
  });

  it('a caught failure reports false', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    await seed();
    const play = mount();
    expect(await play.handleComplete('missing-bt', { isCompleted: true })).toBe(false);
  });
});
