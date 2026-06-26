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
}

export interface RisoBoardCellProps {
  cell: BoardCellModel;
  /** When provided, the cell becomes an interactive button (Phase 3b play). */
  onClick?: () => void;
}

/**
 * A single read-only Riso board cell — colored by type, halftone + gold check
 * when done, counting bar for counters, FREE center, gold ring on bingo lines.
 * Presentational only; `onClick` (Phase 3b) makes it an interactive button.
 */
export function RisoBoardCell({ cell, onClick }: RisoBoardCellProps): React.ReactElement {
  const tagClass = cell.type === 'counting' ? styles.counting : cell.type === 'compound' ? styles.compound : '';
  const className = [
    styles.cell,
    cell.isFree ? styles.free : tagClass,
    cell.done && !cell.isFree ? styles.done : '',
    cell.isLine ? styles.line : '',
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
      <button type="button" className={className} onClick={onClick} aria-pressed={cell.done}>
        {inner}
      </button>
    );
  }
  return <div className={className}>{inner}</div>;
}
