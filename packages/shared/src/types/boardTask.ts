import { Timeframe } from '../constants/enums';

/**
 * BoardTask - Junction table linking boards and tasks
 *
 * Design principles:
 * - Pure placement record — completion lives globally on Task, not per-board
 * - Grid position (row, col) for board layout
 * - UUID primary key (offline creation)
 * - Achievement squares for cross-board goals
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

  // Achievement square data (for cross-board goals)
  isAchievementSquare?: boolean;           // True if this is a cross-board goal
  achievementType?: 'bingo' | 'full_completion'; // What triggers completion
  achievementCount?: number;               // How many required (e.g., 3 monthly bingos)
  achievementTimeframe?: Timeframe;        // Lower-level timeframe to count
  achievementProgress?: number;            // Current progress (denormalized)

  /**
   * Phase 6.3 — Specific-board mode. When set, the achievement square
   * watches this single named board and completes when that board's
   * `status === GREENLOGGED` (and `!isDeleted`). Mutually exclusive
   * with `referencedTemplateId` — Zod refinement rejects rows that
   * set both. When neither is set, the existing aggregate-mode logic
   * (count across timeframe via `achievementType` + `achievementCount`)
   * applies.
   */
  referencedBoardId?: string;

  /**
   * Phase 6.3 — Recurring-template mode. When set, the achievement
   * square watches all spawns of this template whose `startDate` falls
   * within the parent board's `[startDate, endDate]` window. Square
   * completes when the in-window non-deleted spawn set is non-empty
   * AND every member is `GREENLOGGED`. Use case: a monthly fitness
   * board with a "Leg Day" square that completes when each weekly Leg
   * Day spawn greenlogs across the month. Mutually exclusive with
   * `referencedBoardId`.
   */
  referencedTemplateId?: string;

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
  isAchievementSquare?: boolean;
  achievementType?: 'bingo' | 'full_completion';
  achievementCount?: number;
  achievementTimeframe?: Timeframe;
  /** Phase 6.3 — see `BoardTask.referencedBoardId`. Mutually exclusive
   *  with `referencedTemplateId`. */
  referencedBoardId?: string;
  /** Phase 6.3 — see `BoardTask.referencedTemplateId`. Mutually
   *  exclusive with `referencedBoardId`. */
  referencedTemplateId?: string;
}

