import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  forkTaskId,
  forkedEventId,
  resolveTaskWindowState,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { emptyPatch, type TaskEditPatch } from '../../taskEditPatch';
import {
  applyStagedTaskEditsForWizardPersist,
  persistWizardBoardRows,
  type PersistWizardBoardRowsInput,
} from '../wizardBoard';

/**
 * Board-scoped task edits PR 2 — the board wizard's staged inline edits
 * (docs/BOARD_SCOPED_TASK_EDITS.md §1): a library task placed on another
 * board is FORKED for the board being created (the new board places the
 * fork, the other board keeps the original); a task placed nowhere else —
 * or created in this wizard session — is edited in place. The pool editor's
 * strict path (no board) stays global. iOS twin: `BoardScopedWizardEditTests`.
 */

const USER = 'user-1';
const T0 = '2026-07-01T00:00:00.000Z';
const OTHER = '90000000-0000-4000-8000-0000000000b2';
const START = '2026-07-01T00:00:00.000Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: USER, title: id, type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0,
    totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}

function otherBoard(): Board {
  return {
    id: OTHER, userId: USER, name: 'Monthly', status: BoardStatus.ACTIVE, boardSize: 3,
    timeframe: Timeframe.MONTHLY, startDate: START, endDate: '2026-07-31T23:59:59.999Z',
    centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9, completedTasks: 0,
    linesCompleted: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
  } as Board;
}

