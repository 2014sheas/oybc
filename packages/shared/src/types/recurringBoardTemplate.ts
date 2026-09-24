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
 * Legacy fields, still written:
 * - `poolIds` / `removedTaskIds` — a derived mirror of `sources`; the spawn
 *   reads it only through `sourcesForRecord`, but pool-health / deck-preview
 *   still read it directly.
 * - `seedTaskIds` — never read by the spawn; still read by un-migrated
 *   hydration, the Task-detail templates-referencing query
 *   (`fetchTemplatesReferencingTask`), and the roster loading fallbacks.
 *   Note it is a creation-time snapshot the edit path leaves stale (audit
 *   follow-up).
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
   * Creation-time snapshot of the wizard selection. Never read by the spawn;
   * still read by un-migrated hydration, the Task-detail
   * templates-referencing query (`fetchTemplatesReferencingTask`), and the
   * roster loading fallbacks — note it is a creation-time snapshot the edit
   * path leaves stale (audit follow-up).
   */
  seedTaskIds: string[];

  /**
   * Legacy trio: a derived mirror of `sources`' pool entries. The spawn
   * reads it only through `sourcesForRecord`, but pool-health /
   * deck-preview still read it directly.
   */
  poolIds?: string[];
  /** The hand-added layer — live in the sources model; always wins over exclusions. */
  manualTaskIds?: string[];
  /**
   * Legacy trio: flat removals of pool-sourced tasks — a derived mirror of
   * `sources`' exclusions. The spawn reads it only through
   * `sourcesForRecord` (mapped onto each derived source's
   * `excludedTaskIds`), but pool-health still reads it directly.
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
  // Legacy trio — the derived mirror of `sources` (see the entity doc);
  // written verbatim when supplied. The canonical shape is `sources`.
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
  // Legacy trio — the derived mirror of `sources`; see
  // `RecurringBoardTemplate`'s doc and `sourcesForRecord`.
  poolIds?: string[];
  manualTaskIds?: string[];
  removedTaskIds?: string[];
  /** Board Sources P1 — canonical sources shape (see the entity field). */
  sources?: BoardSource[];
  /** Dice for hand-added counters on a recurring board (§Member rules). Additive; absent = {}. */
  manualTaskVary?: Record<string, VaryLevel>;
}
