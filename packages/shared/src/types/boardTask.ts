import type { CountKind } from '../algorithms/countValue';

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
  /**
   * Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md) — a locked
   * placement never changes position: Shuffle and every move skip it and
   * it is not a drop target. Still completable. Optional + absent ⇒ false
   * (forward-compat decode like `Board.isCore`: pre-feature rows and peer
   * payloads carry no field).
   */
  isLocked?: boolean;

  // ── Per-placement parameters (docs/TASK_WINDOW_REWORK.md, slice 1) ──
  // All optional and absent on every pre-rework row. INERT in slice 1: no
  // reader (slice 2) and no writer (slice 3) exists yet; the fields are
  // typed, validated, stored and synced (clearable) so both clients carry
  // the shape before anything writes it (the lockstep rule).
  /**
   * A counting placement's goal for THIS board (owner ruling 2026-10-16:
   * frozen when the board is made or the square is edited). Absent ⇒ the
   * task's own `maxCount`. Positive, quantized to `targetKind`'s step.
   */
  targetOverride?: number;
  /**
   * The count kind `targetOverride` is expressed in. Written together with
   * `targetOverride`, never alone (a kind without an override is dropped on
   * normalisation). A later kind switch on the root never rewrites it.
   */
  targetKind?: CountKind;
  /**
   * A compound placement's per-child goals for THIS board, keyed by the
   * compound's own DIRECT child task ids (a linked child by its own id).
   * Sorted by `childId`, unique, each target positive; `[]` is normalised
   * to absent. An ARRAY, not a map: Firestore writes are `merge: true` and
   * a map deep-merges, so a removed key would survive remotely.
   */
  childTargets?: PlacementChildTarget[];
  /**
   * A per-board title for a counter square (owner ruling 2026-10-16: a
   * rename never forks). Absent ⇒ the root's templates at the placement's
   * goal. Trimmed, non-empty.
   */
  titleOverride?: string;

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
  isDeleted: boolean;            // Soft delete (tombstone)
  deletedAt?: string;            // ISO8601
}

/** One entry of {@link BoardTask.childTargets}. */
export interface PlacementChildTarget {
  /** The compound's direct child task id. */
  childId: string;
  /** That child's goal on this board; positive, quantized to the child's kind. */
  target: number;
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
  /**
   * Optional per-square lock at creation (Board Edit slice 3): the wizard's
   * active persist writes a CHOSEN pick as a locked centre placement.
   * Absent = unlocked.
   */
  isLocked?: boolean;
}
