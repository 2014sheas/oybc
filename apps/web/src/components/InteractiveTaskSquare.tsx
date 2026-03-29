import { useEffect, useCallback, useState, useRef } from 'react';
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

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Perform the "type-specific action" for a square:
 * - normal: toggle completion
 * - counting: increment count (caps at maxCount, marks complete at max)
 * - progress: no grid-level action (callers should open modal instead)
 *
 * @param sq - The task square data
 * @param prev - The current state of the square
 * @returns The updated SquareState
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

/**
 * Compute the progress fraction in [0, 1] for a square.
 *
 * @param sq - The task square data
 * @param state - The current state of the square
 * @returns A value between 0 and 1 representing completion progress
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
  return 0;
}

/**
 * Build the label shown inside the progress bar.
 *
 * @param sq - The task square data
 * @param state - The current state of the square
 * @returns A human-readable progress string, or empty string for normal tasks
 */
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

// ─── FloatingContextMenu ──────────────────────────────────────────────────────

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

interface ContextMenuProps {
  /** Task data for the square that was right-clicked */
  sq: TaskSquareData;
  /** Current state of that square */
  state: SquareState;
  /** Cursor position for anchoring the menu */
  position: { x: number; y: number };
  /** Dismiss the menu */
  onClose: () => void;
  /** When provided, renders custom content instead of the default game-action buttons.
   *  Use the CSS classes `styles.contextMenuItem` and `styles.contextMenuDivider`
   *  from InteractiveTaskSquare.module.css for consistent styling. */
  children?: React.ReactNode;
  // Game-action callbacks — only required when children is not provided
  onToggleComplete?: (id: string) => void;
  onIncrementCount?: (id: string) => void;
  onDecrementCount?: (id: string) => void;
  onResetCount?: (id: string) => void;
  onMarkAllStepsComplete?: (id: string) => void;
  onMarkAllStepsIncomplete?: (id: string) => void;
  onViewDetails?: (id: string) => void;
}

/**
 * Floating context menu positioned near the cursor, clamped to viewport.
 *
 * @param sq - Task data for the square that was right-clicked
 * @param state - Current state of that square
 * @param position - Raw cursor coordinates used as initial anchor
 * @param onClose - Dismiss the menu
 * @param onToggleComplete - Toggle normal task completion
 * @param onIncrementCount - Add one unit to a counting task
 * @param onDecrementCount - Remove one unit from a counting task
 * @param onResetCount - Reset counting task to zero
 * @param onMarkAllStepsComplete - Mark every progress step complete
 * @param onMarkAllStepsIncomplete - Mark every progress step incomplete
 * @param onViewDetails - Open the detail modal for this square
 */
