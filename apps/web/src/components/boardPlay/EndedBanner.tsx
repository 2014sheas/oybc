import styles from '../../pages/BoardPlayPage.module.css';

export interface EndedBannerProps {
  /** The board's `endDate` (ISO8601), or `undefined`/`null` for an
   *  unparseable value (shows "unknown date", matching the retired
   *  `expiredBanner` copy). */
  endDate?: string | null;
}

/** "Sep 30" — no year, matching the stat card's date format (D14). */
function formatBannerDate(iso: string): string {
  const date = new Date(iso);
  if (isNaN(date.getTime())) return 'unknown date';
  return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

/**
 * EndedBanner — Board Edit redesign slice 4 (D14): the red-keyline banner
 * shown above the grid for an ENDED (not yet closed) board. Replaces the
 * old `expiredBanner` "Board expired on…" copy (only shown while
 * `!isSealed`; a CLOSED board shows no banner — its pill + stat card say
 * enough).
 *
 * Verbatim copy (handoff README, decisions §2): "Board ended on {date}.
 * Still logging until you close it." `{date}` matches the stat card's
 * format ("Sep 30").
 */
export function EndedBanner({ endDate }: EndedBannerProps): React.ReactElement {
  const date = endDate ? formatBannerDate(endDate) : 'unknown date';
  return (
    <div className={styles.expiredBanner}>
      Board ended on {date}. Still logging until you close it.
    </div>
  );
}
