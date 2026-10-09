import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
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
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import type { BoardEditTaskOverride } from '../../../hooks/squaresEditReducer';
import type { ChildPatch, TaskEditPatch } from '../../taskEditPatch';

/**
 * Board-scoped task edits PR 2 (docs/BOARD_SCOPED_TASK_EDITS.md): a Board
 * Edit "Edit task…" override lands on a FORK when the task is placed on any
 * other board, and on the task itself otherwise. Covers the fork vs in-place
 * test, in-window event migration (a completed square stays completed after
 * a rename), the type-change event filter, compounds (parent-only fork; a
 * renamed sub-task forked + its link repointed; a holder compound placed
 * elsewhere forked first), the dropped override on a replaced square,
 * idempotent replay, and the sealed-board gate. iOS twin:
 * `BoardScopedEditCommitTests`.
 */

const USER = 'user-1';
const T0 = '2026-10-01T00:00:00.000Z';
const NOW = '2026-10-08T12:00:00.000Z';
const B1 = '80000000-0000-4000-8000-0000000000b1'; // the board being edited (weekly)
const B2 = '80000000-0000-4000-8000-0000000000b2'; // another board (monthly)
const B1_START = '2026-10-05T00:00:00.000Z';
const B1_END = '2026-10-11T23:59:59.999Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: USER, title: id, type: TaskType.NORMAL, isCompleted: false,
    totalCompletions: 0, totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}

function board(id: string, startDate: string, endDate: string, over: Partial<Board> = {}): Board {
  return {
    id, userId: USER, name: id, status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
    startDate, endDate, centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9,
    completedTasks: 0, linesCompleted: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  } as Board;
}

function placement(id: string, boardId: string, taskId: string, row = 0, col = 0): BoardTask {
  return { id, boardId, taskId, row, col, isCenter: false, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}

function link(id: string, compoundTaskId: string, childTaskId: string, childIndex: number): CompoundChild {
  return { id, compoundTaskId, childTaskId, childIndex, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}

function event(id: string, taskId: string, kind: 'completion' | 'increment', occurredAt: string, delta?: number): TaskEvent {
  return {
    id, userId: USER, taskId, kind, occurredAt, ...(delta !== undefined ? { delta } : {}),
    createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
  };
}

function cell(o: Partial<SquareDraftCell> & Pick<SquareDraftCell, 'cellId' | 'taskId'>): SquareDraftCell {
  return {
    row: 0, col: 0, isLocked: false, originalTaskId: o.taskId, originalRow: o.row ?? 0,
    originalCol: o.col ?? 0, originalLocked: false, ...o,
  };
}

function input(cells: SquareDraftCell[], overrides: Array<[string, BoardEditTaskOverride]>): CommitSquareEditsInput {
  return {
    boardId: B1, cells, removedBoardTaskIds: [], taskOverrides: new Map(overrides),
    isLegacyChosenOnDisk: false, centerCellKeepLocked: false,
  };
}

function child(over: Partial<ChildPatch>): ChildPatch {
  return {
    id: over.childTaskId ?? 'new', childTaskId: null, title: '', isCounting: false, action: '', goal: '',
    unit: '', countKind: 'discrete', markedDeleted: false, childType: TaskType.NORMAL, ...over,
  };
}

function compoundPatch(title: string, children: ChildPatch[]): TaskEditPatch {
  return { title, action: '', goal: '', unit: '', children, operator: OperatorType.AND };
}

async function syncedIds(entityType: string): Promise<string[]> {
  return (await db.syncQueue.toArray()).filter((i) => i.entityType === entityType).map((i) => i.entityId);
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date(NOW));
  await db.boards.bulkAdd([
    board(B1, B1_START, B1_END),
    board(B2, '2026-10-01T00:00:00.000Z', '2026-10-31T23:59:59.999Z', { timeframe: Timeframe.MONTHLY }),
  ]);
});

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue].map((t) => t.clear()),
  );
});