export function FloatingContextMenu({
  sq,
  state,
  position,
  onClose,
  onToggleComplete,
  onIncrementCount,
  onDecrementCount,
  onResetCount,
  onMarkAllStepsComplete,
  onMarkAllStepsIncomplete,
  onViewDetails,
  children,
}: ContextMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);

  // Clamp to viewport once mounted
  const [pos, setPos] = useState(position);
  useEffect(() => {
    if (menuRef.current) {
      const { offsetWidth: w, offsetHeight: h } = menuRef.current;
      const x = Math.min(position.x, window.innerWidth - w - 8);
      const y = Math.min(position.y, window.innerHeight - h - 8);
      setPos({ x: Math.max(8, x), y: Math.max(8, y) });
    }
  }, [position]);

  // Close on click-outside or Escape
  useEffect(() => {
    const handleClick = () => onClose();
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    // Defer to avoid the triggering contextmenu event from also counting
    const id = setTimeout(() => {
      document.addEventListener('click', handleClick);
      document.addEventListener('keydown', handleKey);
    }, 0);
    return () => {
      clearTimeout(id);
      document.removeEventListener('click', handleClick);
      document.removeEventListener('keydown', handleKey);
    };
  }, [onClose]);

  const allStepsDone =
    sq.type === 'progress' &&
    (sq.steps ?? []).length > 0 &&
    state.completedStepIds.size >= (sq.steps ?? []).length;

  return (
    <div
      ref={menuRef}
      className={styles.contextMenu}
      style={{ left: pos.x, top: pos.y }}
      onClick={(e) => e.stopPropagation()}
    >
      {children ?? (<>
      {sq.type === 'normal' && (
        <button
          className={styles.contextMenuItem}
          onClick={() => {
            onToggleComplete?.(sq.id);
            onClose();
          }}
        >
          {state.isCompleted ? '✗ Mark Incomplete' : '✓ Mark Complete'}
        </button>
      )}

      {sq.type === 'counting' && (
        <>
          <button
            className={styles.contextMenuItem}
            onClick={() => {
              onIncrementCount?.(sq.id);
              onClose();
            }}
            disabled={state.currentCount >= (sq.maxCount ?? 1)}
          >
            + Add {sq.action} (+1)
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={state.currentCount <= 0}
            onClick={() => {
              onDecrementCount?.(sq.id);
              onClose();
            }}
          >
            − Remove {sq.action} (−1)
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={state.currentCount <= 0}
            onClick={() => {
              onResetCount?.(sq.id);
              onClose();
            }}
          >
            ↺ Reset
          </button>
        </>
      )}

      {sq.type === 'progress' && (
        <>
          <button
            className={styles.contextMenuItem}
            onClick={() => {
              onViewDetails?.(sq.id);
              onClose();
            }}
          >
            ✓ View Steps
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={allStepsDone}
            onClick={() => {
              onMarkAllStepsComplete?.(sq.id);
              onClose();
            }}
          >
            ✓✓ Mark All Complete
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={!allStepsDone}
            onClick={() => {
              onMarkAllStepsIncomplete?.(sq.id);
              onClose();
            }}
          >
            ✗ Mark Incomplete
          </button>
        </>
      )}

      <div className={styles.contextMenuDivider} />
      <button
        className={styles.contextMenuItem}
        onClick={() => {
          onViewDetails?.(sq.id);
          onClose();
        }}
      >
        ⓘ View Details
      </button>
      </>)}
    </div>
  );
}

// ─── InteractiveTaskSquare ────────────────────────────────────────────────────

interface InteractiveTaskSquareProps {
  sq: TaskSquareData;
  state: SquareState;
  onAct: () => void;
  onContextMenu?: (e: React.MouseEvent) => void;
}

/**
 * A single 90×90 bingo square with task name, optional progress bar, and
 * checkmark on completion.
 *
 * Click/tap to perform the primary action. Right-click triggers the optional
 * context menu callback. Supports keyboard activation via Enter and Space.
 *
 * @param sq - Task data driving display and interaction mode
 * @param state - Current runtime state of this square
 * @param onAct - Called on primary action (click/Enter/Space)
 * @param onContextMenu - Optional callback on right-click; receives the mouse event
 */
export function InteractiveTaskSquare({
  sq,
  state,
  onAct,
  onContextMenu,
}: InteractiveTaskSquareProps) {
  const hasProgress = sq.type === 'counting' || sq.type === 'progress';
  const fraction = progressFraction(sq, state);
  const barLabel = progressBarLabel(sq, state);

  const handleClick = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      onAct();
    },
    [onAct],
  );

  const handleContextMenu = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      onContextMenu?.(e);
    },
    [onContextMenu],
  );

  return (
    <div
      role="button"
      tabIndex={0}
      className={`${styles.taskSquare} ${state.isCompleted ? styles.taskSquareCompleted : ''}`}
      onClick={handleClick}
      onContextMenu={handleContextMenu}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onAct();
        }
      }}
      aria-label={sq.title}
      aria-pressed={state.isCompleted}
    >
      {/* Checkmark (visible when completed) */}
      <span className={styles.checkmark}>✓</span>

      {/* Task name */}
      <span className={styles.taskName}>{sq.title}</span>

      {/* Action hint (counting tasks only, visible on hover) */}
      {sq.type === 'counting' && sq.unit && (
        <span className={styles.actionHint}>Tap: +1 {sq.unit}</span>
      )}

      {/* Progress bar */}
      {hasProgress && (
        <div className={styles.progressBarWrapper}>
          <div
            className={`${styles.progressBarFill} ${
              sq.type === 'counting'
                ? styles.progressBarFillCounting
                : styles.progressBarFillProgress
            }`}
            style={{ width: `${fraction * 100}%` }}
          />
          <div className={styles.progressBarLabel}>{barLabel}</div>
        </div>
      )}
    </div>
  );
}

// ─── DetailModal ──────────────────────────────────────────────────────────────

