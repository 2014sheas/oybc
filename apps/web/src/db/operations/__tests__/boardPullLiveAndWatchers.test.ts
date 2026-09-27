import { afterEach, describe, expect, it } from 'vitest';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { applyRemoteSubdoc } from '../pullApply';
import { applyTaskEventsBatch } from '../taskEventPull';
import { sealBoard } from '../sealing';
import { reopenBoard } from '../boardLifecycle';

/**
 * Board Edit post-merge sweep — pull-path gaps (findings 1 + 3):
 *
 *  1. A pulled REOPEN (a board row that was sealed locally and arrives
 *     unsealed) re-derives the board's LIVE stats from THIS device's event
 *     union — non-authored (no version bump, no enqueue), inside the pull txn.
 *  2. Every pull cascade that changes a board (boards / boardTasks /
 *     taskEvents) refreshes that board's achievement watchers — non-authored,
 *     so watcher stats stay a deterministic function of converged data and a
 *     pull never pushes (no ping-pong).
 *
 * Each case drives the REAL pull entry point (`applyRemoteSubdoc` /
 * `applyTaskEventsBatch`) as the receiving device ("B").
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const END = '2026-07-01T23:59:59.999Z';
const IN_WINDOW = '2026-07-01T12:00:00.000Z';
const PAST_AUTO_CLOSE = '2026-07-03T01:00:00.000Z';

const WATCHED = '20000000-0000-4000-8000-000000000001';
const WATCHER = '20000000-0000-4000-8000-000000000002';
const ACH = '30000000-0000-4000-8000-000000000001';

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

function taskId(cell: number): string {
  return `10000000-0000-4000-8000-0000000000${String(cell + 1).padStart(2, '0')}`;
}

async function seedNormalTask(id: string): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'N',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: START,
    endDate: END,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.put(board);
  return board;
}

function placement(boardId: string, tid: string, cell: number): BoardTask {
  return {
    id: `40000000-0000-4000-8000-${boardId.slice(-4)}${String(cell).padStart(8, '0')}`,
    boardId,
    taskId: tid,
    row: Math.floor(cell / 3),
    col: cell % 3,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
}

function completionEvent(id: string, tid: string, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId: tid,
    kind: 'completion',
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

/** A 3×3 WATCHED board with all 9 tasks placed; `completed` cells get an in-window event. */
async function seedWatched(completed: number, over: Partial<Board> = {}): Promise<void> {
  await seedBoard(WATCHED, over);
  for (let cell = 0; cell < 9; cell++) {
    await seedNormalTask(taskId(cell));
    await db.boardTasks.add(placement(WATCHED, taskId(cell), cell));
    if (cell < completed) {
      await db.taskEvents.add(completionEvent(`50000000-0000-4000-8000-0000000000${cell + 10}`, taskId(cell), IN_WINDOW));
    }
  }
}

