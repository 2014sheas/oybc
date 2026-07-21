import { useEffect } from 'react';
import styles from './RowContextMenu.module.css';

/**
 * One item in a {@link RowContextMenu}.
 */
export interface RowContextMenuItem {
  /** Item label rendered next to the glyph. */
  label: string;
  /** Single-character glyph rendered in a small leading gutter. */
  glyph: string;
  /** Invoked on click. The menu auto-closes on click via the
   *  click-outside handler; callers don't need to call onClose
   *  themselves. */
  action: () => void;
  /** Render the item dimmed + non-clickable. Used e.g. for an
   *  already-selected subtask leaf rendered under a compound's
   *  "Add a subtask" submenu. */
  disabled?: boolean;
  /** Render the label in `--riso-red` — for destructive actions (e.g.
   *  Counter Detail's "⋯" overflow → "Delete counter…", R2). */
  destructive?: boolean;
}

interface RowContextMenuProps {
  x: number;
  y: number;
  items: RowContextMenuItem[];
  onClose: () => void;
}

/**
 * Cursor-anchored floating context menu used by the wizard's Tasks
 * step (and now the `From a board` grid view) for long-press /
 * right-click quick actions on a task row or grid square.
 *
 * Dismisses on click-outside or Escape. The first listener is
 * attached on a one-frame timeout so the click that opened the menu
 * doesn't immediately re-trigger the close. Mirrors the
 * `FloatingContextMenu` pattern in `InteractiveTaskSquare` so
 * right-click feels consistent across the app.
 */
export function RowContextMenu({
  x,
  y,
  items,
  onClose,
}: RowContextMenuProps): React.ReactElement {
  useEffect(() => {
    const onDocClick = (): void => onClose();
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose();
    };
    const id = window.setTimeout(() => {
      document.addEventListener('click', onDocClick);
      document.addEventListener('keydown', onKey);
    }, 0);
    return () => {
      window.clearTimeout(id);
      document.removeEventListener('click', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [onClose]);

  return (
    <div
      role="menu"
      className={styles.menu}
      style={{ left: x, top: y }}
      onClick={(e) => e.stopPropagation()}
    >
      {items.map((it, i) => (
        // Index in the key disambiguates items that happen to share a
        // label (compound leaves can legitimately have the same title).
        <button
          key={`${i}-${it.label}`}
          type="button"
          role="menuitem"
          onClick={() => {
            it.action();
            // Auto-close after the action runs — matches the
            // RowContextMenuItem doc contract ("menu auto-closes on
            // click; callers don't need to call onClose themselves").
            // Idempotent if the caller's action also calls onClose.
            onClose();
          }}
          disabled={it.disabled}
          className={`${styles.item} ${it.destructive ? styles.itemDestructive : ''}`}
        >
          <span aria-hidden="true" className={styles.glyph}>
            {it.glyph}
          </span>
          <span>{it.label}</span>
        </button>
      ))}
    </div>
  );
}
