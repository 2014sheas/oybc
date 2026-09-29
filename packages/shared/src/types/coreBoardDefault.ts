import { Timeframe } from '../constants/enums';
import type { BoardSize } from '../constants';
import type { DefaultCenterSquareType } from './user';

/**
 * CoreBoardDefault — Task Pools + Recurring Boards Rework (P1)
 *
 * Replaces `DefaultPool` (Phase 6.X). One row per `(userId, timeframe)`.
 * Chosen over `UserPreferences` fields (locked 2026-07-19: small table, not
 * prefs) because prefs sync as a single LWW doc — concurrent prefs writes
 * would race the whole default set — while per-row LWW matches the
 * `DefaultPool` precedent it replaces.
 *
 * Defaults **pre-fill** core-board setup (both fields render as plain,
 * editable chips); they never auto-own the board. The "Start every <TF>
 * board with 'X'" checkbox (shown only when pools are attached) persists
 * `corePoolIds` ONLY — never the day's one-off tasks.
 *
 * `coreDefaultTaskIds` is authored only in the P7 Board-settings defaults
 * sheet (chips + quick-add) — the field exists synced-but-unwritten from
 * P1 until P7. That's intentional, not a bug.
 *
 * `Timeframe.CUSTOM` is excluded — same reason as `DefaultPool` /
 * `RecurringBoardTemplate`: a "default" tied to a computed recurring
 * window has no semantic for custom-window boards. Enforced by the Zod
 * schema.
 *
 * Canonical design: docs/POOLS_RECURRING.md §Data model → New entity:
 * CoreBoardDefault.
 */
export interface CoreBoardDefault {
  // Identity
  id: string;                 // UUID (client-generated)
  userId: string;              // FK to users

  // Configuration
  timeframe: Timeframe;        // DAILY / WEEKLY / MONTHLY / YEARLY, immutable post-create
  /** Pools that pre-fill core-board setup (union'd as plain chips; never a board action). */
  corePoolIds: string[];
  /** Individual default tasks, pre-filled as plain chips alongside pool tasks. */
  coreDefaultTaskIds: string[];

  // Per-timeframe size + centre (docs/POOLS_RECURRING.md §Per-timeframe
  // size + centre, owner-decided 2026-09-29). Both OPTIONAL: an absent
  // field inherits the global `UserPreferences.defaultBoardSize` /
  // `defaultCenterType`; resolve through `resolveCoreBoardSetupDefaults`
  // (`algorithms/coreBoardSetupDefaults.ts`), never by reading these raw.
  // Declared `?:` (absent, never `null`) like `Board.sealedAt` /
  // `reopenedAt`; a clear is stored as ABSENT and reaches other devices via
  // `CLEARABLE_FIELDS_BY_COLLECTION.coreBoardDefaults` (deleted on push,
  // NULLed on the iOS pull). `null` exists only on the UPDATE input below.
  /** Per-timeframe board size override (3 | 4 | 5); absent = inherit prefs. */
  defaultBoardSize?: BoardSize;
  /** Per-timeframe centre override (FREE | NONE); absent = inherit prefs. */
  defaultCenterType?: DefaultCenterSquareType;

  // Timestamps
  createdAt: string;           // ISO8601
  updatedAt: string;           // ISO8601

  // Sync metadata
  lastSyncedAt?: string;       // ISO8601
  version: number;             // Optimistic locking (incremented on each update)
  isDeleted: boolean;          // Soft delete
  deletedAt?: string;          // ISO8601
}

/**
 * CoreBoardDefault creation input. Fields not listed are computed
 * client-side at insert: `id` (UUID), `createdAt`/`updatedAt` (now),
 * `version` (1), `isDeleted` (false).
 */
export interface CreateCoreBoardDefaultInput {
  timeframe: Timeframe;
  corePoolIds: string[];
  coreDefaultTaskIds: string[];
  /** Optional size override; omit (or pass `null`) to inherit prefs. */
  defaultBoardSize?: BoardSize | null;
  /** Optional centre override; omit (or pass `null`) to inherit prefs. */
  defaultCenterType?: DefaultCenterSquareType | null;
}

/**
 * Partial update input. `userId` and `timeframe` are NOT mutable
 * post-create — to change timeframe, delete + recreate the row (preserves
 * the per-(user, timeframe) uniqueness invariant, matching `DefaultPool`).
 */
export interface UpdateCoreBoardDefaultInput {
  corePoolIds?: string[];
  coreDefaultTaskIds?: string[];
  /**
   * Tri-state: `undefined` (key omitted) keeps the stored value, `null`
   * CLEARS it back to "inherit prefs" (stored as absent), a value
   * overrides. iOS twin: `CoreBoardDefaultFieldPatch` (`.keep` /
   * `.set(nil)` / `.set(x)`).
   */
  defaultBoardSize?: BoardSize | null;
  /** Same tri-state as `defaultBoardSize`. */
  defaultCenterType?: DefaultCenterSquareType | null;
}
