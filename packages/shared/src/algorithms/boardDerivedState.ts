/**
 * Board derived-state change predicate (sync-churn fix).
 *
 * Every board derivation write (the live cascades, the pull cascades, the
 * edit cascades, the sealed re-derive) recomputes a board's derived fields
 * from converged source data. Before this predicate existed those writes were
 * unconditional: each one bumped `version` + `updatedAt` and enqueued a push
 * even when nothing had changed, so own-push echoes on the pull path re-ran
 * the cascade, re-bumped every containing board and re-pushed it — versions
 * climbed into the thousands and every launch re-pushed every live board.
 *
 * Callers compute the next state, ask this predicate, and when it says
 * "unchanged" skip the write, the version bump AND the sync enqueue.
 *
 * Pure, no I/O. Swift twin: `apps/ios/OYBC/Services/BoardDerivedState.swift`,
 * pinned by `tests/fixtures/boardDerivedStateVectors.json`.
 */

/**
 * The board fields a derivation write owns. Everything else on a Board row
 * (identity, schedule, sync metadata) is out of scope — `version` and
 * `updatedAt` in particular are never compared.
 */
export interface BoardDerivedState {
  completedTasks?: number;
  totalTasks?: number;
  linesCompleted?: number;
  completedLineIds?: string[] | null;
  status?: string;
  completedAt?: string | null;
  sealedCompletedCells?: number[] | null;
}

/** Order-independent equality of two arrays treated as sets. */
function sameSet<T>(a: readonly T[], b: readonly T[]): boolean {
  const sa = new Set(a);
  const sb = new Set(b);
  if (sa.size !== sb.size) return false;
  for (const x of sa) if (!sb.has(x)) return false;
  return true;
}

/** `null` / `undefined` / `''` all mean "no completedAt". */
function normalizedCompletedAt(value: string | null | undefined): string | null {
  return value ? value : null;
}

/**
 * True when writing `after` over `before` would change at least one derived
 * field.
 *
 * Comparison rules (mirrored exactly by the Swift twin):
 * - `completedTasks` / `totalTasks` / `linesCompleted`: absent = 0.
 * - `completedLineIds`: compared as a set; absent / null = empty (iOS stores
 *   an empty list as NULL, web as `[]`).
 * - `status`: strict equality.
 * - `completedAt`: absent / null / `''` = none.
 * - `sealedCompletedCells`: compared as a set; absent / null is DISTINCT from
 *   `[]` (a sealed snapshot always stores an array, a live board none).
 *
 * @param before The stored board (or its derived fields).
 * @param after  The board as the derivation would write it.
 * @returns `true` if a write is needed, `false` if it would be a no-op.
 */
export function boardDerivedStateChanged(before: BoardDerivedState, after: BoardDerivedState): boolean {
  if ((before.completedTasks ?? 0) !== (after.completedTasks ?? 0)) return true;
  if ((before.totalTasks ?? 0) !== (after.totalTasks ?? 0)) return true;
  if ((before.linesCompleted ?? 0) !== (after.linesCompleted ?? 0)) return true;
  if (!sameSet(before.completedLineIds ?? [], after.completedLineIds ?? [])) return true;
  if (before.status !== after.status) return true;
  if (normalizedCompletedAt(before.completedAt) !== normalizedCompletedAt(after.completedAt)) return true;
  const beforeCells = before.sealedCompletedCells ?? null;
  const afterCells = after.sealedCompletedCells ?? null;
  if (beforeCells === null || afterCells === null) return beforeCells !== afterCells;
  return !sameSet(beforeCells, afterCells);
}
