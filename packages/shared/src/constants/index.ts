export * from './enums';

/**
 * Board size options
 */
export const BOARD_SIZES = [3, 4, 5] as const;
export type BoardSize = typeof BOARD_SIZES[number];

/**
 * Maximum retry attempts for sync operations
 */
export const MAX_SYNC_RETRIES = 5;

/**
 * Sync batch size (operations per batch)
 */
export const SYNC_BATCH_SIZE = 50;

/**
 * Sync interval in milliseconds (5 minutes)
 */
export const SYNC_INTERVAL_MS = 5 * 60 * 1000;

/**
 * Database version (for migrations)
 */
export const DB_VERSION = 1;

/**
 * Local database read target (milliseconds)
 */
export const TARGET_READ_TIME_MS = 10;