describe('commitSquareEdits — board-scoped edits', () => {
  it('edits in place when the task is placed only on this board', async () => {
    await db.tasks.add(task('T', { title: 'Read' }));
    await db.boardTasks.add(placement('bt1', B1, 'T'));
    // Pool / library presence is not a placement (D2) — nothing else here.

    await commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'T' })], [['T', { title: 'Read 20 pages' }]]));

    expect((await db.tasks.get('T'))!.title).toBe('Read 20 pages');
    expect(await db.tasks.get(forkTaskId(B1, 'T'))).toBeUndefined();
    expect((await db.boardTasks.get('bt1'))!.taskId).toBe('T');
  });

  it('forks when placed elsewhere: rename lands on the fork, completion is migrated, the other board is untouched', async () => {
    await db.tasks.add(task('T', { title: 'Read', isCompleted: true, completedAt: '2026-10-06T09:00:00.000Z' }));
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'T'), placement('bt2', B2, 'T')]);
    await db.taskEvents.bulkAdd([
      event('e-in', 'T', 'completion', '2026-10-06T09:00:00.000Z'),
      event('e-out', 'T', 'completion', '2026-10-02T09:00:00.000Z'), // B2's window only
    ]);

    await commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'T' })], [['T', { title: 'Read a chapter' }]]));

    const forkId = forkTaskId(B1, 'T');
    const fork = (await db.tasks.get(forkId))!;
    expect(fork.title).toBe('Read a chapter');
    expect(fork.forkedFromTaskId).toBe('T');
    expect(fork.createdInWizard).toBe(true);
    // Lifetime caches stamped from the fork's own (migrated) events.
    expect(fork.isCompleted).toBe(true);
    expect(fork.completedAt).toBe('2026-10-06T09:00:00.000Z');

    const original = (await db.tasks.get('T'))!;
    expect(original.title).toBe('Read');
    expect(original.version).toBe(1);

    expect((await db.boardTasks.get('bt1'))!.taskId).toBe(forkId);
    expect((await db.boardTasks.get('bt2'))!.taskId).toBe('T');

    const forkEvents = await db.taskEvents.where('taskId').equals(forkId).toArray();
    expect(forkEvents.map((e) => e.id)).toEqual([forkedEventId(forkId, 'e-in')]);
    expect(resolveTaskWindowState(fork, forkEvents, B1_START, B1_END).isCompleted).toBe(true);

    const origEvents = await db.taskEvents.where('taskId').equals('T').toArray();
    expect(origEvents).toHaveLength(2);
    const b2 = (await db.boards.get(B2))!;
    expect(resolveTaskWindowState(original, origEvents, b2.startDate, b2.endDate ?? null).isCompleted).toBe(true);
    expect((await db.boards.get(B1))!.completedTasks).toBe(1);

    expect(await syncedIds('tasks')).toContain(forkId);
    expect(await syncedIds('taskEvents')).toContain(forkedEventId(forkId, 'e-in'));
    expect(await syncedIds('boardTasks')).toContain('bt1');
  });

  it('a type change migrates only the events the new type owns (Simple → Counting drops completions)', async () => {
    await db.tasks.add(task('T', { title: 'Run' }));
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'T'), placement('bt2', B2, 'T')]);
    await db.taskEvents.add(event('e1', 'T', 'completion', '2026-10-06T09:00:00.000Z'));

    await commitSquareEdits(
      input([cell({ cellId: 'bt1', taskId: 'T' })], [
        ['T', { title: '', type: TaskType.COUNTING, action: 'Run', maxCount: 5, unit: 'km' }],
      ]),
    );

    const forkId = forkTaskId(B1, 'T');
    const fork = (await db.tasks.get(forkId))!;
    expect(fork.type).toBe(TaskType.COUNTING);
    expect(fork.maxCount).toBe(5);
    expect(fork.isCompleted).toBe(false);
    expect(await db.taskEvents.where('taskId').equals(forkId).count()).toBe(0);
    expect((await db.tasks.get('T'))!.type).toBe(TaskType.NORMAL);
  });

  it('forks a compound parent only — children stay shared through copied links', async () => {
    await db.tasks.bulkAdd([
      task('P', { title: 'Morning', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task('C1', { title: 'Stretch' }),
      task('C2', { title: 'Coffee' }),
    ]);
    await db.compoundChildren.bulkAdd([link('l1', 'P', 'C1', 0), link('l2', 'P', 'C2', 1)]);
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'P'), placement('bt2', B2, 'P')]);

    const patch = compoundPatch('Morning routine', [
      child({ childTaskId: 'C1', title: 'Stretch' }),
      child({ childTaskId: 'C2', title: 'Coffee' }),
    ]);
    await commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'P' })], [['P', { title: 'Morning routine', compound: patch }]]));

    const forkId = forkTaskId(B1, 'P');
    expect((await db.tasks.get(forkId))!.title).toBe('Morning routine');
    expect((await db.tasks.get('P'))!.title).toBe('Morning');
    const forkLinks = (await db.compoundChildren.where('compoundTaskId').equals(forkId).toArray()).filter((l) => !l.isDeleted);
    expect(forkLinks.map((l) => l.childTaskId).sort()).toEqual(['C1', 'C2']);
    const origLinks = (await db.compoundChildren.where('compoundTaskId').equals('P').toArray()).filter((l) => !l.isDeleted);
    expect(origLinks.map((l) => l.childTaskId).sort()).toEqual(['C1', 'C2']);
    expect(await db.tasks.get(forkTaskId(B1, 'C1'))).toBeUndefined();
    expect((await db.boardTasks.get('bt1'))!.taskId).toBe(forkId);
  });

  it('a renamed sub-task placed elsewhere is forked and the parent link repointed (parent edited in place)', async () => {
    await db.tasks.bulkAdd([
      task('P', { title: 'Morning', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task('C1', { title: 'Stretch' }),
      task('C2', { title: 'Coffee' }),
    ]);
    await db.compoundChildren.bulkAdd([link('l1', 'P', 'C1', 0), link('l2', 'P', 'C2', 1)]);
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'P'), placement('bt2', B2, 'C1')]);

    const patch = compoundPatch('Morning', [
      child({ childTaskId: 'C1', title: 'Stretch 10 min' }),
      child({ childTaskId: 'C2', title: 'Coffee' }),
    ]);
    await commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'P' })], [['P', { title: 'Morning', compound: patch }]]));

    const c1Fork = forkTaskId(B1, 'C1');
    expect((await db.tasks.get(c1Fork))!.title).toBe('Stretch 10 min');
    expect((await db.tasks.get('C1'))!.title).toBe('Stretch');
    expect(await db.tasks.get(forkTaskId(B1, 'P'))).toBeUndefined();
    const live = (await db.compoundChildren.where('compoundTaskId').equals('P').toArray()).filter((l) => !l.isDeleted);
    expect(live.map((l) => l.childTaskId).sort()).toEqual(['C2', c1Fork].sort());
    expect((await db.boardTasks.get('bt2'))!.taskId).toBe('C1');
  });

  it('a holder compound on this board that is placed elsewhere is forked first and its copied link repointed', async () => {
    await db.tasks.bulkAdd([
      task('T', { title: 'Walk' }),
      task('H', { title: 'Habits', type: TaskType.COMPOUND, operator: OperatorType.AND }),
      task('X', { title: 'Water' }),
    ]);
    await db.compoundChildren.bulkAdd([link('lh1', 'H', 'T', 0), link('lh2', 'H', 'X', 1)]);
    await db.boardTasks.bulkAdd([
      placement('bt1', B1, 'T'),
      placement('bt1h', B1, 'H', 0, 1),
      placement('bt2h', B2, 'H'),
    ]);

    await commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'T' })], [['T', { title: 'Walk 5k' }]]));

    const tFork = forkTaskId(B1, 'T');
    const hFork = forkTaskId(B1, 'H');
    expect((await db.boardTasks.get('bt1'))!.taskId).toBe(tFork);
    expect((await db.boardTasks.get('bt1h'))!.taskId).toBe(hFork);
    expect((await db.boardTasks.get('bt2h'))!.taskId).toBe('H');
    const hForkLinks = (await db.compoundChildren.where('compoundTaskId').equals(hFork).toArray()).filter((l) => !l.isDeleted);
    expect(hForkLinks.map((l) => l.childTaskId).sort()).toEqual([tFork, 'X'].sort());
    const hLinks = (await db.compoundChildren.where('compoundTaskId').equals('H').toArray()).filter((l) => !l.isDeleted);
    expect(hLinks.map((l) => l.childTaskId).sort()).toEqual(['T', 'X']);
    expect((await db.tasks.get('T'))!.title).toBe('Walk');
  });

  it('drops the override of a square replaced in the same session (no fork, original untouched)', async () => {
    await db.tasks.bulkAdd([task('T', { title: 'Read' }), task('X', { title: 'Other' })]);
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'T'), placement('bt2', B2, 'T')]);

    await commitSquareEdits(
      input([cell({ cellId: 'bt1', taskId: 'X', originalTaskId: 'T' })], [['T', { title: 'Renamed' }]]),
    );

    expect((await db.boardTasks.get('bt1'))!.taskId).toBe('X');
    expect(await db.tasks.get(forkTaskId(B1, 'T'))).toBeUndefined();
    expect((await db.tasks.get('T'))!.title).toBe('Read');
  });

  it('is idempotent: replaying the same commit converges on the same rows', async () => {
    await db.tasks.add(task('T', { title: 'Read' }));
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'T'), placement('bt2', B2, 'T')]);
    await db.taskEvents.add(event('e-in', 'T', 'completion', '2026-10-06T09:00:00.000Z'));
    const commit = () =>
      commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'T' })], [['T', { title: 'Read more' }]]));

    await commit();
    const snapshot = async () => ({
      tasks: (await db.tasks.toArray()).map((t) => t.id).sort(),
      events: (await db.taskEvents.toArray()).map((e) => e.id).sort(),
      placements: (await db.boardTasks.toArray()).map((p) => `${p.id}:${p.taskId}`).sort(),
    });
    const first = await snapshot();
    await commit();
    expect(await snapshot()).toEqual(first);
    expect((await db.tasks.get(forkTaskId(B1, 'T')))!.title).toBe('Read more');
  });

  it('a sealed board never reaches the fork (the Save is refused before any write)', async () => {
    await db.boards.update(B1, { sealedAt: '2026-10-07T00:00:00.000Z' });
    await db.tasks.add(task('T', { title: 'Read' }));
    await db.boardTasks.bulkAdd([placement('bt1', B1, 'T'), placement('bt2', B2, 'T')]);

    await expect(
      commitSquareEdits(input([cell({ cellId: 'bt1', taskId: 'T' })], [['T', { title: 'Renamed' }]])),
    ).rejects.toThrow();
    expect(await db.tasks.get(forkTaskId(B1, 'T'))).toBeUndefined();
    expect((await db.tasks.get('T'))!.title).toBe('Read');
  });
});
