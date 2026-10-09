import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  TaskType,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../db/internal';
import { loadSharedCounterGroups } from '../useSharedCounterGroups';

/**
 * Counter Detail "Tasks on boards" member cards read `member.logged` from
 * `loadSharedCounterGroups`. Every member placed on a board must show its
 * count inside THAT board's window (the play cell's number), never the
 * counter's lifetime total — the lifetime stays on the group (`lifetime`).
 */

const T0 = '2026-09-01T00:00:00.000Z';
// This week's board (open) and last week's (ended).
const W = { id: 'b-w', startDate: '2026-10-05T00:00:00.000', endDate: '2026-10-11T23:59:59.999' };
const E = { id: 'b-e', startDate: '2026-09-28T00:00:00.000', endDate: '2026-10-04T23:59:59.999' };

const counting = (over: Partial<Task>): Task =>
  ({
    userId: 'u1', type: TaskType.COUNTING, action: 'Run', unit: 'miles', countKind: 'discrete',
    isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: T0, updatedAt: T0,
    version: 1, isDeleted: false, ...over,
  }) as Task;

const board = (b: { id: string; startDate: string; endDate: string }, status: BoardStatus): Board =>
  ({
    ...b, userId: 'u1', name: b.id, status, boardSize: 3, timeframe: Timeframe.WEEKLY,
    centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9, completedTasks: 0,
    linesCompleted: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
  }) as Board;

const place = (taskId: string, boardId: string): BoardTask =>
  ({
    id: `bt-${taskId}`, boardId, taskId, row: 0, col: 0, isCenter: false,
    createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
  }) as BoardTask;

const inc = (id: string, taskId: string, delta: number, occurredAt: string): TaskEvent =>
  ({
    id, userId: 'u1', taskId, kind: 'increment', delta, occurredAt,
    createdAt: occurredAt, updatedAt: occurredAt, version: 1, isDeleted: false,
  }) as TaskEvent;

async function seed(rootPlacedOn: string | null): Promise<void> {
  await db.boards.bulkAdd([board(W, BoardStatus.ACTIVE), board(E, BoardStatus.ACTIVE)]);
  await db.tasks.bulkAdd([
    counting({ id: 'root', title: 'Run miles', isCounter: rootPlacedOn == null, currentCount: 10, maxCount: 5 }),
    counting({ id: 'm-w', title: 'Run 4 miles', sharedCounterId: 'root', maxCount: 4, currentCount: 10, baseline: 0 }),
    counting({ id: 'm-e', title: 'Run 8 miles', sharedCounterId: 'root', maxCount: 8, currentCount: 10, baseline: 0 }),
  ]);
  const placements = [place('m-w', W.id), place('m-e', E.id)];
  if (rootPlacedOn) placements.push(place('root', rootPlacedOn));
  await db.boardTasks.bulkAdd(placements);
  // +7 last week (inside E), +3 this week (inside W): lifetime 10.
  await db.taskEvents.bulkAdd([
    inc('e1', 'root', 7, '2026-09-30T12:00:00.000Z'),
    inc('e2', 'root', 3, '2026-10-06T12:00:00.000Z'),
  ]);
}

afterEach(async () => {
  await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear()]);
});

describe('loadSharedCounterGroups — member cards show the in-window count', () => {
  it('hub-born root: each placed member reads its own board window, the total stays lifetime', async () => {
    await seed(null);
    const group = (await loadSharedCounterGroups('u1', true)).find((g) => g.counterId === 'root');
    const logged = Object.fromEntries(group!.tasks.map((t) => [t.taskId, t.logged]));
    expect(group!.lifetime).toBe(10);
    expect(logged['m-w']).toBe(3);
    expect(logged['m-e']).toBe(7);
    // The unplaced hub-born root has no window: its row is the lifetime.
    expect(logged['root']).toBe(10);
    expect(group!.tasks.find((t) => t.taskId === 'm-w')).toMatchObject({ goal: 4, met: false });
  });

  it('board-born root placed on this week’s board shows 3 (its window), not the lifetime 10', async () => {
    await seed(W.id);
    const group = (await loadSharedCounterGroups('u1', true)).find((g) => g.counterId === 'root');
    const rootRow = group!.tasks.find((t) => t.taskId === 'root')!;
    expect(rootRow).toMatchObject({ boardId: W.id, logged: 3, goal: 5, met: false, over: 0 });
    expect(group!.lifetime).toBe(10);
    expect(group!.tasks.find((t) => t.taskId === 'm-e')!.logged).toBe(7);
  });
});
