import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  SyncStatus,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { addToSyncQueue, setSyncQueueOwnerProvider } from '../syncQueue';
import { applyRemoteSubdoc } from '../pullApply';
import { applyTaskEventsBatch, healMissingCompletionEvents } from '../taskEventPull';

/**
 * docs/GUEST_MODE.md §Collision, fix round 1 — sync-internal enqueues are
 * owned by the uid the PULL runs for, never the live auth uid. During the
 * collision switch an anon snapshot applied after `signIn` resolves (and
 * after the queue clear) must re-enqueue as anon-owned so the real account's
 * push drops it. Simulated here by a pull for `ANON` while the live-auth
 * provider already returns `REAL`.
 */
const ANON = 'anon-uid';
const REAL = 'real-uid';
const START = '2026-05-01T00:00:00.000Z';
const OLD = '2026-07-01T00:00:00.000Z';
const NEWER = '2026-07-02T00:00:00.000Z';
const TASK = '60000000-0000-4000-8000-000000000001';
const BOARD = '60000000-0000-4000-8000-000000000002';

function task(overrides: Partial<Task> = {}): Task {
  return {
    id: TASK,
    userId: ANON,
    title: 'Anon task',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

async function seedBoardPlacing(taskId: string): Promise<void> {
  const board: Board = {
    id: BOARD,
    userId: ANON,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: START,
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
  };
  const bt: BoardTask = {
    id: `bt-${taskId}`,
    boardId: BOARD,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: START,
    updatedAt: START,
    version: 1,
    isDeleted: false,
  };
  await db.boards.add(board);
  await db.boardTasks.add(bt);
}

beforeEach(() => {
  // Live auth has already flipped to the real account.
  setSyncQueueOwnerProvider(() => REAL);
});

afterEach(async () => {
  setSyncQueueOwnerProvider(() => null);
  await Promise.all([
    db.tasks.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.taskEvents.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('sync-internal enqueues are owned by the pull uid, not the live uid', () => {
  it('a pull local-wins re-assert for ANON, applied while live auth is REAL, is ANON-owned', async () => {
    const local = task({ version: 2, updatedAt: NEWER });
    await db.tasks.add(local);
    const staleRemote: Task = { ...local, title: 'Stale remote', version: 1, updatedAt: OLD };

    expect(await applyRemoteSubdoc('tasks', staleRemote, ANON)).toBeNull();

    const rows = await db.syncQueue.toArray();
    expect(rows.map((r) => [r.entityType, r.ownerUid])).toEqual([['tasks', ANON]]);
  });

  it('a heal mint + its board cascade for ANON, run while live auth is REAL, are all ANON-owned', async () => {
    await db.tasks.add(task({ isCompleted: true, completedAt: '2026-05-10T08:00:00.000Z' }));
    await seedBoardPlacing(TASK);

    expect(await healMissingCompletionEvents(ANON)).toBe(1);

    const rows = await db.syncQueue.toArray();
    const types = rows.map((r) => r.entityType).sort();
    expect(types).toEqual(expect.arrayContaining(['boards', 'taskEvents']));
    expect(new Set(rows.map((r) => r.ownerUid))).toEqual(new Set([ANON]));
  });

  it('a remote-win pulled task for ANON reaching the board cascade, while live auth is REAL, leaves only ANON-owned rows', async () => {
    await db.tasks.add(task());
    await seedBoardPlacing(TASK);
    await db.syncQueue.clear(); // only the pull's enqueues are asserted

    // Remote completes the task at a higher version → remote wins → cascade.
    const remote: Task = { ...task(), isCompleted: true, version: 2, updatedAt: NEWER };
    expect(await applyRemoteSubdoc('tasks', remote, ANON)).toContain('Pulled tasks/');

    const rows = await db.syncQueue.toArray();
    expect(rows.map((r) => r.entityType)).toContain('boards');
    expect(new Set(rows.map((r) => r.ownerUid))).toEqual(new Set([ANON]));
  });

  it('a pulled taskEvents batch for ANON reaching the board cascade, while live auth is REAL, leaves only ANON-owned rows', async () => {
    await db.tasks.add(task());
    await seedBoardPlacing(TASK);
    await db.syncQueue.clear();

    const event: TaskEvent = {
      id: '60000000-0000-4000-8000-000000000003',
      userId: ANON,
      taskId: TASK,
      kind: 'completion',
      occurredAt: '2026-06-01T00:00:00.000Z',
      createdAt: '2026-06-01T00:00:00.000Z',
      updatedAt: '2026-06-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    expect((await applyTaskEventsBatch(ANON, [event])).pulled).toBe(1);

    const rows = await db.syncQueue.toArray();
    expect(rows.map((r) => r.entityType)).toContain('boards');
    expect(new Set(rows.map((r) => r.ownerUid))).toEqual(new Set([ANON]));
  });

  it('a user write outside a sync-owned transaction still takes the live uid', async () => {
    await addToSyncQueue('tasks', TASK, SyncOperationType.UPDATE, task());

    const [row] = await db.syncQueue.toArray();
    expect(row.ownerUid).toBe(REAL);
  });
});

describe('legacy null-owner row adoption (web twin of iOS test_legacyRow_isAdoptedAndRestampedByStampedOp)', () => {
  it('a stamped enqueue coalesces into a legacy unstamped PENDING row and re-stamps it', async () => {
    await db.syncQueue.add({
      id: '60000000-0000-4000-8000-0000000000aa',
      entityType: 'tasks',
      entityId: TASK,
      operationType: SyncOperationType.CREATE,
      payload: JSON.stringify(task()),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: START,
      priority: 0,
    });

    await addToSyncQueue('tasks', TASK, SyncOperationType.UPDATE, task({ version: 2 }));

    const rows = await db.syncQueue.toArray();
    expect(rows).toHaveLength(1);
    expect(rows[0].ownerUid).toBe(REAL);
    expect(rows[0].operationType).toBe(SyncOperationType.CREATE); // coalesced, kept position
  });
});
