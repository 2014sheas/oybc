import { Timeframe, CenterSquareType } from "../constants/enums";
import { BoardSize } from "../constants";

/**
 * RecurringBoardTemplate — Phase 6.2 (Preset-pool Recurring Boards)
 *
 * A user-curated task pool that automatically creates a fresh board every window when
 * the user opens the Boards tab. Differs from Phase 6.1's
 * `findPendingRecurringBoards` (which surfaces a banner inviting the user to
 * *create* a board for the current window) — templates spawn boards
 * automatically without any banner. Spawned boards appear directly in the
 * board list.
 *
 * Canonical design: docs/ARCHITECTURE.md §Phase 6.2.
 *
 * Design notes:
 *
 * - `seedTaskIds` is the pool the spawn function draws from. It is stored
 *   verbatim — soft-deletion of one of the referenced tasks does NOT
 *   automatically remove the id from the array; instead the spawn skips that
 *   template's current window and surfaces a "needs attention" indicator on
 *   the template row. This keeps the user's intent intact while preventing
 *   broken boards from being spawned.
 *
 * - `lastSpawnedWindowKey` is the `startDate` (local ISO8601) of the most
 *   recently spawned window. Compared to the current window's `startDate`
 *   from `getTimeframeBoundaries(timeframe, now, weekStartDay)` for
 *   idempotent spawning. `null` ⇒ never spawned ⇒ spawn immediately on next
 *   Boards-tab open (locked decision: first-spawn timing is immediate, not
 *   "wait for next rollover").
 *
 * - `Timeframe.CUSTOM` is excluded — same reason as Phase 6.1: custom
 *   boards have user-specified dates incompatible with computed-window
 *   recurrence. The Zod schema enforces this.
 *
 * - `CenterSquareType.CHOSEN` is excluded for the MVP — the form supports
 *   FREE / CUSTOM_FREE / NONE only. CHOSEN can be added later as an
 *   additive change (`centerTaskId?: string` field). The Zod schema
 *   enforces this.
 *
 * ## Task Pools + Recurring Boards Rework (P1) — generalized task source
 *
 * `seedTaskIds` is RETIRED: left verbatim on migrated records for
 * decode-compat (the `lastSyncedCount` precedent) and never read after P1
 * — no fallback. The record's task source generalizes to three additive,
 * optional fields — `poolIds` / `manualTaskIds` / `removedTaskIds` — whose
 * mix is resolved by `resolveMix` in `../algorithms/poolMix`:
 *
 *     mix = (union(pools' resolvable tasks) − removedTaskIds) + manualTaskIds
 *
 * Evaluation order is normative: removals subtract from the pool union
 * FIRST, then the manual layer adds — so a task id present in BOTH
 * `manualTaskIds` and `removedTaskIds` IS in the mix (manual wins;
 * removals only ever suppress pool-sourced supply). See
 * docs/POOLS_RECURRING.md §Changed: the spawn record for the full
 * removals semantics (supply-based untoggle clearing, stale-inert
 * entries) and the worked example that is the P1 unit-test vector set.
 *
 * **"Legacy shape"** (`isLegacyShapedRecord` in `../algorithms/poolMix`):
 * at most one pool, no manual additions, no removals — i.e. either a
 * genuinely un-migrated record (`poolIds`/`manualTaskIds`/`removedTaskIds`
 * all absent, `seedTaskIds` present) or a migration/legacy-create-minted
 * record (`poolIds.length === 1`, `manualTaskIds: []`, `removedTaskIds:
 * []`). This is the ONLY shape the legacy template editor's write-through
 * may mutate the linked Pool's `taskIds` for — a richer shape falls back
 * to writing `manualTaskIds` and clearing `poolIds`/`removedTaskIds`
 * instead (the legacy editor never writes a Pool it didn't mint).
 */
export interface RecurringBoardTemplate {
  // Identity
  id: string; // UUID (client-generated)
  userId: string; // FK to users

