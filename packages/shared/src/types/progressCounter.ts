/**
 * ProgressCounter - Shared cumulative counter across boards
 *
 * Enables cross-board goals like "Read 100 pages total across 3 boards"
 *
 * Design principles:
 * - Shared across all boards for a user
 * - Atomic updates (transaction required)
 * - Conflict resolution: Sum all increments (additive)
 * - UUID primary key (offline creation)
 */
export interface ProgressCounter {
  // Identity
  id: string;                    // UUID (client-generated)
  userId: string;                // Foreign key to users table

  // Configuration
  name: string;                  // "Reading Progress", "Running Miles"
  unit: string;                  // "pages", "miles", "times"
  targetValue: number;           // Goal (e.g., 100)
  currentValue: number;          // Current progress

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete
  deletedAt?: string;            // ISO8601
}

/**
 * ProgressCounter creation input
 */
export interface CreateProgressCounterInput {
  name: string;
  unit: string;
  targetValue: number;
}

/**
 * ProgressCounter update input
 */
export interface UpdateProgressCounterInput {
  name?: string;
  currentValue?: number;
  targetValue?: number;
}
