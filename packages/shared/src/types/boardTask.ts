/**
 * BoardTask - Junction table linking boards and tasks
 *
 * Design principles:
 * - Pure placement record. No completion state, no cross-board reference,
 *   no achievement-square config. Completion lives globally on Task (see
 *   `Task.isCompleted` and the compound-tasks-unification spec).
 * - Phase 6.3 moved the cross-board reference fields (`referencedBoardId`,
 *   `referencedTemplateId`) onto `Task` and made ACHIEVEMENT a first-class
 *   `TaskType`, leaving `BoardTask` placement-only — see `Task` and
 *   `TaskType` in this package for details.
 * - Grid position (row, col) for board layout.
 * - UUID primary key (offline creation).
 * - Soft-deleted (tombstoned) like every other synced collection — see
 *   `docs/BOARD_INTEGRITY.md`. Placement removal sets `isDeleted`/`deletedAt`
 *   instead of a physical delete so the LWW version bump wins the sync
 *   tie-break and the tombstone propagates to other devices.
 */
export interface BoardTask {
  // Identity
  id: string;                    // UUID (client-generated)
  boardId: string;               // Foreign key to boards table
  taskId: string;                // Foreign key to tasks table

  // Grid position
  row: number;                   // Row index (0-based)
  col: number;                   // Column index (0-based)
  isCenter: boolean;             // True if center square (for odd-sized boards)

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete (tombstone)
  deletedAt?: string;            // ISO8601
}

/**
 * BoardTask creation input
 */
export interface CreateBoardTaskInput {
  boardId: string;
  taskId: string;
  row: number;
  col: number;
  isCenter: boolean;
}
