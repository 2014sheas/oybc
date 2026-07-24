import type { BoardTask } from '../types';

/**
 * Board-integrity PR-2 (docs/BOARD_INTEGRITY.md) — deterministic placement
 * winner rule + pure repair core.
 *
 * PR-1 gave `BoardTask` durable tombstones, but did nothing to fix ALREADY
 * corrupted boards (duplicate placement rows left behind from the
 * pre-tombstone era — e.g. an interrupted Replace/Move edit, or two devices
 * independently writing to the same cell offline before converging), nor to
 * make collision resolution deterministic across every reader. Two problems,
 * one root fix:
 *
 *  1. When more than one live `BoardTask` row lands on the same cell (or the
 *     same Task ends up placed more than once on one board), every reader —
 *     render, edit-draft seeding, the derivation kernel — must pick the SAME
 *     winner, or the visible grid and the persisted stats (bingo lines,
 *     completedTasks) can disagree (see `duplicatePlacementDivergence.test.ts`
 *     for the original diagnostic evidence).
 *  2. The repair pass (Part 1, `apps/web/src/db/operations/placementIntegrity.ts`
 *     + the iOS twin) needs a PURE decision procedure for which rows to
 *     tombstone, so two devices independently repairing the SAME corrupted
 *     board converge on tombstoning the SAME losers — no ping-pong, no new
 *     conflict machinery, ordinary LWW reconciles the tombstones afterward.
 *
 * Both are driven by ONE winner rule, vector-pinned cross-platform via
 * `tests/fixtures/placementResolutionVectors.json`:
 *
 *   highest `version` → newest `updatedAt` → lowest `id` (lexicographic).
 *
 * `resolvePlacements` is the ROW-SET selector Part 2 wires into render
 * (`btByPosition`), edit-draft seeding (`squaresDraft`), and every cascade's
 * derivation-input assembly — before repair even runs, no two readers can
 * disagree about which row occupies a cell. Full per-cell resolver
 * unification (task-duplicate collapsing, achievement fan-out, etc.) is
 * deferred to PR-3; this function only unifies the (row, col) row-set.
 *
 * `computePlacementIntegrityRepair` is the Part 1 core: given a board's full
 * live placement set, decide which rows are corrupt and must be tombstoned —
 * cell collisions AND same-task duplicates (a Task placed at >1 row on one
 * board), plus straight out-of-bounds rows (no winner to pick, they just go).
 */

/**
 * Compare two placements by the winner rule. Returns a negative number when
 * `a` should be preferred over `b` (i.e. `a` wins), positive when `b` wins,
 * and `0` only when `a.id === b.id` (the same row).
 *
 * Mirrors `resolveConflict` (`lwwResolve.ts`) in spirit — higher version,
 * then newer `updatedAt` — but adds a THIRD tier (lowest id) because this
 * rule must pick a single winner among N rows outright, not just decide
 * between two, and ties on both version and timestamp are much more likely
 * here (multiple rows created in the very same batched write). An
 * unparseable/missing `updatedAt` is normalized to a -Infinity sentinel
 * (sorts OLDEST) so the comparator stays a genuine lexicographic
 * (version, time, id) TOTAL order — the earlier "skip the date compare
 * unless both sides parse" shape was NOT transitive: in a version-tied
 * group of ≥3 rows mixing valid and invalid dates, pairwise comparisons
 * silently switched between date-mode and id-mode, so the winner depended
 * on input order — destroying the cross-device repair determinism this
 * rule exists to provide (review Critical; pinned by the mixed-validity
 * vector + the permutation-stability tests).
 */
export function comparePlacementPrecedence(a: BoardTask, b: BoardTask): number {
  if (a.version !== b.version) return b.version - a.version;

  const aTimeRaw = new Date(a.updatedAt).getTime();
  const bTimeRaw = new Date(b.updatedAt).getTime();
  const aTime = Number.isNaN(aTimeRaw) ? -Infinity : aTimeRaw;
  const bTime = Number.isNaN(bTimeRaw) ? -Infinity : bTimeRaw;
  if (aTime !== bTime) return aTime > bTime ? -1 : 1;

  if (a.id !== b.id) return a.id < b.id ? -1 : 1;
  return 0;
}

/**
 * Pick the single winner among a non-empty set of colliding/duplicate
 * placements per the winner rule.
 *
 * @param rows Candidate placements (must be non-empty).
 * @returns The winning row (same object reference as one of `rows`).
 */
export function pickPlacementWinner(rows: readonly BoardTask[]): BoardTask {
  if (rows.length === 0) {
    throw new Error('pickPlacementWinner: rows must be non-empty');
  }
  let winner = rows[0];
  for (let i = 1; i < rows.length; i++) {
    if (comparePlacementPrecedence(rows[i], winner) < 0) winner = rows[i];
  }
  return winner;
}

/**
 * Resolve a raw (possibly corrupted) set of `BoardTask` rows for ONE board
 * into a clean row-set: at most one row per (row, col) cell.
 *
 * Pure, order-independent (the input array's order never affects the
 * output). Filters tombstones (defense-in-depth — every known caller
 * already pre-filters `!isDeleted`, but this is the shared choke point every
 * reader funnels through, mirroring the kernel's own tombstone guard) and
 * drops out-of-bounds rows (`row`/`col` outside `[0, boardSize)`), then
 * collapses any remaining (row, col) collision to its winner.
 *
 * Does NOT collapse same-task duplicates across different cells — that is a
 * board-wide invariant (`computePlacementIntegrityRepair` handles it), not a
 * per-cell rendering concern; two non-colliding cells legitimately render
 * independently even when they happen to share a taskId (see
 * `duplicatePlacementDivergence.test.ts` Case A for why that specific
 * shape is not itself a render/derivation divergence).
 *
 * Output is sorted by (row, col, id) ascending — stable and deterministic,
 * matching the iOS `ORDER BY row, col, id` read ordering (Part 2).
 *
 * @param rows      Raw `BoardTask` rows for a single board (any order, may
 *                  include tombstones / out-of-bounds / collisions).
 * @param boardSize The board's grid size (`Board.boardSize`).
 * @returns The resolved row-set — at most one row per cell, sorted.
 */
