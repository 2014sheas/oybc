/**
 * Non-component helpers + style re-export shared by `InteractiveTaskSquare`
 * and its consumers. Split out of `InteractiveTaskSquare.tsx` so that
 * file exports components only — required for Fast Refresh / HMR.
 */

import styles from './InteractiveTaskSquare.module.css';

/** Exported CSS module styles for use by consumers rendering custom FloatingContextMenu children */
export { styles as interactiveTaskSquareStyles };

// ─── Types ────────────────────────────────────────────────────────────────────

/** The three interaction modes a task square can have. */
export type SquareTaskType = 'normal' | 'counting' | 'progress';

/** A single step within a progress-type task. */
export interface ProgressStep {
  id: string;
  label: string;
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
  /** progress only */
  steps?: ProgressStep[];
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
  // progress — no grid-level action; callers should open modal instead
  return prev;
}

/** Compute the progress fraction in [0, 1] for a square. */
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
  return 0;
}

/** Build the label shown inside the progress bar. */
export function progressBarLabel(sq: TaskSquareData, state: SquareState): string {
  if (sq.type === 'counting') {
    return `${state.currentCount}/${sq.maxCount} ${sq.unit ?? ''}`.trim();
  }
  if (sq.type === 'progress') {
    const total = sq.steps?.length ?? 0;
    return `${state.completedStepIds.size}/${total} steps`;
  }
  return '';
}