  // Configuration
  name: string; // Display name (1-120 chars after trim)
  timeframe: Timeframe; // DAILY / WEEKLY / MONTHLY / YEARLY (no CUSTOM)
  boardSize: BoardSize; // 3, 4, or 5
  centerSquareType: CenterSquareType; // FREE / CUSTOM_FREE / NONE (no CHOSEN in MVP)
  centerSquareCustomName?: string; // Required when centerSquareType is CUSTOM_FREE
  isRandomized: boolean; // Whether spawn shuffles seedTaskIds
  /**
   * Pool the spawn function draws from. Length must be ≥ the fillable
   * cell count (`boardSize² - (FREE ? 1 : 0)`); the spawn shuffles
   * (when `isRandomized`) and slices to the cell count, so any extras
   * become the "random subset" pool. The earlier `poolStrategy` field
   * — which let users choose between strict-fit and loose-fit — was
   * dropped during the Phase 6.2 UX rework: strict-fit is just a
   * special case of loose-fit where the user picked exactly N tasks,
   * and the selector added friction without capability.
   */
  seedTaskIds: string[];

  /**
   * P1 — pools pulled into this record's mix (may be empty; absent on a
   * genuinely un-migrated record — see the class docstring's "legacy
   * shape"). Order is preserved and is significant: `resolveMix`'s
   * `suppliedByPool`/union order is first-seen-pool order.
   */
  poolIds?: string[];
  /**
   * P1 — hand-picked additions layered on top of the pool union. Manual
   * always wins over a removal (see `resolveMix`).
   */
  manualTaskIds?: string[];
  /**
   * P1 — flat per-record removals of pool-sourced tasks (no per-pool
   * attribution — a removal suppresses that task regardless of which
   * pool(s) supply it). See `clearRemovalsForUntoggle` in
   * `../algorithms/poolMix` for the supply-based untoggle-clearing rule.
   */
  removedTaskIds?: string[];

  // Spawn state
  lastSpawnedWindowKey: string | null; // local ISO startDate of last spawn, or null
  isActive: boolean; // User can pause/resume without deleting

  // Timestamps
  createdAt: string; // ISO8601
  updatedAt: string; // ISO8601

  // Sync metadata
  lastSyncedAt?: string; // ISO8601
  version: number; // Optimistic locking (incremented on each update)
  isDeleted: boolean; // Soft delete
  deletedAt?: string; // ISO8601
}

/**
 * RecurringBoardTemplate creation input. Fields not listed are computed
 * client-side at insert: `id` (UUID), `lastSpawnedWindowKey` (null),
 * `createdAt`/`updatedAt` (now), `version` (1), `isDeleted` (false).
 */
export interface CreateRecurringBoardTemplateInput {
  name: string;
  timeframe: Timeframe;
  boardSize: BoardSize;
  centerSquareType: CenterSquareType;
  centerSquareCustomName?: string;
  isRandomized: boolean;
  seedTaskIds: string[];
  isActive: boolean;
  // P1 — additive, optional. The legacy create path (still the only path
  // until P4's wizard ships) sets these itself (`poolIds: [mintedPoolId]`,
  // `manualTaskIds: []`, `removedTaskIds: []`) rather than accepting them
  // from the caller; kept here so a future P4 caller can pass a
  // generalized create shape without a separate input type.
  poolIds?: string[];
  manualTaskIds?: string[];
  removedTaskIds?: string[];
}

/**
 * Partial update input. Excludes `lastSpawnedWindowKey` — that's mutated
 * by the spawn path, not by the user-facing edit form.
 */
export interface UpdateRecurringBoardTemplateInput {
  name?: string;
  timeframe?: Timeframe;
  boardSize?: BoardSize;
  centerSquareType?: CenterSquareType;
  centerSquareCustomName?: string;
  isRandomized?: boolean;
  seedTaskIds?: string[];
  isActive?: boolean;
  // P1 — additive, optional. See `RecurringBoardTemplate`'s docstring for
  // the mix formula and the "legacy shape" write-through rule.
  poolIds?: string[];
  manualTaskIds?: string[];
  removedTaskIds?: string[];
}
