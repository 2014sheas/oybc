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

      // BoardTasks junction table
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

    // v7: Phase 6.3 — board-completion-as-a-square. BoardTask gains two
    // optional fields, `referencedBoardId` (specific-board mode) and
    // `referencedTemplateId` (recurring-template mode). Neither is
    // indexed (lookups are per-row inside `derivationPass`, not table-
    // wide scans), so the `.stores()` call is intentionally empty —
    // Dexie stores the full BoardTask object verbatim and the new
    // fields ride along automatically. Bumping the version is what
    // makes Dexie open the existing IDB at the new version number
    // without erroring on the "downgrade" check; the schema string is
    // unchanged from v1.
    this.version(7).stores({});
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
