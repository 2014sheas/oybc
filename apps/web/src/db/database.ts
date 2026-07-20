import Dexie, { Table } from 'dexie';
import type {
  Board,
  Task,
  TaskEvent,
  TaskStep,
  BoardTask,
  User,
  SyncQueueItem,
  CompositeTask,
  CompositeNode,
  CompoundChild,
  RecurringBoardTemplate,
  DefaultPool,
  Pool,
  CoreBoardDefault,
} from '@oybc/shared';

/**
 * AppDatabase - Main Dexie database instance
 *
 * Offline-first IndexedDB database matching GRDB iOS implementation
 */
export class AppDatabase extends Dexie {
  // Tables
  users!: Table<User, string>;
  boards!: Table<Board, string>;
  tasks!: Table<Task, string>;
  taskSteps!: Table<TaskStep, string>;
  boardTasks!: Table<BoardTask, string>;
  syncQueue!: Table<SyncQueueItem, string>;
  compositeTasks!: Table<CompositeTask, string>;
  compositeNodes!: Table<CompositeNode, string>;
  compoundChildren!: Table<CompoundChild, string>;
  recurringBoardTemplates!: Table<RecurringBoardTemplate, string>;
  defaultPools!: Table<DefaultPool, string>;
  taskEvents!: Table<TaskEvent, string>;
  pools!: Table<Pool, string>;
  coreBoardDefaults!: Table<CoreBoardDefault, string>;

