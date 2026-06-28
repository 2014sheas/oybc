import { useEffect } from 'react';
import styles from './SquareTapMenu.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

interface SquareTapMenuProps {
  /** Display name of the task currently occupying the tapped square. */
  taskTitle: string;
  /**
   * Click coordinates (from the mouse event that opened the menu).
   * Used to position the menu near the tap point.
   * Note: RisoBoardCell's onClick is `() => void` with no event param, so
   * we use a wrapper button to capture coordinates rather than a DOMRect.
   */
  x: number;
  y: number;
  /** Called when the user picks "Replace task". */
  onReplace: () => void;
  /** Called when the user picks "Edit task". */
  onEdit: () => void;
  /** Dismiss the menu (clicks scrim, Escape, or after an action fires). */
  onClose: () => void;
}

// Menu dimensions (pixels) — must stay in sync with the CSS .menu width + estimated height.
const MENU_W = 216;
const MENU_H = 152; // estimated; used only for flip-above detection
const PAD = 10;

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * SquareTapMenu — small context-menu popover shown when tapping a non-center
 * square in "Edit tasks" sub-mode. Positions near the tap point, clamped
 * within the viewport. Flips above the tap point if it would overflow bottom.
 * Ported from the prototype's `openMenu()` / `.wb-menu` logic.
 *
 * @param taskTitle - Display name for the square's task (header row)
 * @param x - Click clientX coordinate
 * @param y - Click clientY coordinate
 * @param onReplace - Fires when user chooses "Replace task"
 * @param onEdit - Fires when user chooses "Edit task"
 * @param onClose - Fired on scrim click or Escape
 */
export function SquareTapMenu({
  taskTitle,
  x: clickX,
  y: clickY,
  onReplace,
  onEdit,
  onClose,
}: SquareTapMenuProps): React.ReactElement {
  // ── Position computation ──────────────────────────────────────────────────
  // Center the menu horizontally around the click point, clamped to viewport.
  // Place below click by default; flip above if near the bottom edge.
  let x = clickX - MENU_W / 2;
  x = Math.max(PAD, Math.min(x, window.innerWidth - MENU_W - PAD));

  let y = clickY + 8;
  if (y + MENU_H > window.innerHeight - PAD) y = clickY - MENU_H - 8;
  y = Math.max(PAD, y);

  // ── Keyboard dismiss ─────────────────────────────────────────────────────
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onClose]);

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <>
      {/* Scrim — true rgba(0,0,0,…), never adaptive --riso-ink (rule from RISO_WEB.md). */}
      <div
        className={styles.scrim}
        onClick={onClose}
        aria-hidden="true"
      />
      <div
        className={styles.menu}
        role="dialog"
        aria-modal="true"
        aria-label={`Options for square: ${taskTitle}`}
        style={{ left: x, top: y }}
      >
        {/* Header: SQUARE kicker + truncated task name */}
        <div className={styles.menuTask}>
          <div className={styles.menuKicker}>SQUARE</div>
          <div className={styles.menuName} title={taskTitle}>
            {taskTitle}
          </div>
        </div>

        {/* Replace task */}
        <button
          type="button"
          className={styles.menuItem}
          autoFocus
          onClick={() => {
            onReplace();
            onClose();
          }}
        >
          {/* swap / arrows icon */}
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M7 16V4m0 0L3 8m4-4l4 4M17 8v12m0 0l4-4m-4 4l-4-4"
            />
          </svg>
          Replace task
        </button>

        {/* Edit task */}
        <button
          type="button"
          className={styles.menuItem}
          onClick={() => {
            onEdit();
            onClose();
          }}
        >
          {/* pencil icon */}
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M11 4H4a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2v-7"
            />
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z"
            />
          </svg>
          Edit task
        </button>
      </div>
    </>
  );
}
