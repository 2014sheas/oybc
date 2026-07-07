/**
 * Task operations barrel.
 *
 * Split into domain modules (issue #265, code-motion only). Re-exports every
 * symbol so existing import sites (`../db/operations/tasks`) keep working
 * unchanged.
 */
export * from './tasks.crud';
export * from './tasks.sharedCounter';
export * from './tasks.deletion';
export * from './tasks.steps';
export * from './tasks.copy';
