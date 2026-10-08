import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { applyRemoteSubdoc } from '../pullApply';
import { applyTaskEventsBatch } from '../taskEventPull';
import { handleTaskCompletion, runBoardCascadeForBoardId, runBoardCascadeForTasks } from '../orchestration';
import { reorderBoardTasks } from '../boardTasks';

/**
 * Sync churn (owner's Firestore: boards at v3517 / v14639 and every launch
 * re-pushing every live board). Two halves, both pinned here through the REAL
 * entry points:
 *
 *  F1 — a board derivation write only happens (version bump + enqueue) when a
 *       derived field actually changed (`boardDerivedStateChanged`).
 *  F2 — the pull path skips a row identical to the stored one (same version +
 *       updatedAt — an echo of this device's own push): no put, no cascade.
 */

const USER = 'user-1';
const START = '2026-07-01T00:00:00.000Z';
const END = '2099-12-31T23:59:59.999Z';
const IN_WINDOW = '2026-07-02T12:00:00.000Z';
const BOARD = '20000000-0000-4000-8000-000000000001';
const DRAFT = '20000000-0000-4000-8000-000000000002';

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

function taskId(cell: number): string {
  return `10000000-0000-4000-8000-0000000000${String(cell + 1).padStart(2, '0')}`;
}

function eventId(cell: number): string {
  return `50000000-0000-4000-8000-0000000000${String(cell + 10)}`;
}

