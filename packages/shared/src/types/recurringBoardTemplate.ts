import { Timeframe, CenterSquareType } from "../constants/enums";
import type { BoardSource, VaryLevel } from "./boardSource";
import { BoardSize } from "../constants";

/**
 * RecurringBoardTemplate — a repeating board: a record that spawns a fresh
 * board for each new window when the user opens the Boards tab (lazy
 * detection only — never background creation). Canonical design:
 * docs/BOARD_SOURCES.md §Data model (task source) + docs/ARCHITECTURE.md
 * §Phase 6 (spawn lifecycle).
 *
 * Task source: `sources` (pulled pools/boards, each with a min/max range,
 * exclusions and a done-filter) + `manualTaskIds` (the hand-added layer) +
 * `manualTaskVary` (dice for hand-added counting members). Each spawn
 * resolves them live via `sourcesForRecord` → `selectBoardTasks`
 * (`../algorithms/boardSources`), shuffling only when `isRandomized`.
 * A record written before the `sources` stamp is read through
 * `sourcesForRecord`, which derives `[0, all]` pool sources from the legacy
 * `poolIds` / `removedTaskIds` trio (no data backfill).
 *
 * Decode-compat fields: `seedTaskIds`, `poolIds`, `removedTaskIds`. They
 * are still written (the trio as a derived mirror for old clients) but the
 * spawn never reads them directly; `seedTaskIds` is read back only for a
 * genuinely un-migrated record (every generalized field absent).
 *
 * - `lastSpawnedWindowKey` is the local-ISO `startDate` of the last spawned
 *   window (idempotent spawning); `null` ⇒ spawn immediately on next open.
 * - `Timeframe.CUSTOM` and `CenterSquareType.CHOSEN` are excluded (Zod-enforced).
 */
export interface RecurringBoardTemplate {
  // Identity
  id: string; // UUID (client-generated)
  userId: string; // FK to users

  // Configuration
  name: string; // Display name (1-120 chars after trim)
  timeframe: Timeframe; // DAILY / WEEKLY / MONTHLY / YEARLY (no CUSTOM)
  boardSize: BoardSize; // 3, 4, or 5
  centerSquareType: CenterSquareType; // FREE / NONE (no CHOSEN in MVP)
  isRandomized: boolean; // Whether the spawn shuffles its selection + placement
  /**
   * Decode-compat: a snapshot of the wizard selection at create time. Never
   * read by the spawn; read back only as the hand-added layer of a
   * genuinely un-migrated record (every generalized field absent).
   */
  seedTaskIds: string[];

  /**
   * Decode-compat (legacy trio): pools pulled into the pre-sources mix.
   * Still written as a derived mirror of `sources`; read only via
   * `sourcesForRecord` when `sources` is absent.
   */
  poolIds?: string[];
  /** The hand-added layer — live in the sources model; always wins over exclusions. */
  manualTaskIds?: string[];
  /**
   * Decode-compat (legacy trio): flat removals of pool-sourced tasks.
   * `sourcesForRecord` maps them onto each derived source's `excludedTaskIds`.
   */
  removedTaskIds?: string[];

  /**
   * Canonical task source (docs/BOARD_SOURCES.md §Data model): one entry
   * per pulled pool or board with range/excludes/filter. Absent on records
   * that predate the stamp — read through `sourcesForRecord`.
   */
  sources?: BoardSource[];
  /** Dice for hand-added counters on a recurring board (§Member rules). Additive; absent = {}. */
  manualTaskVary?: Record<string, VaryLevel>;

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
  /** Board Sources P1 — canonical sources shape (see the entity field). */
  sources?: BoardSource[];
  /** Dice for hand-added counters on a recurring board (§Member rules). Additive; absent = {}. */
  manualTaskVary?: Record<string, VaryLevel>;
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
  isRandomized?: boolean;
  seedTaskIds?: string[];
  isActive?: boolean;
  // P1 — additive, optional. See `RecurringBoardTemplate`'s docstring for
  // the mix formula and the "legacy shape" write-through rule.
  poolIds?: string[];
  manualTaskIds?: string[];
  removedTaskIds?: string[];
  /** Board Sources P1 — canonical sources shape (see the entity field). */
  sources?: BoardSource[];
  /** Dice for hand-added counters on a recurring board (§Member rules). Additive; absent = {}. */
  manualTaskVary?: Record<string, VaryLevel>;
}
