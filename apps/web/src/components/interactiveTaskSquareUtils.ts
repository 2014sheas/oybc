/**
 * Non-component helpers + style re-export shared by `InteractiveTaskSquare`
 * and its consumers. Split out of `InteractiveTaskSquare.tsx` so that
 * file exports components only — required for Fast Refresh / HMR.
 */

import styles from './InteractiveTaskSquare.module.css';

/** Exported CSS module styles for use by consumers rendering custom FloatingContextMenu children */
export { styles as interactiveTaskSquareStyles };

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * The interaction modes a task square can have.
 *
 * Board-integrity PR-3 (issue #360) added `'achievement'`: a read-only
 * square whose completion is resolved cross-board by the shared kernel
 * (`computeBoardGrid`'s ACHIEVEMENT branch), never a local toggle. See
 * `db/adapters.ts`'s `taskToSquareData`/`taskToSquareState` ACHIEVEMENT
 * branches and their `cellState` parameter.
 */
// 'progress' is INTENTIONALLY-INERT legacy residue (pre-unification per-board
// steps): `taskToSquareData`/`taskToSquareState` never emit it, so its
// branches here and in InteractiveTaskSquare.tsx are unreachable — kept only
// so old call shapes decode. Same disposition as `Task.lastSyncedCount`; do
// not wire new code to it (issue #379).
export type SquareTaskType = 'normal' | 'counting' | 'progress' | 'compound' | 'achievement';

/** A single step within a progress-type task. */
export interface ProgressStep {
  id: string;
  label: string;
}

/**
 * A pre-resolved child task for compound squares.
 *
 * @property taskId - ID of the child Task record
 * @property title - Display name of the child task
 * @property isCompleted - Whether the child task is currently complete
 */
export interface CompoundChild {
  taskId: string;
  title: string;
  isCompleted: boolean;
}

/**
 * All data needed to render a task bingo square.
 *
 * @property id - Unique identifier
 * @property title - Display name shown on the square
 * @property type - Controls interaction mode and progress bar colour
 * @property description - Optional descriptive text (shown in detail modal)
 * @property action - Counting tasks only: verb label (e.g. "Run")
 * @property maxCount - Counting tasks only: target count for completion
 * @property unit - Counting tasks only: unit label (e.g. "km")
 * @property steps - Progress tasks only: ordered list of sub-steps
 * @property operator - Compound tasks only: completion operator ('AND' | 'OR' | 'M_OF_N')
 * @property threshold - Compound tasks only: required count for M_OF_N operator
 * @property children - Compound tasks only: pre-resolved child tasks (resolved by the caller)
 */
export interface TaskSquareData {
  id: string;
  title: string;
  type: SquareTaskType;
  description?: string;
  /** counting only */
  action?: string;
  maxCount?: number;
  unit?: string;
  /**
   * Phase 2 — Shared Counters. Non-null when this is a linked derived
   * counter. The board-play surface maps `Task.sharedCounterId` into
   * this field so the DetailModal and FloatingContextMenu can gate
   * decrement/reset actions (linked counters are read-only; increments
   * must go through the source).
   */
  sharedCounterId?: string | null;
  /**
   * Phase 3 — Shared Counters. The baseline offset for a linked derived
   * counter. Mirrors `Task.baseline`. Used by `taskToSquareState` to
   * baseline-adjust `state.currentCount` via `deriveDisplayedCount` so
   * the rendered value reflects the derived count, not the raw source
   * accumulator.
   *
   * Non-null only when `sharedCounterId` is non-null.
   */
  baseline?: number | null;
  /** progress only */
  steps?: ProgressStep[];
  /** compound only */
  operator?: 'AND' | 'OR' | 'M_OF_N';
  threshold?: number;
  children?: CompoundChild[];
}

/**
 * Runtime state for a single task square.
 *
 * @property isCompleted - Whether the task is marked complete
 * @property currentCount - Counting tasks: how many units have been logged
 * @property completedStepIds - Progress tasks: set of step IDs marked done
 */
export interface SquareState {
  isCompleted: boolean;
  /** counting: current count */
  currentCount: number;
  /** progress: set of completed step IDs */
  completedStepIds: Set<string>;
}

/**
 * Tracks which square triggered a context menu and the cursor position.
 *
 * @property squareId - ID of the square that was right-clicked
 * @property x - Cursor X coordinate in viewport space
 * @property y - Cursor Y coordinate in viewport space
 */
export interface ContextMenuState {
  squareId: string;
  x: number;
  y: number;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Perform the "type-specific action" for a square:
 * - normal: toggle completion
 * - counting: increment count (caps at maxCount, marks complete at max)
 * - progress: no grid-level action (callers should open modal instead)
 * - compound: no grid-level action (callers should open modal instead)
 */
export function applyAction(sq: TaskSquareData, prev: SquareState): SquareState {
  if (sq.type === 'normal') {
    return { ...prev, isCompleted: !prev.isCompleted };
  }
  if (sq.type === 'counting') {
    const max = sq.maxCount ?? 1;
    const next = Math.min(prev.currentCount + 1, max);
    return { ...prev, currentCount: next, isCompleted: next >= max };
  }
  // progress and compound — no grid-level action; callers should open modal instead
  return prev;
}

/**
 * Compute the progress fraction in [0, 1] for a square.
 *
 * Compound: operator-aware fill.
 *   - AND: done / total children
 *   - OR: 0 or 1 (any-complete = full)
 *   - M_OF_N: done / threshold (clamped to 1.0)
 */
export function progressFraction(sq: TaskSquareData, state: SquareState): number {
  if (sq.type === 'counting') {
    const max = sq.maxCount ?? 1;
    return max === 0 ? 0 : state.currentCount / max;
  }
  if (sq.type === 'progress') {
    const total = sq.steps?.length ?? 0;
    if (total === 0) return 0;
    return state.completedStepIds.size / total;
  }
  if (sq.type === 'compound') {
    const children = sq.children ?? [];
    const total = children.length;
    const done = children.filter((c) => c.isCompleted).length;
    if (total === 0) return 0;
    if (sq.operator === 'OR') return done > 0 ? 1 : 0;
    if (sq.operator === 'M_OF_N') {
      const threshold = sq.threshold ?? 0;
      if (threshold === 0) return 0;
      return Math.min(done / threshold, 1);
    }
    // AND (default)
    return done / total;
  }
  return 0;
}

/**
 * Build the label shown inside the progress bar.
 *
 * Compound bar label: 'X/Y' for AND, 'X/T threshold' for M_OF_N, 'any 1 of Y' for OR.
 */
export function progressBarLabel(sq: TaskSquareData, state: SquareState): string {
  if (sq.type === 'counting') {
    return `${state.currentCount}/${sq.maxCount} ${sq.unit ?? ''}`.trim();
  }
  if (sq.type === 'progress') {
    const total = sq.steps?.length ?? 0;
    return `${state.completedStepIds.size}/${total} steps`;
  }
  if (sq.type === 'compound') {
    const children = sq.children ?? [];
    const done = children.filter((c) => c.isCompleted).length;
    const total = children.length;
    if (sq.operator === 'OR') return done > 0 ? 'complete' : `0 of ${total}`;
    if (sq.operator === 'M_OF_N') return `${done}/${sq.threshold ?? '?'}`;
    return `${done}/${total}`;
  }
  return '';
}
