import Dexie, { Table } from 'dexie';
import type {
  Board,
  Task,
  TaskStep,
  BoardTask,
  ProgressCounter,
  User,
  SyncQueueItem,
  CompositeTask,
  CompositeNode,
  CompoundChild,
  RecurringBoardTemplate,
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
  progressCounters!: Table<ProgressCounter, string>;
  syncQueue!: Table<SyncQueueItem, string>;
  compositeTasks!: Table<CompositeTask, string>;
  compositeNodes!: Table<CompositeNode, string>;
  compoundChildren!: Table<CompoundChild, string>;
  recurringBoardTemplates!: Table<RecurringBoardTemplate, string>;

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

      // ProgressCounters table
      progressCounters: `
        id,
        [userId+isDeleted],
        updatedAt
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
  }
}

// Singleton instance
export const db = new AppDatabase();

// Enable debug logging in development
if (import.meta.env.DEV) {
  db.on('ready', () => {
    console.log('✅ Dexie database initialized');
  });

  // Log all database operations
  db.on('populate', () => {
    console.log('📊 Database populated with initial data');
  });

  // Uncomment to log all transactions (verbose)
  // db.on('changes', (changes) => {
  //   console.log('Database changes:', changes);
  // });
}

// Export types for convenience
export type {
  Board,
  Task,
  TaskStep,
  BoardTask,
  ProgressCounter,
  User,
  SyncQueueItem,
  CompositeTask,
  CompositeNode,
  CompoundChild,
  RecurringBoardTemplate,
};
