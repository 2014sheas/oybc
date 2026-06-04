import { useEffect } from 'react';

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
      style={{
        position: 'fixed',
        left: x,
        top: y,
        zIndex: 1000,
        background: 'var(--color-bg-elevated, #1c1c1e)',
        border: '1px solid rgba(255,255,255,0.1)',
        borderRadius: 8,
        padding: '4px 0',
        minWidth: 180,
        boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
      }}
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
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 10,
            width: '100%',
            padding: '8px 14px',
            background: 'transparent',
            border: 0,
            color: 'inherit',
            font: 'inherit',
            cursor: it.disabled ? 'default' : 'pointer',
            textAlign: 'left',
            opacity: it.disabled ? 0.5 : 1,
          }}
          onMouseEnter={(e) => {
            if (!it.disabled) {
              (e.currentTarget as HTMLButtonElement).style.background =
                'rgba(255,255,255,0.08)';
            }
          }}
          onMouseLeave={(e) => {
            (e.currentTarget as HTMLButtonElement).style.background = 'transparent';
          }}
        >
          <span
            aria-hidden="true"
            style={{ width: 16, textAlign: 'center', opacity: 0.7 }}
          >
            {it.glyph}
          </span>
          <span>{it.label}</span>
        </button>
      ))}
    </div>
  );
}
