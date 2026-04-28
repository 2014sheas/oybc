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
}

