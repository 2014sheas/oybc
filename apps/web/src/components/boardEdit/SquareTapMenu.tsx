import { useEffect } from 'react';
import styles from './SquareTapMenu.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

interface SquareTapMenuProps {
  /** Display name of the task (or "Free space") for the tapped square header. */
  taskTitle: string;
  /**
   * Click coordinates (from the mouse event that opened the menu).
   * Used to position the menu near the tap point.
   * Note: RisoBoardCell's onClick is `() => void` with no event param, so
   * we use a wrapper button to capture coordinates rather than a DOMRect.
   */
  x: number;
  y: number;
  /** Called when the user picks "Replace task". Omit to hide the item. */
  onReplace?: () => void;
  /** Called when the user picks "Edit task". Omit to hide the item. */
  onEdit?: () => void;
  /**
   * Phase 2b — shown when the center cell holds a task (NONE center type)
   * and the user can convert it back to a free space. Omit to hide the item.
   */
  onMakeFree?: () => void;
  /**
   * Phase 2b — shown when the center is a free space (FREE/CUSTOM_FREE) and
   * the user can convert it to a task square. Omit to hide the item.
   */
  onMakeTask?: () => void;
  /** Dismiss the menu (clicks scrim, Escape, or after an action fires). */
  onClose: () => void;
}

// Menu dimensions (pixels) — MENU_W must stay in sync with the CSS .menu width.
// MENU_H is estimated per visible item count for flip-above detection.
const MENU_W = 216;
const MENU_HEADER_H = 54; // header row approximate height
const MENU_ITEM_H = 50;   // each button row approximate height
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
  onMakeFree,
  onMakeTask,
  onClose,
}: SquareTapMenuProps): React.ReactElement {
  // ── Position computation ──────────────────────────────────────────────────
  // Center the menu horizontally around the click point, clamped to viewport.
  // Place below click by default; flip above if near the bottom edge.
  // Compute height dynamically based on how many items are visible.
  const itemCount = [onReplace, onEdit, onMakeFree, onMakeTask].filter(Boolean).length;
  const menuH = MENU_HEADER_H + itemCount * MENU_ITEM_H;

  let x = clickX - MENU_W / 2;
  x = Math.max(PAD, Math.min(x, window.innerWidth - MENU_W - PAD));

  let y = clickY + 8;
  if (y + menuH > window.innerHeight - PAD) y = clickY - menuH - 8;
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

        {/* Replace task — hidden for center-toggle-only menus (no task) */}
        {onReplace && (
          <button
            type="button"
            className={styles.menuItem}
            autoFocus={true}
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
        )}

        {/* Edit task — hidden for center-toggle-only menus (no task) */}
        {onEdit && (
          <button
            type="button"
            className={styles.menuItem}
            autoFocus={!onReplace}
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
        )}

        {/* Phase 2b — Make it a free space (NONE center with task → FREE) */}
        {onMakeFree && (
          <button
            type="button"
            className={styles.menuItem}
            autoFocus={!onReplace && !onEdit}
            onClick={() => {
              onMakeFree();
              onClose();
            }}
          >
            {/* star icon (mirrors the free-center star marker) */}
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.197-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z"
              />
            </svg>
            Make it a free space
          </button>
        )}

        {/* Phase 2b — Make it a task square (FREE/CUSTOM_FREE center → NONE) */}
        {onMakeTask && (
          <button
            type="button"
            className={styles.menuItem}
            autoFocus={!onReplace && !onEdit && !onMakeFree}
            onClick={() => {
              onMakeTask();
              onClose();
            }}
          >
            {/* grid/square icon */}
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
              />
            </svg>
            Make it a task square
          </button>
        )}
      </div>
    </>
  );
}
