import styles from './RecurringBadge.module.css';

/**
 * RecurringBadge — Small outline pill marking a board that was spawned
 * from a RecurringBoardTemplate (Phase 6.2). Rendered next to the
 * BoardStatusBadge on the Boards-list card and the board-play header.
 *
 * Provenance is orthogonal to status (a recurring board is still
 * ACTIVE/COMPLETED), so this is a separate outline tag rather than a
 * status variant — the ink keyline reads as "where it came from" without
 * colliding with any status fill. iOS twin: `RisoRecurringBadge`.
 */
export function RecurringBadge(): React.ReactElement {
  return <span className={styles.badge}>RECURRING</span>;
}
