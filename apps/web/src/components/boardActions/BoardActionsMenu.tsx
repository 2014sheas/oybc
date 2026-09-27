import { useEffect, useRef, useState } from 'react';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoIcon } from '../riso';
import type { BoardMenuItem, BoardMenuItemKind } from './boardMenu';
import styles from './BoardActionsMenu.module.css';

export interface BoardActionsMenuProps {
  /** Rows to render, in display order (`buildBoardMenuItems`). Empty renders nothing. */
  items: BoardMenuItem[];
  /** The board's display name — shown ellipsized in the popover header. */
  boardName: string;
  /** Fired when a row is chosen; the menu closes itself first. */
  onSelect: (kind: BoardMenuItemKind) => void;
}

/**
 * BoardActionsMenu — the title-row "…" board menu (Board Edit redesign
 * slice 2, plan D1/D3). A 36px square trigger (ink-filled while open, per
 * the handoff's `decorate()`) opens a 216px popover anchored under it:
 * a "Board" kicker + ellipsized name header, then the menu rows from
 * `buildBoardMenuItems` (danger rows in `--riso-red`, hover → gold fill +
 * ink-static text). The iOS twin is a SwiftUI `Menu` over the same
 * `BoardMenuItem` rows (`BoardActionsMenuButton.swift`).
 *
 * Renders nothing when `items` is empty (draft boards have no menu, D3).
 */
export function BoardActionsMenu({ items, boardName, onSelect }: BoardActionsMenuProps): React.ReactElement | null {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);

  const { ref: menuRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open,
    onCancel: () => setOpen(false),
  });

  // Close on outside click — deferred one tick so the click that OPENED the
  // menu (the trigger button) doesn't also close it via the same listener
  // (mirrors `FloatingContextMenu`'s pattern).
  useEffect(() => {
    if (!open) return undefined;
    const handleClick = (e: MouseEvent) => {
      const target = e.target as Node;
      if (menuRef.current?.contains(target) || triggerRef.current?.contains(target)) return;
      setOpen(false);
    };
    const id = window.setTimeout(() => {
      document.addEventListener('click', handleClick);
    }, 0);
    return () => {
      window.clearTimeout(id);
      document.removeEventListener('click', handleClick);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  if (items.length === 0) return null;

  return (
    <div className={styles.wrap}>
      <button
        ref={triggerRef}
        type="button"
        className={`${styles.trigger} ${open ? styles.triggerOpen : ''}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Board menu"
        onClick={() => setOpen((v) => !v)}
      >
        <RisoIcon name="dots" size={16} />
      </button>
      {open && (
        <div
          ref={menuRef}
          role="menu"
          aria-label="Board menu"
          className={styles.popover}
          {...modalProps}
        >
          <div className={styles.header}>
            <span className={styles.kicker}>Board</span>
            <span className={styles.name}>{boardName}</span>
          </div>
          {items.map((item) => (
            <button
              key={item.kind}
              type="button"
              role="menuitem"
              className={`${styles.row} ${item.danger ? styles.danger : ''}`}
              onClick={() => {
                setOpen(false);
                onSelect(item.kind);
              }}
            >
              <RisoIcon name={item.icon} size={18} />
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
