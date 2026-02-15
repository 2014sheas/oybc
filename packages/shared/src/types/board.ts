import { BoardStatus, Timeframe, CenterSquareType } from '../constants/enums';
import { BoardSize } from '../constants';

/**
 * Board - Main game board entity
 *
 * Design principles:
 * - UUID primary key (offline creation)
 * - Denormalized stats (instant reads, no joins)
 * - Version field (optimistic locking)
 * - Soft deletes (isDeleted flag)
 */
export interface Board {
  // Identity
  id: string;                    // UUID (client-generated)
  userId: string;                // Foreign key to users table

  // Metadata
  name: string;                  // Board title
  description?: string;          // Optional description

  // Configuration
  status: BoardStatus;           // draft, active, completed, archived
  boardSize: BoardSize;          // 3, 4, or 5
  timeframe: Timeframe;          // daily, weekly, monthly, yearly, custom
  startDate: string;             // ISO8601 (start of timeframe)
  endDate: string;               // ISO8601 (end of timeframe)
  centerSquareType: CenterSquareType; // free, custom_free, chosen, none
  centerSquareCustomName?: string;   // Custom display name for CUSTOM_FREE type
  centerTaskId?: string;             // Task ID for CHOSEN type (future use)
  isRandomized: boolean;         // Whether tasks are randomized on grid

  // Denormalized stats (for instant reads, updated on task completion)
  totalTasks: number;            // Total tasks on board (boardSize * boardSize)
  completedTasks: number;        // Number of completed tasks
  linesCompleted: number;        // Number of bingos achieved
  completedLineIds?: string[];   // Completed line IDs (e.g., ["row_0", "col_1", "diag_0"])
                                 // Format: "row_0", "col_1", etc. (0-based indices)

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601
  completedAt?: string;          // ISO8601 (when board fully completed)

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601 (last successful sync to Firestore)
  version: number;               // Optimistic locking (incremented on each update)
  isDeleted: boolean;            // Soft delete flag
  deletedAt?: string;            // ISO8601 (when deleted)
}

/**
 * Board creation input (subset of Board fields)
 */
export interface CreateBoardInput {
  name: string;
  description?: string;
  boardSize: BoardSize;
  timeframe: Timeframe;
  startDate: string;
  endDate: string;
  centerSquareType: CenterSquareType;
  centerSquareCustomName?: string;   // Required when centerSquareType is CUSTOM_FREE
  centerTaskId?: string;             // Required when centerSquareType is CHOSEN
  isRandomized: boolean;
}

/**
 * Board update input (partial updates)
 */
export interface UpdateBoardInput {
  name?: string;
  description?: string;
  status?: BoardStatus;
}