  constructor() {
    super('oybc');

    // Define schema with indexes
    this.version(1).stores({
      // Users table
      users: 'id, email, updatedAt',

      // Boards table
      boards: `
        id,
        [userId+isDeleted],
        [userId+timeframe+status],
        [userId+timeframe+linesCompleted],
        updatedAt,
        status
      `,

      // Tasks table
      tasks: `
        id,
        [userId+isDeleted],
        updatedAt,
        type,
        parentStepId
      `,

      // TaskSteps table
      taskSteps: `
        id,
        [taskId+stepIndex],
        linkedTaskId,
        [isDeleted+taskId]
      `,

      // BoardTasks junction table.
      // v1 declared `[boardId+isCompleted]` and the `isAchievementSquare`
      // / `[isAchievementSquare+achievementTimeframe]` indexes — both
      // dropped at v7 once their underlying fields stopped existing on
      // BoardTask. The string is preserved here so legacy on-disk
      // databases match the originally-declared schema; Dexie diffs the
      // declared schema across versions to migrate.
      // NOTE: indexes below marked /* legacy */ are intentionally kept
      // here as the v1 baseline; live queries don't use them. v7 drops
      // them from the actual schema (see further down).
      boardTasks: `
        id,
        [boardId+isCompleted],
        boardId,
        taskId,
        isAchievementSquare,
        [isAchievementSquare+achievementTimeframe]
      `,

      // SyncQueue table
      syncQueue: `
        id,
        [status+priority+createdAt],
        [entityType+entityId]
      `,
    });

    // v2: Add composite task tables
    this.version(2).stores({
      // CompositeTasks table
      compositeTasks: `
        id,
        [userId+isDeleted],
        updatedAt
      `,

      // CompositeNodes table
      compositeNodes: `
        id,
        compositeTaskId,
        [compositeTaskId+isDeleted],
        parentNodeId,
        taskId
      `,
    });

    // v3: Add childCompositeTaskId index to compositeNodes
    this.version(3).stores({
      // Only the changed table needs to be specified
      compositeNodes: `
        id,
        compositeTaskId,
        [compositeTaskId+isDeleted],
        parentNodeId,
        taskId,
        childCompositeTaskId
      `,
    });

    // v4: Add compoundChildren table for the unified compound model.
    // Replaces task_steps + composite_nodes (legacy stores remain in place
    // until v5 — Task 2.6 — drops them after Task 2.5's data migration).
    this.version(4)
      .stores({
        compoundChildren: `
          id,
          compoundTaskId,
          childTaskId,
          [compoundTaskId+childIndex]
        `,
      })
      .upgrade((tx) => {
        // Dynamic import avoids a top-of-file circular reference:
        // migrationV4.ts imports `db` from this file, so a static import here
        // would create a cycle. Dexie resolves the Promise before the upgrade
        // transaction commits, so atomicity is preserved.
        return import('./operations/migrationV4').then((mod) =>
          mod.runMigrationV4(tx)
        );
      });

    // v5: Drop legacy stores. The v4 upgrade callback already migrated their
    // rows into `tasks` + `compoundChildren`. Class field declarations for
    // `taskSteps`, `compositeTasks`, `compositeNodes` remain so migrationV4.ts
    // still compiles — Phase 8 cleanup removes them along with the migration
    // code itself once we're past the transition window.
    this.version(5).stores({
      taskSteps: null,
      compositeTasks: null,
      compositeNodes: null,
    });

    // v6: Phase 6.2 — recurring board templates. New table; `Board` gains
    // an `spawnedFromTemplateId` column on the type level (additive,
    // optional, no IndexedDB schema change needed because Dexie stores
    // the full Board object verbatim — only INDEX columns appear in
    // `.stores()`. Add an index on `spawnedFromTemplateId` later if a
    // query pattern requires it).
    this.version(6).stores({
      recurringBoardTemplates: `
        id,
        [userId+isActive],
        [userId+isDeleted],
        updatedAt
      `,
    });

    // v7: Phase 6.3 — ACHIEVEMENT-as-TaskType. Achievement-square config
    // moved from `BoardTask` to `Task` (a new `TaskType.ACHIEVEMENT` task
    // type with `referencedBoardId` / `referencedTemplateId` fields).
    //
    // `boardTasks` is now a pure placement table — the pre-unification
    // `[boardId+isCompleted]` index (over a field that no longer exists)
    // and the never-shipped `isAchievementSquare` /
    // `[isAchievementSquare+achievementTimeframe]` indexes are all
    // dropped here, leaving only the FK lookups (`boardId`, `taskId`).
    // The new `Task` reference fields are intentionally NOT indexed
    // (lookups happen per-row inside `derivationPass`, not as table-wide
    // scans). Dexie stores the full object verbatim, so the new
    // optional `Task` fields ride along automatically.
    this.version(7).stores({
      boardTasks: `
        id,
        boardId,
        taskId
      `,
    });

    // v8: Phase 6.X — Default Pools. A new `defaultPools` table holding
    // one pool per `(userId, timeframe)`. Index `[userId+timeframe]` so
    // the wizard's prefill path can do a single-row lookup; `id` is the
    // primary key for sync push/pull; `updatedAt` indexed for ordered
    // reads in any future "recently edited" UI. Uniqueness is enforced
    // client-side (no DB constraint) — the CRUD layer's `upsertDefaultPool`
    // call queries by the index first and creates-or-updates accordingly.
    this.version(8).stores({
      defaultPools: `
        id,
        [userId+timeframe],
        [userId+isDeleted],
        updatedAt
      `,
    });

    // v9: Phase 6.Y — Timeboxed Tasks. Adds 3 optional fields to Task
    // (timeframe / startDate / endDate) and BACKFILLS them from the
    // task's most-recently-updated non-deleted BoardTask placement.
    // Dexie's `.stores({})` is a no-op shape change (no new indexes
    // needed — these fields are unindexed); the schema bump is just
    // a vehicle for the `.upgrade()` callback.
    //
    // Backfill rule: for each non-deleted task with no `endDate`
    // (i.e., not already timeboxed), find the latest BoardTask whose
    // Board is non-deleted, then set the task's `timeframe`,
    // `startDate`, `endDate` from that Board. Tasks with zero
    // placements stay indefinite. Bumps `version + updatedAt` so the
    // change syncs to remote peers (where each peer will run its
    // own migration on first launch — duplicate writes coalesce via
    // LWW because the timestamps are identical-or-close).
    this.version(9).stores({}).upgrade(async (tx) => {
      const tasksTable = tx.table('tasks');
      const boardTasksTable = tx.table('boardTasks');
      const boardsTable = tx.table('boards');

      const allTasks = await tasksTable.toArray();
      const allBoardTasks = await boardTasksTable.toArray();
      const allBoards = await boardsTable.toArray();
      const boardById = new Map(allBoards.map((b: { id: string }) => [b.id, b]));

      // Group BoardTasks by taskId; sort each group by updatedAt desc.
      const btsByTaskId = new Map<string, typeof allBoardTasks>();
      for (const bt of allBoardTasks) {
        const list = btsByTaskId.get(bt.taskId) ?? [];
        list.push(bt);
        btsByTaskId.set(bt.taskId, list);
      }

      const now = new Date().toISOString();
      for (const task of allTasks) {
        if (task.isDeleted) continue;
        if (task.endDate) continue; // already timeboxed (somehow)

        const candidates = btsByTaskId.get(task.id) ?? [];
        if (candidates.length === 0) continue; // no placements → indefinite

        // Pick the most-recently-updated BoardTask whose Board is alive.
        let chosen: typeof allBoardTasks[number] | undefined;
        let chosenBoard: { timeframe: string; startDate: string; endDate: string } | undefined;
        let chosenUpdatedAt = '';
        for (const bt of candidates) {
          const board = boardById.get(bt.boardId) as
            | { timeframe: string; startDate: string; endDate: string; isDeleted: boolean }
            | undefined;
          if (!board || board.isDeleted) continue;
          const u = (bt.updatedAt as string | undefined) ?? '';
          if (u >= chosenUpdatedAt) {
            chosen = bt;
            chosenBoard = board;
            chosenUpdatedAt = u;
          }
        }
        if (!chosen || !chosenBoard) continue;

        await tasksTable.update(task.id, {
          timeframe: chosenBoard.timeframe,
          startDate: chosenBoard.startDate,
          endDate: chosenBoard.endDate,
          updatedAt: now,
          version: (task.version ?? 0) + 1,
        });
      }
    });

    // v10: Phase 2 — Shared Counters. Adds `sharedCounterId` (TEXT) and
    // `baseline` (INTEGER) to `tasks`. Both are optional (null for
    // non-linked tasks). No new indexes needed — source lookups happen
    // via JS filter over small-N linked tasks. Dexie stores the full
    // Task object verbatim, so new optional fields forward-compat without
    // a migration callback; the version bump documents the schema change.
    this.version(10).stores({});

    // v11: Phase 4 — Shared Counter Sync. Adds `lastSyncedCount` (INTEGER)
    // to `tasks`. This is the common-ancestor value used by the additive-merge
    // conflict resolver in syncService.ts to detect concurrent increments on
    // shared-counter source tasks.
    //
    // Adds `sharedCounterId` to the `tasks` index spec so that
    // `db.tasks.where('sharedCounterId').equals(sourceTaskId)` (used in
    // applyRemoteSubdoc and syncService.ts:~540) does not throw "Index not
    // found" at runtime. The field is optional/nullable — non-linked tasks
    // simply have no row in the resulting index entry.
    //
    // Dead-scaffolding cleanup: drops `progressCounters` (the `null` sentinel
    // tells Dexie to remove the object store). The ProgressCounter entity is
    // retired per Decision 1 — per-Task sharedCounterId is the live model.
    // The `progressCounters` Table property, ops module, and barrel export are
    // also removed in this commit (callers are gone; store is dropped).
    //
    // No data backfill: existing tasks get `undefined` for `lastSyncedCount`,
    // which the sync service treats as null → LWW fallback on first conflict
    // after migration (correct — no common ancestor is known).
    this.version(11).stores({
      // Re-declare tasks to add the sharedCounterId index. Dexie merges
      // the new index into the existing spec; columns/rows are unaffected.
      tasks: `
        id,
        [userId+isDeleted],
        updatedAt,
        type,
        parentStepId,
        sharedCounterId
      `,
      progressCounters: null, // Drop the inert ProgressCounter object store.
    });

    // v12: Windowed Completion (docs/WINDOWED_COMPLETION.md §New entity +
    // §Sync). New `taskEvents` store — one soft-deletable occurrence row per
    // completion/increment on an event-owning task, synced per-row LWW like
    // compoundChildren. PR B sub-slice 1 is FOUNDATIONS ONLY: the store is
    // created empty; no backfill and no write/read paths yet (those land in
    // later sub-slices), so the table syncs harmlessly empty.
    //
    // Indexes: `[taskId+occurredAt]` is the windowed-evaluation hot path
    // (all of a task's events since a board's startDate). `[userId+occurredAt]`
    // backs lifetime/library reads. `[userId+isDeleted]` scopes the sync pull
    // like every other collection; `taskId` supports parent-scoped lookups.
    this.version(12).stores({
      taskEvents: `
        id,
        [userId+isDeleted],
        taskId,
        [taskId+occurredAt],
        [userId+occurredAt]
      `,
    });

    // v13: Windowed Completion — event BACKFILL (docs/WINDOWED_COMPLETION.md
    // §Migration & backfill, step 2). v12 created the `taskEvents` store empty
    // (sub-slice 1); this bump runs the backfill upgrade that synthesizes the
    // deterministic completion/increment events from existing lifetime task
    // state. Separated from v12 so the upgrade fires even on a dev machine that
    // already opened the DB at v12-empty (Dexie only runs an upgrade when
    // moving to a HIGHER stored version — attaching it to v12 would silently
    // skip those machines). No schema shape change (`.stores({})` no-op); the
    // version bump is the vehicle for the `.upgrade()` callback. Expired-board
    // SEALING (doc step 3) is PR C, NOT here.
    this.version(13).stores({}).upgrade((tx) => {
      // Dynamic import avoids a top-of-file cycle (migrationV13 imports `db`).
      return import('./operations/migrationV13').then((mod) => mod.runMigrationV13(tx));
    });

    // v14: Windowed Completion — board SEALING (docs/WINDOWED_COMPLETION.md
    // §Sealing → Board schema delta + §Migration step 3). Three new optional
    // Board fields (`sealedAt`, `sealedCompletedCells`, `activatedAt`) ride
    // along automatically — Dexie stores the full Board object verbatim, so no
    // index change is needed and none are indexed. The version bump is the
    // vehicle for the `.upgrade()` callback, which seals every already-expired
    // board (past its backstop deadline at upgrade time) from the pre-migration
    // rendered state. Boards still inside their backstop window are left for the
    // normal close-out prompt (slice 2). Runs AFTER v13's event backfill so the
    // event log exists, but seals from the lifetime task caches (pre-migration
    // semantics) to reproduce exactly what the user currently sees.
    this.version(14).stores({}).upgrade((tx) => {
      // Dynamic import avoids a top-of-file cycle (migrationV14 imports `db`).
      return import('./operations/migrationV14').then((mod) => mod.runMigrationV14(tx));
    });

    // v15: Task Pools + Recurring Boards Rework (P1, docs/POOLS_RECURRING.md
    // §Data model + §Migration). New `pools` and `coreBoardDefaults` stores —
    // created EMPTY here, mirroring the taskEvents v12/v13 split (schema shape
    // separated from the backfill upgrade so the upgrade still fires even on a
    // dev machine that already opened the DB at v15-empty).
    //
    // `pools`: `[userId+isDeleted]` scopes the sync pull + the future Tasks-tab
    // Pools segment list query (P2); `updatedAt` for ordered reads. No index on
    // `taskIds` — consumers (`resolveMix`, health checks) read the whole row.
    //
    // `coreBoardDefaults`: `[userId+timeframe]` is the one-row-per-(user,
    // timeframe) lookup the core-board setup prefill needs (mirrors the
    // `defaultPools` v8 index); `[userId+isDeleted]` scopes the sync pull.
    this.version(15).stores({
      pools: `
        id,
        [userId+isDeleted],
        updatedAt
      `,
      coreBoardDefaults: `
        id,
        [userId+timeframe],
        [userId+isDeleted],
        updatedAt
      `,
    });

    // v16: Task Pools + Recurring Boards Rework — first-launch BACKFILL
    // (docs/POOLS_RECURRING.md §Migration). Runs AFTER v15 created the stores
    // empty. Mints: (1) a `Pool` + `CoreBoardDefault` row per `DefaultPool`,
    // soft-deleting the `DefaultPool` row; (2) a `Pool` per
    // `RecurringBoardTemplate`'s `seedTaskIds`, stamping `poolIds: [pool.id]`,
    // `manualTaskIds: []`, `removedTaskIds: []` on the template (`seedTaskIds`
    // itself is left VERBATIM — decode-compat only, never read after P1).
    // No schema shape change here (`.stores({})` no-op); the version bump is
    // the vehicle for the `.upgrade()` callback, same pattern as v13/v14.
    this.version(16).stores({}).upgrade((tx) => {
      // Dynamic import avoids a top-of-file cycle (migrationV16 imports `db`).
      return import('./operations/migrationV16').then((mod) => mod.runMigrationV16(tx));
    });
  }
}

// NOTE: The `db` singleton instance lives in `db/internal.ts` (B3, issue
// #284). This module only defines the `AppDatabase` class + schema so the
// raw Dexie instance has a single, boundary-enforced import site. See
// `db/internal.ts`.

// Export types for convenience
export type {
  Board,
  Task,
  TaskEvent,
  TaskStep,
  BoardTask,
  User,
  SyncQueueItem,
  CompositeTask,
  CompositeNode,
  CompoundChild,
  RecurringBoardTemplate,
};