function placement(id: string, boardId: string, taskId: string): BoardTask {
  return { id, boardId, taskId, row: 0, col: 0, isCenter: false, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}

function completion(id: string, taskId: string, occurredAt: string): TaskEvent {
  return { id, userId: USER, taskId, kind: 'completion', occurredAt, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}

function input(placed: Task[], stagedEdits: Map<string, TaskEditPatch>, over: Partial<PersistWizardBoardRowsInput> = {}): PersistWizardBoardRowsInput {
  const placement: (Task | null)[] = new Array(9).fill(null);
  placed.forEach((t, i) => (placement[i] = t));
  return {
    userId: USER, draftBoardId: null, isCore: false, isRecurringDraft: false, status: 'active',
    boardFields: {
      name: 'Daily', boardSize: 3, timeframe: Timeframe.DAILY, startDate: START,
      endDate: '2026-07-01T23:59:59.999Z', centerSquareType: CenterSquareType.NONE, isRandomized: false,
    },
    placement, size: 3, centerType: CenterSquareType.NONE, pendingTasks: [], stagedEdits, ...over,
  };
}

afterEach(async () => {
  await Promise.all(
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.pools, db.syncQueue].map((t) => t.clear()),
  );
});

describe('persistWizardBoardRows — board-scoped staged edits', () => {
  it('forks a library task placed on another board: the new board places the fork, completion migrates', async () => {
    const t = task('T', { title: 'Read' });
    await db.tasks.add(t);
    await db.boards.add(otherBoard());
    await db.boardTasks.add(placement('bt-other', OTHER, 'T'));
    await db.taskEvents.bulkAdd([
      completion('e-in', 'T', '2026-07-01T09:00:00.000Z'),
      completion('e-out', 'T', '2026-07-03T09:00:00.000Z'),
    ]);

    const boardId = await persistWizardBoardRows(input([t], new Map([['T', emptyPatch('Read a chapter')]])));

    const forkId = forkTaskId(boardId, 'T');
    const fork = (await db.tasks.get(forkId))!;
    expect(fork.title).toBe('Read a chapter');
    expect(fork.forkedFromTaskId).toBe('T');
    expect(fork.isCompleted).toBe(true);
    expect((await db.tasks.get('T'))!.title).toBe('Read');

    const placed = (await db.boardTasks.where('boardId').equals(boardId).toArray()).filter((p) => !p.isDeleted);
    expect(placed.map((p) => p.taskId)).toEqual([forkId]);
    expect((await db.boardTasks.get('bt-other'))!.taskId).toBe('T');

    const forkEvents = await db.taskEvents.where('taskId').equals(forkId).toArray();
    expect(forkEvents.map((e) => e.id)).toEqual([forkedEventId(forkId, 'e-in')]);
    const created = (await db.boards.get(boardId))!;
    expect(resolveTaskWindowState(fork, forkEvents, created.startDate, created.endDate ?? null).isCompleted).toBe(true);
    expect(created.completedTasks).toBe(1);
  });

  it('edits in place when the task is placed nowhere else', async () => {
    const t = task('T', { title: 'Read' });
    await db.tasks.add(t);

    const boardId = await persistWizardBoardRows(input([t], new Map([['T', emptyPatch('Read more')]])));

    expect((await db.tasks.get('T'))!.title).toBe('Read more');
    expect(await db.tasks.get(forkTaskId(boardId, 'T'))).toBeUndefined();
  });

  it('a compound created in this wizard session is edited in place (nothing else can see it)', async () => {
    const parent = task('P', { title: 'Routine', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const kid = task('K', { title: 'Stretch' });
    const link: CompoundChild = { id: 'lk', compoundTaskId: 'P', childTaskId: 'K', childIndex: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
    const patch: TaskEditPatch = {
      ...emptyPatch('Morning routine'),
      operator: OperatorType.AND,
      children: [{ id: 'K', childTaskId: 'K', title: 'Stretch', isCounting: false, action: '', goal: '', unit: '', countKind: 'discrete', markedDeleted: false, childType: TaskType.NORMAL }],
    };

    const boardId = await persistWizardBoardRows(
      input([parent], new Map([['P', patch]]), {
        pendingTasks: [{ task: parent, childTasks: [kid], childLinks: [link] }],
      }),
    );

    expect((await db.tasks.get('P'))!.title).toBe('Morning routine');
    expect(await db.tasks.get(forkTaskId(boardId, 'P'))).toBeUndefined();
    const placed = (await db.boardTasks.where('boardId').equals(boardId).toArray()).filter((p) => !p.isDeleted);
    expect(placed.map((p) => p.taskId)).toEqual(['P']);
  });

  it('the pool editor path (no board) stays global even for a task placed on a board', async () => {
    await db.tasks.add(task('T', { title: 'Read' }));
    await db.boards.add(otherBoard());
    await db.boardTasks.add(placement('bt-other', OTHER, 'T'));

    await db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], () =>
      applyStagedTaskEditsForWizardPersist(new Map([['T', emptyPatch('Global')]]), new Set(), T0, { strict: true }),
    );

    expect((await db.tasks.get('T'))!.title).toBe('Global');
  });

  it('a sub-task forked inside a compound edit also replaces its own hand-added square', async () => {
    const h = task('H', { title: 'Habits', type: TaskType.COMPOUND, operator: OperatorType.AND });
    const c = task('C', { title: 'Stretch' });
    await db.tasks.bulkAdd([h, c]);
    await db.compoundChildren.add({ id: 'lhc', compoundTaskId: 'H', childTaskId: 'C', childIndex: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false });
    await db.boards.add(otherBoard());
    await db.boardTasks.add(placement('bt-other', OTHER, 'C'));
    const patch: TaskEditPatch = {
      ...emptyPatch('Habits'),
      operator: OperatorType.AND,
      children: [{ id: 'C', childTaskId: 'C', title: 'Stretch 10 min', isCounting: false, action: '', goal: '', unit: '', countKind: 'discrete', markedDeleted: false, childType: TaskType.NORMAL }],
    };

    const boardId = await persistWizardBoardRows(input([h, c], new Map([['H', patch]]), { manualTaskIds: ['H', 'C'] }));

    const cFork = forkTaskId(boardId, 'C');
    expect((await db.tasks.get(cFork))!.title).toBe('Stretch 10 min');
    const placed = (await db.boardTasks.where('boardId').equals(boardId).toArray()).filter((p) => !p.isDeleted);
    expect(placed.map((p) => p.taskId).sort()).toEqual(['H', cFork].sort());
    const links = (await db.compoundChildren.where('compoundTaskId').equals('H').toArray()).filter((l) => !l.isDeleted);
    expect(links.map((l) => l.childTaskId)).toEqual([cFork]);
    expect((await db.boardTasks.get('bt-other'))!.taskId).toBe('C');
  });
});
