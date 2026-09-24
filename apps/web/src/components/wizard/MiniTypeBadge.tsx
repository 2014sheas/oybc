import styles from './PoolRowEditor.module.css';

/** The three task kinds the inline editors badge. Achievement never reaches
 *  them (read-only in the pool, no pencil). */
export type MiniBadgeType = 'normal' | 'counting' | 'compound';

/** Single-letter type indicator (N / C / K) — matches the design handoff's
 *  compact badge vocabulary (`BADGE` map in the prototype), distinct from
 *  `TypeBadge`'s 4-letter list-row abbreviation. */
const MINI_BADGE: Record<MiniBadgeType, { letter: string; className: string }> = {
  normal: { letter: 'N', className: styles.miniBadgeNormal },
  counting: { letter: 'C', className: styles.miniBadgeCounting },
  compound: { letter: 'K', className: styles.miniBadgeCompound },
};

/**
 * MiniTypeBadge — the N/C/K square used in the inline editor header
 * (`size="header"`) and on each sub-task card (`size="sub"`).
 *
 * @param type - Which task kind to badge.
 * @param size - `header` (26px) or `sub` (30px).
 */
export function MiniTypeBadge({ type, size }: { type: MiniBadgeType; size: 'header' | 'sub' }): React.ReactElement {
  const meta = MINI_BADGE[type];
  return (
    <span className={`${styles.miniBadge} ${size === 'header' ? styles.miniBadgeHeader : styles.miniBadgeSub} ${meta.className}`}>
      {meta.letter}
    </span>
  );
}
