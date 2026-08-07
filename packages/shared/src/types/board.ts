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
  timeframe: Timeframe;          // daily, weekly, monthly, yearly, custom, indefinite
  startDate: string;             // ISO8601 (start of timeframe; creation anchor for indefinite boards)
  endDate?: string;              // ISO8601 (end of timeframe). Absent for INDEFINITE boards — they
                                 // never expire. Treat a missing endDate as an unbounded window
                                 // [startDate, ∞). See isBoardIndefinite().
  centerSquareType: CenterSquareType; // free, chosen, none
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

  // Phase 6.2 provenance (additive). Set on insert by the template-spawn
  // path; remains undefined for manually-created boards. Never mutated
  // after insert. Forward-compatible: pre-6.2 peers without this field
  // decode unchanged via Zod `.optional()`.
  spawnedFromTemplateId?: string;

  // Phase 6.1 core-board marker. `true` iff this board was created from
  // the Boards-tab recurring banner OR auto-spawned from a
  // RecurringBoardTemplate (Phase 6.2). The recurring-banner detector
  // (`findPendingRecurringBoards`) suppresses the banner only when an
  // `isCore: true` board exists for the active window — manual ad-hoc
  // boards for the same window do not dismiss the suggestion. Marked
  // optional so existing fixtures + old sync rows decode unchanged
  // (the Zod schema also defaults to `false`); the detector uses
  // strict `=== true` so `undefined` is treated as non-core.
  isCore?: boolean;

  // ── Windowed Completion — board sealing (docs/WINDOWED_COMPLETION.md
  //    §Sealing → Board schema delta) ────────────────────────────────
  //
  // `sealedAt` — set ONCE when the board's window is closed out (user Seal
  // action OR the auto-seal backstop OR migration of an already-expired
  // board). Never cleared; there is no unseal gesture. A non-null `sealedAt`
  // makes the board a permanent historical record: it drops out of the live
  // derivation fan-out, renders read-only from `sealedCompletedCells`, and is
  // ineligible for Board Edit. `status` is untouched — sealing is orthogonal
  // to draft/active/completed/archived.
  sealedAt?: string;             // ISO8601

  // `sealedCompletedCells` — the green cell indexes (`row*size+col`) frozen at
  // seal time, computed by `computeSealedCompletedCells` from the converged
  // in-window event union. A pure function of that union, so it re-derives
  // deterministically on any device when late pre-seal events arrive (never
  // LWW-raced). Undefined until the board seals.
  sealedCompletedCells?: number[];

  // `activatedAt` — when the board transitioned out of DRAFT (or, for a board
  // created active, its creation). Absent for boards created before this field
  // existed. The auto-seal backstop keys its deadline off
  // `max(endDate, activatedAt)` so a DRAFT activated AFTER its window already
  // expired still gets one full prompt cycle instead of an instant silent
  // seal (docs §Sealing → backstop, §Edge cases). Never mutated after the
  // activation that sets it.
  activatedAt?: string;          // ISO8601
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
  endDate?: string;              // Absent for INDEFINITE boards
  centerSquareType: CenterSquareType;
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

/**
 * Whether a board is "indefinite" — an ongoing board with no end date that
 * never expires, is excluded from recurrence/streaks/the core-board pager,
 * but still plays normally and can host achievement tasks (its window is
 * treated as `[startDate, ∞)`).
 *
 * The OR is deliberate: a board is indefinite if it carries the INDEFINITE
 * timeframe OR simply has no `endDate`. This keeps every consumer robust to a
 * sync row whose `endDate` is absent even if its `timeframe` is stale, and
 * mirrors the task-level precedent (`isTaskExpired` treats `!endDate` as
 * never-expiring). Use this everywhere instead of ad-hoc
 * `timeframe === Timeframe.INDEFINITE` / `endDate == null` checks.
 */
export function isBoardIndefinite(
  board: Pick<Board, 'timeframe' | 'endDate'>,
): boolean {
  return board.timeframe === Timeframe.INDEFINITE || board.endDate == null;
}