/** A WATCHER board placing a specific-board GREENLOG achievement on WATCHED. */
async function seedWatcher(): Promise<void> {
  const ach: Task = {
    id: ACH,
    userId: USER,
    title: 'Watch it',
    type: TaskType.ACHIEVEMENT,
    referencedBoardId: WATCHED,
    achievementTrigger: AchievementTrigger.GREENLOG,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(ach);
  await seedBoard(WATCHER, { totalTasks: 9 });
  await db.boardTasks.add(placement(WATCHER, ACH, 0));
}

async function boardQueueEntries(boardId: string) {
  return (await db.syncQueue.toArray()).filter((i) => i.entityType === 'boards' && i.entityId === boardId);
}

describe('boards pull — a pulled Reopen re-derives LIVE stats from the local event union', () => {
  it("device B keeps its own late log after pulling A's LWW-newer reopened row (non-authored)", async () => {
    // B: 8 in-window completions, closed, then a late log on the 9th (the
    // sealed re-derive already made B's snapshot 9/9 COMPLETED locally).
    await seedWatched(8);
    await sealBoard(WATCHED, PAST_AUTO_CLOSE);
    await db.taskEvents.add(completionEvent('50000000-0000-4000-8000-000000000099', taskId(8), END));
    const sealedLocal = (await db.boards.get(WATCHED))!;

    // A never saw B's late log: it reopened at 8/9 ACTIVE, version bumped.
    const { sealedAt: _s, sealedCompletedCells: _c, ...rest } = sealedLocal;
    const remoteReopened: Board = {
      ...rest,
      completedTasks: 8,
      linesCompleted: 1,
      completedLineIds: [],
      status: BoardStatus.ACTIVE,
      reopenedAt: '2026-07-04T00:00:00.000Z',
      updatedAt: '2026-07-04T00:00:00.000Z',
      version: sealedLocal.version + 1,
    };
    await db.syncQueue.clear();

    const status = await applyRemoteSubdoc('boards', remoteReopened, USER);
    expect(status).toMatch(/^Pulled /);

    const board = (await db.boards.get(WATCHED))!;
    expect(board.sealedAt).toBeUndefined();
    // B's converged union (8 + its late log) → 9/9 greenlog, not A's 8/9.
    expect(board.completedTasks).toBe(9);
    expect(board.linesCompleted).toBe(8);
    expect(board.status).toBe(BoardStatus.COMPLETED);
    // Non-authored: the pulled version stands, nothing is pushed back.
    expect(board.version).toBe(remoteReopened.version);
    expect(await boardQueueEntries(WATCHED)).toHaveLength(0);
  });

  it('a local reopen (the authoring device) still bumps + enqueues — unchanged', async () => {
    await seedWatched(8);
    await sealBoard(WATCHED, PAST_AUTO_CLOSE);
    const before = (await db.boards.get(WATCHED))!.version;
    await db.syncQueue.clear();
    await reopenBoard(WATCHED, '2026-07-04T00:00:00.000Z');
    expect((await db.boards.get(WATCHED))!.version).toBeGreaterThan(before);
    expect((await boardQueueEntries(WATCHED)).length).toBeGreaterThan(0);
  });
});

describe('pull cascades refresh achievement watchers (non-authored)', () => {
  it('taskEvents pull: the 9th completion greenlogs WATCHED → the watcher square greens', async () => {
    await seedWatched(8);
    await seedWatcher();
    const watcherBefore = (await db.boards.get(WATCHER))!;

    await applyTaskEventsBatch(USER, [completionEvent('50000000-0000-4000-8000-000000000077', taskId(8), IN_WINDOW)]);

    expect((await db.boards.get(WATCHED))!.status).toBe(BoardStatus.COMPLETED);
    const watcher = (await db.boards.get(WATCHER))!;
    expect(watcher.completedTasks).toBe(1);
    expect(watcher.version).toBe(watcherBefore.version);
    expect(await boardQueueEntries(WATCHER)).toHaveLength(0);
  });

  it('boardTasks pull: a pulled placement completing WATCHED greens the watcher square', async () => {
    // WATCHED: 9 tasks, all completed, but cell 8's placement hasn't arrived yet.
    await seedBoard(WATCHED);
    for (let cell = 0; cell < 9; cell++) {
      await seedNormalTask(taskId(cell));
      await db.taskEvents.add(completionEvent(`50000000-0000-4000-8000-0000000000${cell + 10}`, taskId(cell), IN_WINDOW));
      if (cell < 8) await db.boardTasks.add(placement(WATCHED, taskId(cell), cell));
    }
    await seedWatcher();
    const watcherBefore = (await db.boards.get(WATCHER))!;

    await applyRemoteSubdoc('boardTasks', placement(WATCHED, taskId(8), 8), USER);

    expect((await db.boards.get(WATCHED))!.status).toBe(BoardStatus.COMPLETED);
    const watcher = (await db.boards.get(WATCHER))!;
    expect(watcher.completedTasks).toBe(1);
    expect(watcher.version).toBe(watcherBefore.version);
    expect(await boardQueueEntries(WATCHER)).toHaveLength(0);
  });

  it('boards pull: a pulled WATCHED row now COMPLETED greens the watcher square', async () => {
    await seedWatched(9);
    await seedWatcher();
    const watcherBefore = (await db.boards.get(WATCHER))!;
    const local = (await db.boards.get(WATCHED))!;

    await applyRemoteSubdoc(
      'boards',
      { ...local, completedTasks: 9, linesCompleted: 8, status: BoardStatus.COMPLETED, completedAt: IN_WINDOW, version: local.version + 1, updatedAt: IN_WINDOW },
      USER,
    );

    const watcher = (await db.boards.get(WATCHER))!;
    expect(watcher.completedTasks).toBe(1);
    expect(watcher.version).toBe(watcherBefore.version);
    expect(await boardQueueEntries(WATCHER)).toHaveLength(0);
  });
});
