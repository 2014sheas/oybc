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
  onViewDetails?: (id: string) => void;
  /**
   * When provided, an "Open in library" item is added to the context menu
   * for ALL task types. Triggers the task library detail sheet.
   */
  onOpenInLibrary?: (taskId: string) => void;
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
  onViewDetails,
  onOpenInLibrary,
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
          >
            + Add {sq.action} (+1)
          </button>
          <button
            className={styles.contextMenuItem}
            disabled={state.currentCount <= 0 || sq.sharedCounterId != null}
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

      {onOpenInLibrary && (
        <button
          className={styles.contextMenuItem}
          onClick={() => {
            onOpenInLibrary(sq.id);
            onClose();
          }}
        >
          ↗ Open in library
        </button>
      )}

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
  /** Specific-board mode: referenced board's display label + trigger-met
   *  status. Falls back to `(deleted board)` when the referenced board
   *  was soft-deleted, so the cell makes clear why it's not completing. */
  referencedBoardName?: string;
  referencedBoardCompleted?: boolean;
  /** Recurring-template mode: template name + M / N spawns meeting the
   *  trigger within the parent board's window. `templateRequiredCount`
   *  is the user-set required N; `templateInWindowMet` is how many
   *  in-window spawns currently satisfy the trigger. Empty window
   *  renders as `0/N` and derivation marks the cell incomplete. */
  templateName?: string;
  templateInWindowMet?: number;
  templateRequiredCount?: number;
}

interface InteractiveTaskSquareProps {
  sq: TaskSquareData;
  state: SquareState;
  onAct: () => void;
  onContextMenu?: (e: React.MouseEvent) => void;
  /** Compound tasks only: called when the user toggles a child task in the detail sheet. */
  onCompoundChildToggle?: (childTaskId: string) => void;
  /** Compound tasks only: a counting child's stepper — `+1` logs its step, `-1` removes it. */
  onCompoundChildIncrement?: (childTaskId: string, direction: 1 | -1) => void;
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
  const hasProgress = sq.type === 'counting' || sq.type === 'compound';
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
      const met = badge.templateInWindowMet ?? 0;
      const required = badge.templateRequiredCount ?? 0;
      return `${met}/${required} ${name}`;
    }
  }
}
