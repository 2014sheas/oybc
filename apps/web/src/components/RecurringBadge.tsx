import styles from './RecurringBadge.module.css';

export interface RecurringBadgeProps {
  /**
   * P6 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
   * §Surfaces item 8) — when true, renders the muted "↻ PAUSED" variant
   * instead of "RECURRING". Same outline-pill shell (a variant of this
   * component, not a new one, per the locked design) — only the text +
   * color are muted.
   */
  paused?: boolean;
}

/**
 * RecurringBadge — Small outline pill marking a board that was spawned
 * from a RecurringBoardTemplate (Phase 6.2). Rendered next to the
 * BoardStatusBadge on the Boards-list card and the board-play header.
 *
 * Provenance is orthogonal to status (a recurring board is still
 * ACTIVE/COMPLETED), so this is a separate outline tag rather than a
 * status variant — the ink keyline reads as "where it came from" without
 * colliding with any status fill. iOS twin: `RisoRecurringBadge`.
 *
 * P6 adds a `paused` variant: same pill shell, muted border + text
 * (`--riso-muted` in place of `--riso-ink`) and "↻ PAUSED" copy, so a
 * paused repeating board's provenance tag visually recedes without a
 * whole new component.
 */
export function RecurringBadge({ paused = false }: RecurringBadgeProps): React.ReactElement {
  if (paused) {
    return <span className={`${styles.badge} ${styles.badgePaused}`}>↻ PAUSED</span>;
  }
  return <span className={styles.badge}>RECURRING</span>;
}
