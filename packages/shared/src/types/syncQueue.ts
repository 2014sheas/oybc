import { SyncOperationType, SyncStatus } from '../constants/enums';

/**
 * SyncQueue - Pending Firestore operations
 *
 * Design principles:
 * - Operations queued when offline or sync fails
 * - Processed in order (FIFO)
 * - Retry with exponential backoff on failure
 * - Batch operations for efficiency
 */
export interface SyncQueueItem {
  // Identity
  id: string;                    // UUID (client-generated)

  // Operation details
  entityType: string;            // 'board', 'task', 'boardTask', 'bingoLine'
  entityId: string;              // ID of the entity being synced
  operationType: SyncOperationType; // create, update, delete
  payload: string;               // JSON stringified entity data

  // Status tracking
  status: SyncStatus;            // pending, in_progress, completed, failed
  retryCount: number;            // Number of retry attempts
  lastError?: string;            // Last error message (if failed)

  // Timestamps
  createdAt: string;             // ISO8601 (when operation was queued)
  lastAttemptAt?: string;        // ISO8601 (last sync attempt)
  completedAt?: string;          // ISO8601 (when successfully synced)

  // Priority (lower number = higher priority)
  priority: number;              // Default: 0, Critical operations: -1
}

/**
 * SyncQueue item creation input
 */
export interface CreateSyncQueueItemInput {
  entityType: string;
  entityId: string;
  operationType: SyncOperationType;
  payload: any;                  // Will be JSON.stringify'd
  priority?: number;
}
