import styles from './PoolRowEditor.module.css';

/** The three task kinds the inline editors badge. Achievement never reaches
 *  them (read-only in the pool, no pencil). */
export type MiniBadgeType = 'normal' | 'counting' | 'compound';

/** Single-letter type indicator (N / # / C) — the same letters as the iOS
 *  kit's `RisoTypeBadge(.letterSquare)` (normal N, counting #, compound C),
 *  so a sub-task card reads the same on both platforms. Distinct from
 *  `TypeBadge`'s 4-letter list-row abbreviation. */
const MINI_BADGE: Record<MiniBadgeType, { letter: string; className: string }> = {
  normal: { letter: 'N', className: styles.miniBadgeNormal },
  counting: { letter: '#', className: styles.miniBadgeCounting },
  compound: { letter: 'C', className: styles.miniBadgeCompound },
};

/**
 * MiniTypeBadge — the N/#/C square used in the inline editor header
 * (`size="header"`) and on each sub-task card (`size="sub"`).
 *
 * @param type - Which task kind to badge.
 * @param size - `header` (26px) or `sub` (30px).
 * @param label - Accessible name (e.g. "Counting sub-task"); omitted ⇒ the
 *   badge is decorative (the header already spells the type out).
 */
export function MiniTypeBadge({
  type,
  size,
  label,
}: {
  type: MiniBadgeType;
  size: 'header' | 'sub';
  label?: string;
}): React.ReactElement {
  const meta = MINI_BADGE[type];
  return (
    <span
      className={`${styles.miniBadge} ${size === 'header' ? styles.miniBadgeHeader : styles.miniBadgeSub} ${meta.className}`}
      {...(label ? { role: 'img', 'aria-label': label } : { 'aria-hidden': true })}
    >
      {meta.letter}
    </span>
  );
}
