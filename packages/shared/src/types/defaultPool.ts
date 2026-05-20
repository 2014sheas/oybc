import { Timeframe } from '../constants/enums';

/**
 * DefaultPool — Phase 6.X (Default Pools)
 *
 * A user-curated task pool that prefills the recurring-banner wizard for a
 * specific timeframe. One pool per `(userId, timeframe)`. Unlike
 * `RecurringBoardTemplate` (Phase 6.2), DefaultPool:
 *
 *   - **Does not auto-spawn** boards. It only prefills the wizard's
 *     `selectedTaskIds` when the user clicks the recurring banner; the
 *     user can add/remove tasks before saving.
 *   - **Has no scheduling state** (`lastSpawnedWindowKey`, etc.). It's a
 *     pure pool definition.
 *   - **Is also consumed by the pre-spawn flow** (Phase B, future PR): the
 *     "pre-spawn a future board" affordance pulls tasks from the pool to
 *     populate the future window's board.
 *
 * `Timeframe.CUSTOM` is excluded — custom boards have user-specified
 * dates with no recurring window concept; a "default pool" semantic
 * doesn't apply. Enforced by the Zod schema.
 *
 * Soft-delete (`isDeleted`) + version + sync metadata follow the same
 * pattern as other entities.
 */
export interface DefaultPool {
  // Identity
  id: string;                // UUID (client-generated)
  userId: string;            // FK to users

  // Configuration
  timeframe: Timeframe;      // DAILY / WEEKLY / MONTHLY / YEARLY (no CUSTOM)
  /**
   * Ordered task ID pool. Order is preserved for non-randomized board
   * creates; banner-wizard prefill seeds `selectedTaskIds` from this
   * list (the wizard handles ordering vs randomization at create time).
   * Soft-deleted tasks are NOT auto-removed from this list — the
   * wizard/pre-spawn paths filter them at read time so the user's intent
   * is preserved across temporary deletes.
   */
  taskIds: string[];

  // Timestamps
  createdAt: string;         // ISO8601
  updatedAt: string;         // ISO8601

  // Sync metadata
  lastSyncedAt?: string;     // ISO8601
  version: number;           // Optimistic locking (incremented on each update)
  isDeleted: boolean;        // Soft delete
  deletedAt?: string;        // ISO8601
}

/**
 * DefaultPool creation input. Fields not listed are computed client-side
 * at insert: `id` (UUID), `createdAt`/`updatedAt` (now), `version` (1),
 * `isDeleted` (false).
 */
export interface CreateDefaultPoolInput {
  timeframe: Timeframe;
  taskIds: string[];
}

/**
 * Partial update input. `userId` and `timeframe` are NOT mutable post-
 * create — to change timeframe, delete + recreate the pool (preserves
 * the per-(user, timeframe) uniqueness invariant).
 */
export interface UpdateDefaultPoolInput {
  taskIds?: string[];
}
