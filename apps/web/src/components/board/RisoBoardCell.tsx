import { formatCount, type CountKind } from '@oybc/shared';
import { RisoIcon } from '../riso';
import { cellCountFit } from './cellModel';
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
  /** Counting progress, when `type === 'counting'` — `kind` is the counter family's. */
  count?: { cur: number; max: number; kind: CountKind };
  /** FREE/auto center square (inked, gold star, not a real task). */
  isFree: boolean;
  /** Part of a completed bingo line (gold ring). */
  isLine: boolean;
  /**
   * When true, renders a two-dot shared-counter marker on the cell corner
   * (only while not done). Set for COUNTING tasks that are either a shared-
   * counter source or a linked derived counter, and for a task of ANY type
   * that counts toward a counter (docs/SHARED_COUNTER_SETTINGS.md §3d).
   */
  isShared?: boolean;
  /**
   * When true, the cell pulses (`arriveGlow`, 2 iterations) — set for the
   * squares that just "arrived" from a shared-counter log made elsewhere
   * (Shared Counters P3). Purely a transient highlight; clears on auto-dismiss.
   */
  isArrived?: boolean;
  /**
   * Board Edit redesign slice 1 — per-square lock (`BoardTask.isLocked`).
   * Draws the red corner lock chip whenever the board is drawn, editing or
   * not: a locked square never moves (Shuffle and drags skip it) but stays
   * completable.
   */
  locked?: boolean;
  /**
   * Staged, unsaved edit on this square (edit mode only) — the gold pencil
   * chip. Lock beats dirty when both apply.
   */
  dirty?: boolean;
}

export interface RisoBoardCellProps {
  cell: BoardCellModel;
  /** When provided, the cell becomes an interactive button (Phase 3b play). */
  onClick?: () => void;
  /** Right-click / long-press → the play board's context menu (Phase 3b). */
  onContextMenu?: (e: React.MouseEvent) => void;
  /** Optional corner badge (e.g. an ACHIEVEMENT-watch indicator). */
  badge?: React.ReactNode;
  /** The cell's edge in px — picks the counting bar's text tier. Defaults to 88. */
  cellSize?: number;
}

/**
 * A single read-only Riso board cell — colored by type, halftone + gold check
 * when done, counting bar for counters, FREE center, gold ring on bingo lines.
 * Presentational only; `onClick` (Phase 3b) makes it an interactive button,
 * `onContextMenu` wires the play board's context menu, and `badge` renders a
 * corner indicator (achievement watch).
 */
export function RisoBoardCell({ cell, onClick, onContextMenu, badge, cellSize = 88 }: RisoBoardCellProps): React.ReactElement {
  const tagClass = cell.type === 'counting' ? styles.counting : cell.type === 'compound' ? styles.compound : '';
  const className = [
    styles.cell,
    cell.isFree ? styles.free : tagClass,
    cell.done && !cell.isFree ? styles.done : '',
    cell.isLine ? styles.line : '',
    cell.isArrived ? styles.arrived : '',
    cell.locked || cell.dirty ? styles.hasChip : '',
    onClick ? styles.interactive : '',
  ]
    .filter(Boolean)
    .join(' ');

  // Corner chips: lock (red) + dirty (gold), SIDE BY SIDE when both apply
  // (Board Edit redesign slice 3, D12 — adopts iOS's HStack; a replaced
  // locked square must show BOTH "this is locked" and "this is unsaved").
  // Pencil renders first, then lock (matches iOS `RisoBoardPlayCell.swift`).
  const chip = (cell.locked || cell.dirty) ? (
    <span className={styles.chipRow}>
      {cell.dirty && (
        <span className={`${styles.chip} ${styles.chipDirty}`} aria-label="Unsaved edit" role="img">
          <RisoIcon name="edit" size={12} />
        </span>
      )}
      {cell.locked && (
        <span className={`${styles.chip} ${styles.chipLock}`} aria-label="Locked in place" role="img">
          <RisoIcon name="lock" size={12} />
        </span>
      )}
    </span>
  ) : null;

  const inner = cell.isFree ? (
    <>
      <span className={styles.freeStar} aria-hidden="true" />
      <span className={styles.freeLabel}>{cell.label}</span>
      {chip}
    </>
  ) : (
    <>
      {badge}
      {chip}
      {!cell.done && cell.isShared && (
        <span className={styles.sharedMarker} aria-hidden="true">
          <i /><i />
        </span>
      )}
      {(cell.type === 'counting' || cell.type === 'compound') && (
        <span className={`${styles.tag} ${cell.type === 'counting' ? styles.counting : styles.compound}`}>
          {cell.type === 'counting' && cell.count ? `×${formatCount(cell.count.max, cell.count.kind)}` : '≡'}
        </span>
      )}
      <span className={styles.cellText}>{cell.label}</span>
      {cell.type === 'counting' && cell.count && <CountBar count={cell.count} cellSize={cellSize} />}
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

/**
 * The counting bar: fill + the tiered `cur/max` → `cur` → nothing text. An
 * overshoot keeps its real value (never clamped) on a full GOLD fill.
 */
function CountBar({ count, cellSize }: { count: NonNullable<BoardCellModel['count']>; cellSize: number }): React.ReactElement {
  const over = count.max > 0 && count.cur > count.max;
  const fit = cellCountFit(count.cur, count.max, count.kind, cellSize);
  const pct = count.max > 0 ? Math.min(100, Math.round((count.cur / count.max) * 100)) : 0;
  return (
    <span className={over ? `${styles.cbar} ${styles.over}` : styles.cbar}>
      <i style={{ width: `${pct}%` }} />
      {fit.tier !== 'none' && <span>{fit.text}</span>}
    </span>
  );
}
