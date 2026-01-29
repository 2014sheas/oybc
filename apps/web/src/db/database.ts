import Dexie, { Table } from 'dexie';
import type {
  Board,
  Task,
  TaskStep,
  BoardTask,
  ProgressCounter,
  User,
  SyncQueueItem,
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
};
