import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { CompoundEditValidationError, saveTaskEdit } from '../compoundStructureEdit';
import { newChildPatch, type ChildPatch, type TaskEditPatch } from '../../taskEditPatch';

/**
 * The global editor's type switch (Task Detail / Tasks tab): Simple ⇄
 * Counting and Simple / Counting → Compound through `saveTaskEdit`, the SAME
 * transaction Board Edit's commit uses — global (no fork) and retroactive on
 * every board placing the task. iOS twin: `ApplyTaskEditPatchTypeSwitchTests`.
 */

const USER = 'user-1';
const NOW = new Date('2026-10-08T12:00:00.000Z');
const SEEDED = '2026-10-01T08:00:00.000Z';
const WINDOW = { startDate: '2026-10-05T00:00:00.000Z', endDate: '2026-10-11T23:59:59.999Z' };

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Stretch',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function event(id: string, taskId: string, kind: 'completion' | 'increment', delta?: number): TaskEvent {
  return {
    id, userId: USER, taskId, kind, occurredAt: '2026-10-06T09:00:00.000Z',
    ...(delta !== undefined ? { delta } : {}),
    createdAt: SEEDED, updatedAt: SEEDED, version: 1, isDeleted: false,
  } as TaskEvent;
}

async function place(boardId: string, taskId: string, over: Partial<Board> = {}): Promise<void> {
  const board: Board = {
    id: boardId,
    userId: USER,
    name: boardId,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    ...WINDOW,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 1,
    completedTasks: 1,
    linesCompleted: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
  await db.boards.add(board);
  const bt: BoardTask = {
    id: `bt-${boardId}`, boardId, taskId, row: 0, col: 0, isCenter: false,
    createdAt: SEEDED, updatedAt: SEEDED, version: 1, isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

function sub(title: string): ChildPatch {
  return { ...newChildPatch(false), title };
}

function compoundPatch(children: ChildPatch[]): TaskEditPatch {
  return { title: 'Stretch', action: '', goal: '', unit: '', children, operator: OperatorType.AND };
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
});

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all([
    db.tasks.clear(),
    db.taskEvents.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('saveTaskEdit — type switch (global editor)', () => {
  it('Simple → Counting: counting fields set, old completion inert, caches recomputed, every live board re-derived; sealed board untouched', async () => {
    await db.tasks.add(task('T', { isCompleted: true, completedAt: '2026-10-06T09:00:00.000Z' }));
    await db.taskEvents.add(event('e1', 'T', 'completion'));
    await place('b-live', 'T');
    await place('b-sealed', 'T', { sealedAt: '2026-10-07T12:00:00.000Z', sealedCompletedCells: [0] });

    await saveTaskEdit('T', { type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', unit: 'km', maxCount: 5, countKind: 'discrete' });

    const row = await db.tasks.get('T');
    expect(row).toMatchObject({
      type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, countKind: 'discrete',
      isCompleted: false, currentCount: 0, version: 2,
    });
    expect(row?.completedAt).toBeUndefined();
    // The old completion event survives — inert for a counting task.
    expect(await db.taskEvents.get('e1')).toMatchObject({ isDeleted: false });
    expect((await db.boards.get('b-live'))?.completedTasks).toBe(0);
    // Sealed: excluded from the live fan-out (re-derived on its next deterministic pass).
    expect(await db.boards.get('b-sealed')).toMatchObject({ completedTasks: 1, version: 1 });
    // No fork: the edit is global.
    expect(await db.tasks.count()).toBe(1);
  });

  it('Counting → Simple: counting fields cleared', async () => {
    await db.tasks.add(task('T', {
      type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', unit: 'km', maxCount: 5, currentCount: 2,
    }));
    await db.taskEvents.add(event('e1', 'T', 'increment', 2));
    await place('b-live', 'T', { completedTasks: 0 });

    await saveTaskEdit('T', { type: TaskType.NORMAL, title: 'Run' });

    const row = await db.tasks.get('T');
    expect(row).toMatchObject({ type: TaskType.NORMAL, title: 'Run', isCompleted: false, version: 2 });
    expect(row?.action).toBeUndefined();
    expect(row?.unit).toBeUndefined();
    expect(row?.maxCount).toBeUndefined();
    expect(row?.currentCount).toBeUndefined();
  });

  it('Simple → Compound: the task keeps its id, becomes a compound and links its new sub-tasks', async () => {
    await db.tasks.add(task('T'));
    await place('b-live', 'T');

    await saveTaskEdit('T', { type: TaskType.COMPOUND, title: 'Stretch', compound: compoundPatch([sub('Hamstrings'), sub('Calves')]) });

    expect(await db.tasks.get('T')).toMatchObject({ type: TaskType.COMPOUND, operator: OperatorType.AND, isCompleted: false });
    const links = (await db.compoundChildren.where('compoundTaskId').equals('T').toArray()).filter((l) => !l.isDeleted);
    expect(links).toHaveLength(2);
  });

  it('a compound never switches out', async () => {
    await db.tasks.add(task('C', { type: TaskType.COMPOUND, operator: OperatorType.AND }));
    await expect(saveTaskEdit('C', { type: TaskType.NORMAL, title: 'Plain' })).rejects.toThrow();
    expect(await db.tasks.get('C')).toMatchObject({ type: TaskType.COMPOUND, version: 1 });
  });

  it('a linked counter never changes type', async () => {
    await db.tasks.add(task('R', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 10 }));
    await db.tasks.add(task('L', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, sharedCounterId: 'R' }));
    await expect(saveTaskEdit('L', { type: TaskType.NORMAL, title: 'Run' })).rejects.toBeInstanceOf(CompoundEditValidationError);
    expect(await db.tasks.get('L')).toMatchObject({ type: TaskType.COUNTING, version: 1 });
  });

  it('a counter root with live linked copies never changes type', async () => {
    await db.tasks.add(task('R', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 10 }));
    await db.tasks.add(task('L', { type: TaskType.COUNTING, action: 'Run', unit: 'km', maxCount: 5, sharedCounterId: 'R' }));
    await expect(saveTaskEdit('R', { type: TaskType.NORMAL, title: 'Run' })).rejects.toBeInstanceOf(CompoundEditValidationError);
    expect(await db.tasks.get('R')).toMatchObject({ type: TaskType.COUNTING, version: 1 });
  });

  it('an achievement never changes type', async () => {
    await db.tasks.add(task('A', { type: TaskType.ACHIEVEMENT }));
    await expect(saveTaskEdit('A', { type: TaskType.NORMAL, title: 'Plain' })).rejects.toThrow();
    expect(await db.tasks.get('A')).toMatchObject({ type: TaskType.ACHIEVEMENT, version: 1 });
  });

  it('a submit whose type equals the stored type is an ordinary edit', async () => {
    await db.tasks.add(task('T'));
    await saveTaskEdit('T', { type: TaskType.NORMAL, title: 'Stretch more' });
    expect(await db.tasks.get('T')).toMatchObject({ type: TaskType.NORMAL, title: 'Stretch more', version: 2 });
  });
});