interface DetailModalProps {
  sq: TaskSquareData;
  state: SquareState;
  onClose: () => void;
  onToggleComplete: (id: string) => void;
  onIncrementCount: (id: string) => void;
  onDecrementCount: (id: string) => void;
  onToggleStep: (squareId: string, stepId: string) => void;
}

/**
 * A detail modal rendered as a fixed overlay with backdrop.
 *
 * Presents type-appropriate controls: a toggle button for normal tasks, a
 * counter with +/− buttons for counting tasks, and step checkboxes for
 * progress tasks. Backdrop clicks and Escape key close the modal.
 *
 * @param sq - Task data to display
 * @param state - Current state of the task
 * @param onClose - Called when the user dismisses the modal
 * @param onToggleComplete - Called with square id to toggle normal task completion
 * @param onIncrementCount - Called with square id to add one count unit
 * @param onDecrementCount - Called with square id to remove one count unit
 * @param onToggleStep - Called with (squareId, stepId) to toggle a progress step
 */
export function DetailModal({
  sq,
  state,
  onClose,
  onToggleComplete,
  onIncrementCount,
  onDecrementCount,
  onToggleStep,
}: DetailModalProps) {
  // Close on Escape key
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  const fraction = progressFraction(sq, state);
  const barLabel = progressBarLabel(sq, state);

  return (
    <div
      className={styles.modalBackdrop}
      onClick={onClose}
      role="presentation"
    >
      {/* Inner content stops propagation so clicks don't close */}
      <div
        className={styles.modal}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-labelledby="modal-title"
      >
        <button
          className={styles.modalCloseButton}
          onClick={onClose}
          aria-label="Close"
        >
          ✕
        </button>

        <h3 id="modal-title" className={styles.modalTitle}>
          {sq.title}
        </h3>

        {/* Normal task */}
        {sq.type === 'normal' && (
          <>
            {sq.description && (
              <p className={styles.modalDescription}>{sq.description}</p>
            )}
            <button
              className={`${styles.modalButton} ${
                state.isCompleted
                  ? styles.modalButtonIncomplete
                  : styles.modalButtonComplete
              }`}
              onClick={() => onToggleComplete(sq.id)}
            >
              {state.isCompleted ? 'Mark Incomplete' : 'Mark Complete'}
            </button>
          </>
        )}

        {/* Counting task */}
        {sq.type === 'counting' && (
          <>
            <p className={styles.modalMeta}>
              {sq.action} · {sq.maxCount} {sq.unit}
            </p>
            {/* Progress bar */}
            <div className={styles.modalProgressBar}>
              <div
                className={`${styles.modalProgressFill} ${styles.modalProgressFillCounting}`}
                style={{ width: `${fraction * 100}%` }}
              />
              <div className={styles.modalProgressLabel}>{barLabel}</div>
            </div>
            {/* Counter controls */}
            <div className={styles.counterRow}>
              <button
                className={styles.counterButton}
                disabled={state.currentCount <= 0}
                onClick={() => onDecrementCount(sq.id)}
                aria-label="Decrease"
              >
                −
              </button>
              <span className={styles.counterValue}>
                {state.currentCount} / {sq.maxCount}
              </span>
              <button
                className={styles.counterButton}
                disabled={state.currentCount >= (sq.maxCount ?? 1)}
                onClick={() => onIncrementCount(sq.id)}
                aria-label="Increase"
              >
                +
              </button>
            </div>
          </>
        )}

        {/* Progress task */}
        {sq.type === 'progress' && (
          <>
            {sq.description && (
              <p className={styles.modalDescription}>{sq.description}</p>
            )}
            {/* Progress bar */}
            <div className={styles.modalProgressBar}>
              <div
                className={`${styles.modalProgressFill} ${styles.modalProgressFillProgress}`}
                style={{ width: `${fraction * 100}%` }}
              />
              <div className={styles.modalProgressLabel}>{barLabel}</div>
            </div>
            {/* Step checkboxes */}
            <div className={styles.stepsList}>
              {(sq.steps ?? []).map((step) => (
                <label key={step.id} className={styles.stepItem}>
                  <input
                    type="checkbox"
                    checked={state.completedStepIds.has(step.id)}
                    onChange={() => onToggleStep(sq.id, step.id)}
                  />
                  {step.label}
                </label>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
