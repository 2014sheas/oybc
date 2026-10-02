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

/**
 * Shared seeding helpers for the windowed-linked-counter tests (heal sweep,
 * placement choke points, the June/September regression). Hub-linked =
 * `sharedCounterId` set, not window-stamped.
 */

export const USER = 'user-1';
export const T0 = '2026-05-01T00:00:00.000Z';
export const ROOT = 'root-miles';

export const JUNE = {
  id: 'board-june',
  startDate: '2026-06-01T00:00:00.000Z',
  endDate: '2026-06-30T23:59:59.999Z',
};
export const SEPT = {
  id: 'board-sept',
  startDate: '2026-09-01T00:00:00.000Z',
  endDate: '2026-09-30T23:59:59.999Z',
};

export function rootTask(over: Partial<Task> = {}): Task {
  return {
    id: ROOT,
    userId: USER,
    title: 'Run 100 miles',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'miles',
    maxCount: 100,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

/** A hub-linked copy of the root: `sharedCounterId` set, NO window stamp. */
export function hubLinked(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Run 5 miles',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'miles',
    maxCount: 5,
    sharedCounterId: ROOT,
    baseline: 0,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 2,
    isDeleted: false,
    ...over,
  } as Task;
}

export function compoundTask(id: string): Task {
  return {
    id,
    userId: USER,
    title: 'Compound',
    type: TaskType.COMPOUND,
    operator: 'AND',
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  } as unknown as Task;
}

export function boardRow(
  w: { id: string; startDate: string; endDate: string },
  over: Partial<Board> = {},
): Board {
  return {
    id: w.id,
    userId: USER,
    name: w.id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: w.startDate,
    endDate: w.endDate,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
    ...over,
  } as Board;
}

export function placement(id: string, boardId: string, taskId: string, row = 0, col = 0): BoardTask {
  return {
    id,
    boardId,
    taskId,
    row,
    col,
    isCenter: false,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };
}

export function link(id: string, compoundTaskId: string, childTaskId: string): CompoundChild {
  return {
    id,
    compoundTaskId,
    childTaskId,
    childIndex: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  } as CompoundChild;
}

export function incEvent(id: string, taskId: string, delta: number, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

export async function clearAll(): Promise<void> {
  await Promise.all([
    db.tasks.clear(),
    db.taskEvents.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
    db.users.clear(),
  ]);
}

export async function queued(entityType: string): Promise<string[]> {
  return (await db.syncQueue.toArray()).filter((i) => i.entityType === entityType).map((i) => i.entityId);
}
