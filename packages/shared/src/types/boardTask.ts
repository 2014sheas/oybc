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
