import { useEffect, useRef, useState } from 'react';
import { RisoIcon } from '../../../components/riso';
import styles from './TaskDetail.module.css';

export interface DetailMenuProps {
  /** "Open counter settings" (counting tasks with a counter): absent hides the item. */
  onOpenCounterSettings?: () => void;
  onDelete: () => void;
}

/**
 * The ⋯ menu: Open counter settings (counting) · ─ · Delete task… (red).
 * "Place on a board…" is omitted: no placement flow is reachable from Task
 * Detail on web today. Keyboard: focus lands on the first item, arrows / Home /
 * End rove, Escape and a choice hand focus back to ⋯, an outside press closes.
 *
 * @returns The 32px ⋯ button and its popover.
 */
export function DetailMenu({ onOpenCounterSettings, onDelete }: DetailMenuProps): React.ReactElement {
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const items = (): HTMLButtonElement[] => [...(wrap.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]') ?? [])];

  const close = (): void => {
    setOpen(false);
    button.current?.focus();
  };

  useEffect(() => {
    if (!open) return;
    items()[0]?.focus();
    const onPointer = (e: PointerEvent): void => {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', onPointer);
    return () => document.removeEventListener('pointerdown', onPointer);
  }, [open]);

  const onKeyDown = (e: React.KeyboardEvent): void => {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      close();
      return;
    }
    const list = items();
    const at = list.indexOf(document.activeElement as HTMLButtonElement);
    const to = e.key === 'ArrowDown' ? (at + 1) % list.length
      : e.key === 'ArrowUp' ? (at - 1 + list.length) % list.length
        : e.key === 'Home' ? 0 : e.key === 'End' ? list.length - 1 : -1;
    if (to < 0) return;
    e.preventDefault();
    list[to]?.focus();
  };

  const choose = (action: () => void): void => {
    close();
    action();
  };

  return (
    <div ref={wrap} className={styles.menuWrap}>
      <button ref={button} type="button" className={styles.dots} aria-label="Task options" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <RisoIcon name="dots" size={16} />
      </button>
      {open && (
        <div className={styles.menu} role="menu" aria-label="Task options" onKeyDown={onKeyDown}>
          {onOpenCounterSettings && (
            <>
              <button type="button" role="menuitem" tabIndex={-1} className={styles.menuItem} onClick={() => choose(onOpenCounterSettings)}>
                <RisoIcon name="sliders" size={16} />
                Open counter settings
              </button>
              <div className={styles.menuDivider} role="separator" />
            </>
          )}
          <button type="button" role="menuitem" tabIndex={-1} className={`${styles.menuItem} ${styles.menuDanger}`} onClick={() => choose(onDelete)}>
            <RisoIcon name="trash" size={16} />
            Delete task…
          </button>
        </div>
      )}
    </div>
  );
}
