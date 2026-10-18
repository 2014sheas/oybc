import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { RisoIcon, RisoTypeBadge } from '../../riso';
import type { MenuItem, SquareMenuModel } from './squareMenuItems';
import styles from './SquareMenu.module.css';

export interface SquareMenuProps {
  model: SquareMenuModel;
  /** Cursor position the menu anchors to (clamped into the viewport). */
  position: { x: number; y: number };
  /** A write is in flight — write items are inert at once. */
  busy: boolean;
  /** The busy LOOK (write items dimmed): `busy` held ~250 ms. Defaults to `busy`. */
  dim?: boolean;
  onChoose: (item: MenuItem) => void;
  onClose: () => void;
}

/**
 * SquareMenu — the unified hold menu: header (type square · title · meta) over
 * the items of `buildSquareMenu`, the first gold. `role="menu"`; arrows move,
 * Escape / an outside click close, focus returns to the held square. iOS twin:
 * `SquareHoldMenu`.
 *
 * @returns The menu.
 */
export function SquareMenu({ model, position, busy, dim = busy, onChoose, onClose }: SquareMenuProps): React.ReactElement {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState(position);
  // `onClose` is an inline closure — read it through a ref so the setup effect runs ONCE.
  const openerRef = useRef<HTMLElement | null>(null);
  const closeRef = useRef(onClose);
  useEffect(() => { closeRef.current = onClose; });
  const firstId = model.entries.find((e) => e !== 'divider')?.id;
  const [activeId, setActiveId] = useState(firstId);

  // Clamp into the viewport once measured, and again on resize.
  const { x, y } = position;
  useLayoutEffect(() => {
    const clamp = (): void => {
      const el = ref.current;
      if (!el) return;
      setPos({
        x: Math.max(8, Math.min(x, window.innerWidth - el.offsetWidth - 8)),
        y: Math.max(8, Math.min(y, window.innerHeight - el.offsetHeight - 8)),
      });
    };
    clamp();
    window.addEventListener('resize', clamp);
    return () => window.removeEventListener('resize', clamp);
  }, [x, y]);

  useEffect(() => {
    // Captured once (dev StrictMode re-runs this effect, by when focus is already in the menu).
    const opener = (openerRef.current ??= document.activeElement as HTMLElement | null);
    ref.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
    const onPointer = (e: MouseEvent): void => {
      if (!ref.current?.contains(e.target as Node)) closeRef.current();
    };
    // Escape closes from anywhere; Tab leaves the menu (it is a menu, not a form).
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape' || e.key === 'Tab') {
        e.preventDefault();
        closeRef.current();
      }
    };
    // Deferred so the contextmenu gesture that opened the menu doesn't close it.
    const id = setTimeout(() => document.addEventListener('mousedown', onPointer), 0);
    document.addEventListener('keydown', onKey);
    return () => {
      clearTimeout(id);
      document.removeEventListener('mousedown', onPointer);
      document.removeEventListener('keydown', onKey);
      // Hand focus back to the held square unless a surface the choice opened already took it.
      // Deferred a tick: the pointer's own focus change (an outside click) lands after this cleanup.
      setTimeout(() => { if (document.activeElement === document.body || !document.activeElement) opener?.focus?.(); }, 0);
    };
  }, []);

  const onKeyDown = (e: React.KeyboardEvent): void => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    e.preventDefault();
    const items = [...(ref.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])];
    const at = items.indexOf(document.activeElement as HTMLButtonElement);
    const step = e.key === 'ArrowDown' ? 1 : -1;
    items[(at + step + items.length) % items.length]?.focus();
  };

  return createPortal(
    <div ref={ref} className={styles.menu} role="menu" aria-label={model.title} style={{ left: pos.x, top: pos.y }} onKeyDown={onKeyDown}>
      <div className={styles.header}>
        <RisoTypeBadge type={model.type} size="small" />
        <span className={styles.title}>{model.title}</span>
        <span className={styles.meta}>{model.meta}</span>
      </div>
      {model.entries.map((entry, i) => {
        if (entry === 'divider') return <div key={`d${i}`} className={styles.divider} role="separator" />;
        const gold = entry.id === firstId;
        return (
          <button
            key={entry.id}
            type="button"
            role="menuitem"
            className={`${styles.item} ${gold ? styles.gold : ''}`}
            tabIndex={entry.id === activeId ? 0 : -1}
            onFocus={() => setActiveId(entry.id)}
            disabled={entry.disabled || (dim && entry.write)}
            aria-disabled={(busy && entry.write) || undefined}
            onClick={() => { if (!(busy && entry.write)) onChoose(entry); }}
          >
            <span className={styles.icon}><RisoIcon name={entry.icon} size={16} /></span>
            <span className={styles.label}>{entry.label}</span>
            {entry.meta && <span className={styles.meta}>{entry.meta}</span>}
          </button>
        );
      })}
    </div>,
    document.body,
  );
}
