import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  BoardSize,
  CenterSquareType,
  OperatorType,
  SyncOperationType,
  TaskType,
  Timeframe,
  SYNC_COLLECTIONS,
  type Board,
  type BoardTask,
  type CompositeNode,
  type CompositeTask,
  type CompoundChild,
  type CoreBoardDefault,
  type DefaultPool,
  type Pool,
  type RecurringBoardTemplate,
  type SyncableEntity,
  type SyncCollection,
  type Task,
  type TaskEvent,
  type TaskStep,
} from '@oybc/shared';
import { db } from '../../internal';
import { applyRemoteSubdoc, rowsGenuinelyDiffer } from '../pullApply';

/**
 * Cross-platform review finding C1 (P1 final fix wave,
 * docs/POOLS_RECURRING.md): `applyRemoteSubdoc` upserted into
 * `db.table(collectionName)` inside a Dexie transaction whose scope list
 * didn't include that table for every collection (only a hardcoded subset).
 * Dexie throws `NotFoundError` for a table referenced inside a transaction
 * but not declared in its scope, which silently dropped every pulled doc
 * for the un-scoped collections (`pools`, `coreBoardDefaults`, and the
 * pre-existing `recurringBoardTemplates` / `defaultPools`) AND wedged the
 * global pull watermark forever (`pullSync`'s per-collection catch sets
 * `hadPullError`).
 *
 * This is a data-driven regression test: for every LIVE collection in
 * `SYNC_COLLECTIONS` (not a hand-picked subset), a minimal valid remote doc
 * must round-trip through `applyRemoteSubdoc` and land in the matching
 * Dexie table. Looping the full shared collection list (rather than
 * copy-pasting one test per collection) means a future collection addition
 * is covered automatically — the whole point of the fix is "every
 * collection", so the test must assert that, not just the ones broken
 * today.
 *
 * `taskSteps` / `compositeTasks` / `compositeNodes` are excluded from the
 * loop: their Dexie tables were DROPPED (`null`'d) in the Compound Tasks
 * Unification migration (`database.ts` v4) — no live table exists to land
 * a doc in, and `pullSync`/`attachPullListeners` never call
 * `applyRemoteSubdoc` for them in production (`LEGACY_PULL_SKIP_COLLECTIONS`
 * short-circuits before the call). `defaultPools` joined that same skip set
 * in P1 but its Dexie table is still live (kept for migration backfill
 * reads), so it stays in the loop as a defense-in-depth check on the
 * transaction-scope fix itself.
 */

const DROPPED_TABLES: ReadonlySet<SyncCollection> = new Set([
  'taskSteps',
  'compositeTasks',
  'compositeNodes',
]);

const LIVE_SYNC_COLLECTIONS = SYNC_COLLECTIONS.filter((c) => !DROPPED_TABLES.has(c));

const USER = 'user-1';
const NOW = '2026-07-19T00:00:00.000Z';