function normalTask(id: string): Task {
  return {
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
}

function boardRow(id: string, over: Partial<Board> = {}): Board {
  return {
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
    version: 7,
    isDeleted: false,
    ...over,
  };
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

function completionEvent(cell: number): TaskEvent {
  return {
    id: eventId(cell),
    userId: USER,
    taskId: taskId(cell),
    kind: 'completion',
    occurredAt: IN_WINDOW,
    createdAt: IN_WINDOW,
    updatedAt: IN_WINDOW,
    version: 1,
    isDeleted: false,
  };
}

/**
 * A 3×3 board with every task placed; `completed` cells carry an in-window
 * completion event, and the stored stats are already the CORRECT derivation
 * (cells 0-2 complete → row_0 bingo).
 */
async function seedConvergedBoard(completed: number, over: Partial<Board> = {}): Promise<Board> {
  const lines = completed >= 3 ? ['row_0'] : [];
  const board = boardRow(BOARD, {
    completedTasks: completed,
    linesCompleted: lines.length,
    completedLineIds: lines,
    ...over,
  });
  await db.boards.put(board);
  for (let cell = 0; cell < 9; cell++) {
    await db.tasks.put(normalTask(taskId(cell)));
    await db.boardTasks.put(placement(BOARD, taskId(cell), cell));
    if (cell < completed) await db.taskEvents.put(completionEvent(cell));
  }
  return board;
}

async function boardQueue(boardId = BOARD) {
  return (await db.syncQueue.toArray()).filter((i) => i.entityType === 'boards' && i.entityId === boardId);
}

describe('F2 — pull skips an identical echo of our own push', () => {
  it('echoes of our own task / placement / compound link / board leave the board untouched', async () => {
    const seeded = await seedConvergedBoard(3);
    const before = await db.boards.get(BOARD);

    const task = (await db.tasks.get(taskId(0)))!;
    const bt = (await db.boardTasks.get(placement(BOARD, taskId(0), 0).id))!;
    expect(await applyRemoteSubdoc('tasks', { ...task }, USER)).toMatch(/^Unchanged /);
    expect(await applyRemoteSubdoc('boardTasks', { ...bt }, USER)).toMatch(/^Unchanged /);
    expect(await applyRemoteSubdoc('boards', { ...seeded }, USER)).toMatch(/^Unchanged /);

    const after = await db.boards.get(BOARD);
    expect(after?.version).toBe(before?.version);
    expect(after?.updatedAt).toBe(before?.updatedAt);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('an echoed compound link is skipped too', async () => {
    await seedConvergedBoard(0);
    const compound: Task = { ...normalTask('60000000-0000-4000-8000-000000000001'), type: TaskType.COMPOUND };
    await db.tasks.put(compound);
    const link: CompoundChild = {
      id: '70000000-0000-4000-8000-000000000001',
      compoundTaskId: compound.id,
      childTaskId: taskId(0),
      childIndex: 0,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.compoundChildren.put(link);

    expect(await applyRemoteSubdoc('compoundChildren', { ...link }, USER)).toMatch(/^Unchanged /);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('an echoed batch of our own events applies nothing and pushes nothing', async () => {
    await seedConvergedBoard(3);
    const events = await db.taskEvents.toArray();

    const result = await applyTaskEventsBatch(USER, events.map((e) => ({ ...e })));

    expect(result.pulled).toBe(0);
    expect((await db.boards.get(BOARD))?.version).toBe(7);
    expect(await db.syncQueue.count()).toBe(0);
  });
});

describe('F1 — pull cascades only write when the derived state changed', () => {
  it('a newer task row that leaves the board stats unchanged does not bump the board', async () => {
    await seedConvergedBoard(3);
    const task = (await db.tasks.get(taskId(4)))!;

    const status = await applyRemoteSubdoc(
      'tasks',
      { ...task, title: 'Renamed elsewhere', version: 2, updatedAt: IN_WINDOW },
      USER,
    );

    expect(status).toMatch(/^Pulled /);
    expect((await db.tasks.get(taskId(4)))?.title).toBe('Renamed elsewhere');
    expect((await db.boards.get(BOARD))?.version).toBe(7);
    expect(await boardQueue()).toHaveLength(0);
  });

  it('a pull that genuinely changes the derived state bumps once and enqueues once', async () => {
    await seedConvergedBoard(2);

    const result = await applyTaskEventsBatch(USER, [completionEvent(2)]);

    expect(result.pulled).toBe(1);
    const after = await db.boards.get(BOARD);
    expect(after?.completedTasks).toBe(3);
    expect(after?.completedLineIds).toEqual(['row_0']);
    expect(after?.version).toBe(8);
    expect(await boardQueue()).toHaveLength(1);
  });
});

describe('F1 — local cascades skip a no-op write', () => {
  it('runBoardCascadeForTasks on a converged board writes nothing', async () => {
    const seeded = await seedConvergedBoard(3);

    const map = await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      () => runBoardCascadeForTasks([taskId(0), taskId(5)]),
    );

    // The result map is still populated (bingo diffs read it).
    expect(map.get(BOARD)?.completedLineIds).toEqual(['row_0']);
    expect(map.get(BOARD)?.newBingos).toEqual([]);
    const after = await db.boards.get(BOARD);
    expect(after?.version).toBe(seeded.version);
    expect(after?.updatedAt).toBe(seeded.updatedAt);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('runBoardCascadeForBoardId on a converged board writes nothing', async () => {
    await seedConvergedBoard(3);
    await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      () => runBoardCascadeForBoardId(BOARD),
    );
    expect((await db.boards.get(BOARD))?.version).toBe(7);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('an empty DRAFT is still derived but never rewritten when unchanged', async () => {
    await seedConvergedBoard(3);
    await db.boards.put(boardRow(DRAFT, { status: BoardStatus.DRAFT, version: 14639 }));
    await db.boardTasks.put(placement(DRAFT, taskId(8), 8));

    await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      () => runBoardCascadeForTasks([taskId(8)]),
    );

    expect((await db.boards.get(DRAFT))?.version).toBe(14639);
    expect(await boardQueue(DRAFT)).toHaveLength(0);
  });

  it('a positional no-op rearrange (edit cascade) does not bump the derived write', async () => {
    await seedConvergedBoard(3);
    // Swap two incomplete cells: no line or count changes.
    const a = placement(BOARD, taskId(4), 4).id;
    const b = placement(BOARD, taskId(5), 5).id;
    await reorderBoardTasks(BOARD, [
      { boardTaskId: a, row: 1, col: 2 },
      { boardTaskId: b, row: 1, col: 1 },
    ]);
    // The placement rows enqueue (they moved); the board stats did not change.
    expect((await db.boards.get(BOARD))?.version).toBe(7);
    expect(await boardQueue()).toHaveLength(0);
  });
});

describe('F1 — a real completion still bumps once and fires the bingo diff', () => {
  it('completing the third cell of row_0 bumps the board once and reports the bingo', async () => {
    await seedConvergedBoard(2);

    const result = await handleTaskCompletion(BOARD, placement(BOARD, taskId(2), 2).id, { isCompleted: true });

    expect(result.newBingos).toEqual(['row_0']);
    const after = await db.boards.get(BOARD);
    expect(after?.completedTasks).toBe(3);
    expect(after?.version).toBe(8);
    expect(await boardQueue()).toHaveLength(1);
  });
});