export function resolvePlacements(rows: readonly BoardTask[], boardSize: number): BoardTask[] {
  const byCell = new Map<string, BoardTask[]>();
  for (const bt of rows) {
    if (bt.isDeleted) continue;
    if (bt.row < 0 || bt.col < 0 || bt.row >= boardSize || bt.col >= boardSize) continue;
    const key = `${bt.row}-${bt.col}`;
    const group = byCell.get(key);
    if (group) group.push(bt);
    else byCell.set(key, [bt]);
  }

  const out: BoardTask[] = [];
  for (const group of byCell.values()) {
    out.push(group.length === 1 ? group[0] : pickPlacementWinner(group));
  }

  out.sort((a, b) => (a.row !== b.row ? a.row - b.row : a.col !== b.col ? a.col - b.col : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return out;
}

/** The outcome of a placement-integrity repair pass over one board. */
export interface PlacementIntegrityRepairResult {
  /**
   * Live rows that violate an invariant and must be soft-deleted
   * (tombstoned) by the caller. Empty when the board is already clean —
   * repairing a clean board is always a zero-write no-op (idempotency).
   */
  toTombstone: BoardTask[];
}

/**
 * Pure repair core (Part 1): given a board's full LIVE (non-tombstoned)
 * placement set, decide which rows are corrupt and must be tombstoned.
 *
 * Three violation classes, resolved in this order so the result is a single
 * deterministic pass (no violation class re-triggers another):
 *
 *   1. Out-of-bounds (`row`/`col` outside `[0, boardSize)`) — no winner to
 *      pick, every such row is tombstoned outright.
 *   2. Cell collisions (>1 in-bounds row at the same `(row, col)`) — the
 *      winner rule picks ONE survivor per cell; every other row in the group
 *      is tombstoned.
 *   3. Same-task duplicates (one Task placed at >1 surviving row on this
 *      board, evaluated AFTER cell-collision resolution) — the winner rule
 *      again picks ONE survivor per taskId; every other row is tombstoned.
 *
 * Deterministic ⇒ two devices independently repairing the SAME corrupted
 * board pick the SAME winners, so there is no repair ping-pong: the losers
 * converge to tombstoned everywhere via ordinary LWW, exactly like any other
 * soft-delete. Idempotent: running this again on the post-repair survivor
 * set always returns `toTombstone: []`.
 *
 * @param livePlacements All live (non-tombstoned) `BoardTask` rows for ONE
 *                        board. Callers are responsible for pre-filtering
 *                        `isDeleted` and scoping to a single `boardId` — this
 *                        function trusts its input is already scoped (it
 *                        does not re-check `boardId`), mirroring the shared
 *                        kernel's own contract.
 * @param boardSize      The board's grid size (`Board.boardSize`).
 */
export function computePlacementIntegrityRepair(
  livePlacements: readonly BoardTask[],
  boardSize: number,
): PlacementIntegrityRepairResult {
  const toTombstoneIds = new Set<string>();
  const byId = new Map<string, BoardTask>();
  for (const bt of livePlacements) byId.set(bt.id, bt);

  // 1. Out-of-bounds — no winner, straight tombstone.
  const inBounds: BoardTask[] = [];
  for (const bt of livePlacements) {
    if (bt.row < 0 || bt.col < 0 || bt.row >= boardSize || bt.col >= boardSize) {
      toTombstoneIds.add(bt.id);
    } else {
      inBounds.push(bt);
    }
  }

  // 2. Cell collisions — winner rule per (row, col).
  const byCell = new Map<string, BoardTask[]>();
  for (const bt of inBounds) {
    const key = `${bt.row}-${bt.col}`;
    const group = byCell.get(key);
    if (group) group.push(bt);
    else byCell.set(key, [bt]);
  }
  const afterCellResolution: BoardTask[] = [];
  for (const group of byCell.values()) {
    if (group.length === 1) {
      afterCellResolution.push(group[0]);
      continue;
    }
    const winner = pickPlacementWinner(group);
    afterCellResolution.push(winner);
    for (const bt of group) {
      if (bt.id !== winner.id) toTombstoneIds.add(bt.id);
    }
  }

  // 3. Same-task duplicates — winner rule per taskId, evaluated on the
  //    cell-collision survivors (a row already tombstoned in step 2 must
  //    not also "win" a task-duplicate group).
  const byTask = new Map<string, BoardTask[]>();
  for (const bt of afterCellResolution) {
    const group = byTask.get(bt.taskId);
    if (group) group.push(bt);
    else byTask.set(bt.taskId, [bt]);
  }
  for (const group of byTask.values()) {
    if (group.length === 1) continue;
    const winner = pickPlacementWinner(group);
    for (const bt of group) {
      if (bt.id !== winner.id) toTombstoneIds.add(bt.id);
    }
  }

  const toTombstone: BoardTask[] = [];
  for (const id of toTombstoneIds) {
    const bt = byId.get(id);
    if (bt) toTombstone.push(bt);
  }
  // Deterministic output order (id ascending) — no functional significance,
  // just keeps caller writes/tests stable.
  toTombstone.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  return { toTombstone };
}
