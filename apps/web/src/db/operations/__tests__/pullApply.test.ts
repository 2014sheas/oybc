import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  BoardSize,
  CenterSquareType,
  OperatorType,
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
  type SyncCollection,
  type Task,
  type TaskEvent,
  type TaskStep,
} from '@oybc/shared';
import { db } from '../../internal';
import { applyRemoteSubdoc } from '../pullApply';

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
  await Promise.all(
    LIVE_SYNC_COLLECTIONS.map((c) => db.table(c).clear()),
  );
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
