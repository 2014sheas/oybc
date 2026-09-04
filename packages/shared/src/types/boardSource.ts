/**
 * BoardSource — Board Sources rework (docs/BOARD_SOURCES.md, P1).
 *
 * One pulled source feeding a board's task list: a **pool** or another
 * **board**, with a two-handle range (how many of its tasks land on the
 * board), per-board exclusions, and (boards only) a done/not-done filter.
 * A board's full task list = its sources plus the hand-added manual layer
 * (`manualTaskIds`, unchanged from the pools rework).
 *
 * Stored on `RecurringBoardTemplate.sources` and inside the wizard-draft
 * blob (`Board.recurringDraftMix`, v2 codec). Replaces the retired
 * `poolIds` + `removedTaskIds` pair as the canonical persisted shape —
 * during P1 both representations are written together (the legacy trio is
 * decode-compat + old-client tolerance; see docs/BOARD_SOURCES.md
 * §Data model) and `sourcesForRecord` in `../algorithms/boardSources`
 * derives sources on read for records that predate the stamp.
 *
 * iOS twin: `apps/ios/OYBC/Database/Models/BoardSource.swift` — keep in
 * sync.
 */

/** What kind of entity a `BoardSource` pulls from. */
export type BoardSourceKind = 'pool' | 'board';

/**
 * Board-source member filter. `'all'` = every square; `'todo'` = only
 * squares not yet complete in the source board's window (evaluated at
 * resolve time via the per-cell resolver — never the lifetime cache).
 * Pools are always `'all'` (the field is carried but ignored for pools).
 */
export type BoardSourceFilter = 'all' | 'todo';

export interface BoardSource {
  /** `Pool.id` (kind `'pool'`) or the pulled `Board.id` (kind `'board'`). */
  sourceId: string;
  kind: BoardSourceKind;
  /**
   * Range minimum — "guarantee at least this many of this source's tasks
   * on the board". `0` = no guarantee (the default). Clamped defensively
   * at resolve time to the source's available count and the board's
   * fillable cell count; UI enforces the same cap.
   */
  min: number;
  /**
   * Range maximum — "at most this many of this source's tasks on the
   * board". `null` is the **"all" latch** (the default): the cap tracks
   * the source's live available count, so a source pulled and left alone
   * follows pool edits / square completions without storing a stale
   * number. A numeric value is a deliberate handle drag.
   */
  max: number | null;
  /**
   * Per-board exclusions — task ids suppressed from THIS source's supply
   * for THIS board only. The saved pool/board is never modified. An entry
   * for a task the source doesn't currently supply is stale-inert
   * (harmless; supply − excluded is unchanged) — records migrated from
   * the flat `removedTaskIds` carry the full legacy list on every source
   * for exactly this reason (docs/BOARD_SOURCES.md §Migration).
   */
  excludedTaskIds: string[];
  /** See {@link BoardSourceFilter}. Meaningful for kind `'board'` only. */
  filter: BoardSourceFilter;
}
