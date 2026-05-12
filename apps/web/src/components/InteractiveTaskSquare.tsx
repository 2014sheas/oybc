import { useEffect, useCallback, useState, useRef } from 'react';
import styles from './InteractiveTaskSquare.module.css';
import {
  progressFraction,
  progressBarLabel,
  type TaskSquareData,
  type SquareState,
} from './interactiveTaskSquareUtils';

// ─── FloatingContextMenu ──────────────────────────────────────────────────────

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

      {sq.type === 'compound' && (
        <button
          className={styles.contextMenuItem}
          onClick={() => {
            onViewDetails?.(sq.id);
            onClose();
          }}
        >
          ⊕ View Children
        </button>
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

/**
 * Phase 6.3 — Optional achievement-square badge data for a cell.
 *
 * Orthogonal to `TaskSquareData` (which is shaped around task type).
 * The parent computes this from the underlying `Task`'s reference fields
 * (`type === ACHIEVEMENT` carrying `referencedBoardId` XOR
 * `referencedTemplateId`) plus a lookup against the workspace's boards /
 * templates. When `undefined`, the cell renders as a regular task with
 * no achievement-square indicator.
 */
export interface AchievementSquareBadgeData {
  mode: 'specificBoard' | 'recurringTemplate';
  /** Specific-board mode: referenced board's display label + greenlog
   *  status. Falls back to `(deleted board)` when the referenced board
   *  was soft-deleted, so the cell makes clear why it's not completing. */
  referencedBoardName?: string;
  referencedBoardCompleted?: boolean;
  /** Recurring-template mode: template name + M / N greenlogged spawns
   *  within the parent board's window. Empty window renders as `0/0`
   *  with the standard caption — derivation marks the cell incomplete
   *  in that case. */
  templateName?: string;
  templateInWindowGreenlogged?: number;
  templateInWindowTotal?: number;
}

interface InteractiveTaskSquareProps {
  sq: TaskSquareData;
  state: SquareState;
  onAct: () => void;
  onContextMenu?: (e: React.MouseEvent) => void;
  /** Compound tasks only: called when the user toggles a child task in the detail sheet. */
  onCompoundChildToggle?: (childTaskId: string) => void;
  /** Phase 6.3: when set, the cell renders an achievement-square badge
   *  at the top-left indicating cross-board tracking. */
  achievementBadge?: AchievementSquareBadgeData;
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
  achievementBadge,
}: InteractiveTaskSquareProps) {
  const hasProgress = sq.type === 'counting' || sq.type === 'progress' || sq.type === 'compound';
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

      {/* Phase 6.3: achievement-square badge (top-left). Replaces the
          compound badge when both apply — achievement-square semantics
          override the task-type indicator for display purposes (the
          cell still backs the task; the badge just signals cross-board
          tracking). */}
      {achievementBadge && (
        <span className={styles.achievementBadge} title="Achievement square">
          🎯 {formatAchievementBadgeLabel(achievementBadge)}
        </span>
      )}

      {/* Compound badge (top-left, compound tasks only). Suppressed
          when an achievement badge is already showing — see comment
          above. */}
      {!achievementBadge && sq.type === 'compound' && (
        <span className={styles.compoundBadge}>C</span>
      )}

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
                : sq.type === 'compound'
                  ? styles.progressBarFillCompound
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
  /** Compound tasks only: called when the user toggles a child task in the detail sheet. */
  onCompoundChildToggle?: (childTaskId: string) => void;
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
 * @param onCompoundChildToggle - Compound tasks only: called with childTaskId to toggle a child
 */
export function DetailModal({
  sq,
  state,
  onClose,
  onToggleComplete,
  onIncrementCount,
  onDecrementCount,
  onToggleStep,
  onCompoundChildToggle,
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

  /** Human-readable caption for the compound operator. */
  function compoundOperatorCaption(): string {
    if (sq.type !== 'compound') return '';
    const total = sq.children?.length ?? 0;
    if (sq.operator === 'OR') return `Any 1 of ${total}`;
    if (sq.operator === 'M_OF_N') return `At least ${sq.threshold ?? '?'} of ${total}`;
    return `All ${total} of ${total}`;
  }

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

        {/* Compound task */}
        {sq.type === 'compound' && (
          <>
            {sq.description && (
              <p className={styles.modalDescription}>{sq.description}</p>
            )}
            {/* Operator caption */}
            <p className={styles.compoundOperatorCaption}>{compoundOperatorCaption()}</p>
            {/* Progress bar */}
            <div className={styles.modalProgressBar}>
              <div
                className={`${styles.modalProgressFill} ${styles.modalProgressFillCompound}`}
                style={{ width: `${fraction * 100}%` }}
              />
              <div className={styles.modalProgressLabel}>{barLabel}</div>
            </div>
            {/* Child task list */}
            <ul className={styles.compoundChildList}>
              {(sq.children ?? []).map((child) => (
                <li
                  key={child.taskId}
                  className={styles.compoundChildItem}
                  onClick={() => onCompoundChildToggle?.(child.taskId)}
                  role="button"
                  tabIndex={0}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                      e.preventDefault();
                      onCompoundChildToggle?.(child.taskId);
                    }
                  }}
                  aria-pressed={child.isCompleted}
                >
                  <span className={styles.compoundChildCheck}>
                    {child.isCompleted ? '✓' : '○'}
                  </span>
                  <span
                    className={`${styles.compoundChildLabel} ${
                      child.isCompleted ? styles.compoundChildLabelDone : ''
                    }`}
                  >
                    {child.title}
                  </span>
                </li>
              ))}
            </ul>
            <p className={styles.compoundFooter}>
              Completion applies to all boards where this task appears.
            </p>
          </>
        )}
      </div>
    </div>
  );
}

// ─── Achievement-square badge label formatter ────────────────────────────────
//
// Compact, mode-aware label for the cell badge. Kept as a helper so the
// modal's render branches stay declarative.
//
// - Aggregate: "M/N" (e.g. "3/5"). Falls back to "0/0" if numbers missing.
// - Specific-board: "✓ Board name" when greenlogged, "Board name" otherwise.
//   Empty board name (referenced board was deleted) becomes "(deleted)".
// - Recurring-template: "M/N Template name". Empty template name → "(deleted)".
function formatAchievementBadgeLabel(badge: AchievementSquareBadgeData): string {
  switch (badge.mode) {
    case 'specificBoard': {
      const name = badge.referencedBoardName?.trim() || '(deleted)';
      return badge.referencedBoardCompleted ? `✓ ${name}` : name;
    }
    case 'recurringTemplate': {
      const name = badge.templateName?.trim() || '(deleted)';
      const g = badge.templateInWindowGreenlogged ?? 0;
      const t = badge.templateInWindowTotal ?? 0;
      return `${g}/${t} ${name}`;
    }
  }
}