function uuid(n: number): string {
  return `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

afterEach(async () => {
  await Promise.all([
    ...LIVE_SYNC_COLLECTIONS.map((c) => db.table(c).clear()),
    // Item 1 (board-integrity PR-4) tests below assert on sync-queue
    // contents; `syncQueue` isn't a SYNC_COLLECTIONS table so it's cleared
    // separately here to keep every test's queue assertions isolated.
    db.syncQueue.clear(),
  ]);
});

/**
 * Builds a minimal, schema-valid remote doc for each syncable collection,
 * plus any DB seeding a given collection's `applyRemoteSubdoc` cross-checks
 * require (e.g. `compoundChildren` looks up its parent Task locally).
 */
const FIXTURES: Record<
  SyncCollection,
  { seed?: () => Promise<void>; doc: () => unknown }
> = {
  boards: {
    doc: (): Board => ({
      id: uuid(1),
      userId: USER,
      name: 'Board',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.MONTHLY,
      startDate: NOW,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 0,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  tasks: {
    doc: (): Task => ({
      id: uuid(2),
      userId: USER,
      title: 'Task',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  taskSteps: {
    doc: (): TaskStep => ({
      id: uuid(3),
      taskId: uuid(2),
      stepIndex: 0,
      title: 'Step',
      type: TaskType.NORMAL,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  boardTasks: {
    doc: (): BoardTask => ({
      id: uuid(4),
      boardId: uuid(1),
      taskId: uuid(2),
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  compositeTasks: {
    doc: (): CompositeTask => ({
      id: uuid(5),
      userId: USER,
      title: 'Composite',
      rootNodeId: uuid(6),
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  compositeNodes: {
    doc: (): CompositeNode => ({
      id: uuid(6),
      compositeTaskId: uuid(5),
      nodeIndex: 0,
      nodeType: 'operator',
      operatorType: OperatorType.AND,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  compoundChildren: {
    // The parent-lookup check in `applyRemoteSubdoc` requires the parent
    // compound Task to already exist locally with a matching userId.
    seed: async () => {
      const parent: Task = {
        id: uuid(7),
        userId: USER,
        title: 'Compound parent',
        type: TaskType.COMPOUND,
        operator: OperatorType.AND,
        isCompleted: false,
        totalCompletions: 0,
        totalInstances: 0,
        createdAt: NOW,
        updatedAt: NOW,
        version: 1,
        isDeleted: false,
      };
      await db.tasks.add(parent);
    },
    doc: (): CompoundChild => ({
      id: uuid(8),
      compoundTaskId: uuid(7),
      childTaskId: uuid(2),
      childIndex: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  recurringBoardTemplates: {
    doc: (): RecurringBoardTemplate => ({
      id: uuid(9),
      userId: USER,
      name: 'Template',
      timeframe: Timeframe.DAILY,
      boardSize: 3 as BoardSize,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      seedTaskIds: [],
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  defaultPools: {
    doc: (): DefaultPool => ({
      id: uuid(10),
      userId: USER,
      timeframe: Timeframe.DAILY,
      taskIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  taskEvents: {
    doc: (): TaskEvent => ({
      id: uuid(11),
      userId: USER,
      taskId: uuid(2),
      kind: 'completion',
      occurredAt: NOW,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  pools: {
    doc: (): Pool => ({
      id: uuid(12),
      userId: USER,
      name: 'Pool',
      taskIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
  coreBoardDefaults: {
    doc: (): CoreBoardDefault => ({
      id: uuid(13),
      userId: USER,
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    }),
  },
};

describe('applyRemoteSubdoc — every SYNC_COLLECTIONS entry round-trips (C1 regression)', () => {
  for (const collectionName of LIVE_SYNC_COLLECTIONS) {
    it(`lands a minimal valid ${collectionName} doc in its Dexie table`, async () => {
      const fixture = FIXTURES[collectionName];
      if (fixture.seed) {
        await fixture.seed();
      }
      const doc = fixture.doc();

      const status = await applyRemoteSubdoc(collectionName, doc, USER);

      expect(status).toMatch(/^Pulled /);
      const stored = await db.table(collectionName).get((doc as { id: string }).id);
      expect(stored).toBeDefined();
      expect((stored as { id: string }).id).toBe((doc as { id: string }).id);
    });
  }
});

/**
 * Item 1 (bingo-pipeline hardening) — sealed-board pull re-derive transport
 * convergence hole. `reDeriveSealedBoards(ForTasks)` previously fired only
 * from the taskEvents-pull batch; a pulled `boards` doc was applied verbatim,
 * so a stale sealed snapshot from another device (sealed offline with a
 * partial event union) would stick locally — and since sealed re-derivation
 * never bumps `version`/enqueues, the remote copy stayed stale for every
 * future puller too. The fix: `applyRemoteSubdoc`'s `boards` branch now
 * re-derives any pulled SEALED doc against the LOCAL converged event union,
 * inside the same pull transaction.
 */
describe('applyRemoteSubdoc — sealed-board pull re-derive (item 1)', () => {
  const TASK = '40000000-0000-4000-8000-000000000001';
  const BOARD = '20000000-0000-4000-8000-000000000099';
  const START = '2026-07-01T00:00:00.000Z';
  const SEALED_AT = '2026-07-02T06:00:00.000Z';
  const IN_WINDOW = '2026-07-01T12:00:00.000Z';

  it('corrects a stale pulled sealed snapshot from the local event union, without bumping version or enqueuing sync', async () => {
    // Local device: the task has a completion event squarely inside the
    // window, so the LOCAL converged union says cell 0 is green.
    const task: Task = {
      id: TASK,
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
    await db.taskEvents.add({
      id: 'ev-local-1',
      userId: USER,
      taskId: TASK,
      kind: 'completion',
      occurredAt: IN_WINDOW,
      createdAt: IN_WINDOW,
      updatedAt: IN_WINDOW,
      version: 1,
      isDeleted: false,
    } as TaskEvent);

    // Local board is already sealed correctly (grey→green from the local
    // union) at version 1.
    const localSealed: Board = {
      id: BOARD,
      userId: USER,
      name: 'B',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 1,
      linesCompleted: 0,
      completedLineIds: [],
      sealedAt: SEALED_AT,
      sealedCompletedCells: [0],
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.boards.add(localSealed);
    const localBoardTask: BoardTask = {
      id: 'bt-1',
      boardId: BOARD,
      taskId: TASK,
      row: 0,
      col: 0,
      isCenter: false,
      createdAt: START,
      updatedAt: START,
      version: 1,
      isDeleted: false,
    };
    await db.boardTasks.add(localBoardTask);

    // A remote device sealed offline BEFORE the event above had synced to
    // it, so its pulled snapshot claims cell 0 is still incomplete — and it
    // carries a higher version, so LWW picks the remote row.
    const staleRemote: Board = {
      ...localSealed,
      completedTasks: 0,
      completedLineIds: [],
      sealedCompletedCells: [],
      version: 2,
      updatedAt: SEALED_AT,
    };

    const status = await applyRemoteSubdoc('boards', staleRemote, USER);
    expect(status).toMatch(/^Pulled /);

    const board = await db.boards.get(BOARD);
    // The LWW-applied row's version is whatever the pulled doc carried...
    expect(board?.version).toBe(2);
    // ...but the snapshot was corrected in-place from the LOCAL union —
    // re-derivation does NOT bump the version any further, and it doesn't
    // enqueue a sync entry (pull paths don't author writes).
    expect(board?.completedTasks).toBe(1);
    expect(board?.sealedCompletedCells).toEqual([0]);

    const boardSyncEntries = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'boards' && i.entityId === BOARD,
    );
    expect(boardSyncEntries).toHaveLength(0);
  });

  it('leaves a non-sealed pulled board doc untouched by the re-derive hook', async () => {
    const liveBoard: Board = {
      id: BOARD,
      userId: USER,
      name: 'B',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      timeframe: Timeframe.DAILY,
      startDate: START,
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
      totalTasks: 9,
      completedTasks: 3,
      linesCompleted: 0,
      completedLineIds: [],
      createdAt: START,
      updatedAt: START,
      version: 2,
      isDeleted: false,
    };

    const status = await applyRemoteSubdoc('boards', liveBoard, USER);
    expect(status).toMatch(/^Pulled /);

    const board = await db.boards.get(BOARD);
    expect(board?.completedTasks).toBe(3);
    expect(board?.sealedAt).toBeUndefined();
  });
});

/**
 * Item 1 (board-integrity PR-4, docs/BOARD_INTEGRITY.md): the push path
 * conflict-checks via getDoc → setDoc with no transaction, so a stale write
 * can land AFTER a fresher one on a cross-device race. Before this fix,
 * "local wins" on pull was a silent no-op — nothing ever re-pushed the
 * fresher local row, so the divergence stuck forever. The fix: re-enqueue an
 * UPDATE for the local row whenever pull resolves local-wins AND the rows
 * genuinely differ (loop guard — an already-converged pull must never
 * enqueue, or every sync of an in-sync doc would loop).
 */
describe('applyRemoteSubdoc — local-wins re-enqueue (item 1)', () => {
  const TASK = '50000000-0000-4000-8000-000000000001';
  const OLD = '2026-07-01T00:00:00.000Z';
  const NEWER = '2026-07-02T00:00:00.000Z';

  function localTask(overrides: Partial<Task> = {}): Task {
    return {
      id: TASK,
      userId: USER,
      title: 'Local task',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: OLD,
      updatedAt: NEWER,
      version: 2,
      isDeleted: false,
      ...overrides,
    };
  }

  it('enqueues an UPDATE for the local row when pull resolves local-wins (higher local version)', async () => {
    const local = localTask({ version: 2, updatedAt: NEWER });
    await db.tasks.add(local);

    // Remote is stale — lower version. resolveConflict picks local.
    const remote: Task = { ...local, title: 'Stale remote', version: 1, updatedAt: OLD };

    const status = await applyRemoteSubdoc('tasks', remote, USER);
    expect(status).toBeNull();

    // Local row is untouched (local-wins never writes it).
    const stored = await db.tasks.get(TASK);
    expect(stored?.version).toBe(2);
    expect(stored?.title).toBe('Local task');

    const entries = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'tasks' && i.entityId === TASK,
    );
    expect(entries).toHaveLength(1);
    expect(entries[0].operationType).toBe(SyncOperationType.UPDATE);
    const payload = JSON.parse(entries[0].payload) as Task;
    expect(payload.version).toBe(2);
    expect(payload.title).toBe('Local task');
  });

  it('enqueues an UPDATE for the local row when pull resolves local-wins (same version, newer local updatedAt)', async () => {
    const local = localTask({ version: 3, updatedAt: NEWER });
    await db.tasks.add(local);

    // Same version, older updatedAt — resolveConflict still picks local.
    const remote: Task = { ...local, title: 'Stale remote', version: 3, updatedAt: OLD };

    const status = await applyRemoteSubdoc('tasks', remote, USER);
    expect(status).toBeNull();

    const entries = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'tasks' && i.entityId === TASK,
    );
    expect(entries).toHaveLength(1);
    expect(entries[0].operationType).toBe(SyncOperationType.UPDATE);
  });

  it('does NOT enqueue when remote wins (higher remote version)', async () => {
    const local = localTask({ version: 1, updatedAt: OLD });
    await db.tasks.add(local);

    const remote: Task = { ...local, title: 'Fresh remote', version: 2, updatedAt: NEWER };

    const status = await applyRemoteSubdoc('tasks', remote, USER);
    expect(status).toMatch(/^Pulled /);

    const entries = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'tasks' && i.entityId === TASK,
    );
    expect(entries).toHaveLength(0);
  });

  it('does NOT enqueue when the pulled row is brand new locally (isNew branch)', async () => {
    const remote = localTask({ version: 1, updatedAt: OLD });

    const status = await applyRemoteSubdoc('tasks', remote, USER);
    expect(status).toMatch(/^Pulled .*\(new\)/);

    const entries = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'tasks' && i.entityId === TASK,
    );
    expect(entries).toHaveLength(0);
  });

  it('does NOT enqueue when the pulled row is identical (tie → remote-wins through the public API)', async () => {
    const local = localTask({ version: 2, updatedAt: NEWER });
    await db.tasks.add(local);
    const identicalRemote: Task = { ...local };

    // Sanity: resolveConflict on an identical pair resolves remote-wins
    // (exact tie → server authority), so this exercises the remote-wins
    // branch, not local-wins — confirming no enqueue happens either way.
    const status = await applyRemoteSubdoc('tasks', identicalRemote, USER);
    expect(status).toMatch(/^Pulled /);

    const entries = (await db.syncQueue.toArray()).filter(
      (i) => i.entityType === 'tasks' && i.entityId === TASK,
    );
    expect(entries).toHaveLength(0);
  });

  describe('rowsGenuinelyDiffer (loop-guard predicate, unit)', () => {
    // `Task` doesn't structurally satisfy `SyncableEntity`'s index signature
    // (same as `applyRemoteSubdoc`'s own `validated as SyncableEntity` cast
    // above) — cast through `unknown`, matching that convention.
    function asSyncable(task: Task): SyncableEntity {
      return task as unknown as SyncableEntity;
    }

    it('returns false for identical version + updatedAt — the actual loop-guard case', () => {
      const local = localTask({ version: 2, updatedAt: NEWER });
      const remote = { ...local };
      expect(rowsGenuinelyDiffer(asSyncable(local), asSyncable(remote))).toBe(false);
    });

    it('returns true when versions differ', () => {
      const local = localTask({ version: 2, updatedAt: NEWER });
      const remote = { ...local, version: 1 };
      expect(rowsGenuinelyDiffer(asSyncable(local), asSyncable(remote))).toBe(true);
    });

    it('returns true when versions match but updatedAt differs', () => {
      const local = localTask({ version: 2, updatedAt: NEWER });
      const remote = { ...local, updatedAt: OLD };
      expect(rowsGenuinelyDiffer(asSyncable(local), asSyncable(remote))).toBe(true);
    });
  });
});
