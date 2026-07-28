import { RisoIcon } from '../riso';
import styles from './RisoBoard.module.css';

/** Visual type of a board cell. */
export type CellType = 'normal' | 'counting' | 'compound';

/** A resolved cell's view-model — everything needed to render it, no data layer. */
export interface BoardCellModel {
  /** Stable key (the BoardTask id, or `free-<index>`). */
  key: string;
  /** Display name (task title, or FREE label for the center). */
  label: string;
  type: CellType;
  done: boolean;
  /** Counting progress, when `type === 'counting'`. */
  count?: { cur: number; max: number };
  /** FREE/auto center square (inked, gold star, not a real task). */
  isFree: boolean;
  /** Part of a completed bingo line (gold ring). */
  isLine: boolean;
  /**
   * When true, renders a two-dot shared-counter marker on the cell corner
   * (only while not done). Set for COUNTING tasks that are either a shared-
   * counter source or a linked derived counter.
   */
  isShared?: boolean;
  /**
   * When true, the cell pulses (`arriveGlow`, 2 iterations) — set for the
   * squares that just "arrived" from a shared-counter log made elsewhere
   * (Shared Counters P3). Purely a transient highlight; clears on auto-dismiss.
   */
  isArrived?: boolean;
}

export interface RisoBoardCellProps {
  cell: BoardCellModel;
  /** When provided, the cell becomes an interactive button (Phase 3b play). */
  onClick?: () => void;
  /** Right-click / long-press → the play board's context menu (Phase 3b). */
  onContextMenu?: (e: React.MouseEvent) => void;
  /** Optional corner badge (e.g. an ACHIEVEMENT-watch indicator). */
  badge?: React.ReactNode;
}

/**
 * A single read-only Riso board cell — colored by type, halftone + gold check
 * when done, counting bar for counters, FREE center, gold ring on bingo lines.
 * Presentational only; `onClick` (Phase 3b) makes it an interactive button,
 * `onContextMenu` wires the play board's context menu, and `badge` renders a
 * corner indicator (achievement watch).
 */
export function RisoBoardCell({ cell, onClick, onContextMenu, badge }: RisoBoardCellProps): React.ReactElement {
  const tagClass = cell.type === 'counting' ? styles.counting : cell.type === 'compound' ? styles.compound : '';
  const className = [
    styles.cell,
    cell.isFree ? styles.free : tagClass,
    cell.done && !cell.isFree ? styles.done : '',
    cell.isLine ? styles.line : '',
    cell.isArrived ? styles.arrived : '',
    onClick ? styles.interactive : '',
  ]
    .filter(Boolean)
    .join(' ');

  const inner = cell.isFree ? (
    <>
      <span className={styles.freeStar} aria-hidden="true" />
      <span className={styles.freeLabel}>{cell.label}</span>
    </>
  ) : (
    <>
      {badge}
      {cell.type === 'counting' && !cell.done && cell.isShared && (
        <span className={styles.sharedMarker} aria-hidden="true">
          <i /><i />
        </span>
      )}
      {(cell.type === 'counting' || cell.type === 'compound') && (
        <span className={`${styles.tag} ${cell.type === 'counting' ? styles.counting : styles.compound}`}>
          {cell.type === 'counting' && cell.count ? `×${cell.count.max}` : '≡'}
        </span>
      )}
      <span className={styles.cellText}>{cell.label}</span>
      {cell.type === 'counting' && cell.count && (
        <span className={styles.cbar}>
          <i
            style={{
              width: `${cell.count.max > 0 ? Math.min(100, Math.round((cell.count.cur / cell.count.max) * 100)) : 0}%`,
            }}
          />
          <span>
            {cell.count.cur}/{cell.count.max}
          </span>
        </span>
      )}
      {cell.done && (
        <span className={styles.check}>
          <RisoIcon name="check" />
        </span>
      )}
    </>
  );

  if (onClick) {
    return (
      <button
        type="button"
        className={className}
        onClick={onClick}
        onContextMenu={onContextMenu}
        aria-pressed={cell.done}
      >
        {inner}
      </button>
    );
  }
  return <div className={className}>{inner}</div>;
}
