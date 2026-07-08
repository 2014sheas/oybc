/**
 * Database barrel export
 */

// NOTE: The raw `db` instance is intentionally NOT re-exported here (B3,
// issue #284). It lives in `db/internal.ts` and is importable only by the
// data layer (operations / hooks / firebase / tests). Components and pages
// must go through the operations exported below or a hook.
export { AppDatabase } from './database';
export * from './operations';
export * from './utils';
export type {
  Board,
  Task,
  TaskStep,
  BoardTask,
  User,
  SyncQueueItem,
} from './database';
