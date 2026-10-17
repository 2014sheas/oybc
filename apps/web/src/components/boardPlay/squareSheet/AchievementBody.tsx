import { RisoButton } from '../../riso';
import styles from './SquareSheet.module.css';

export interface AchievementBodyProps {
  /** "Watching" / "Done". */
  statusLabel: string;
  /** "Core · monthly"; absent for a non-core board. */
  timeframeLabel: string | null;
  /** "14 days left"; absent when open-ended or over. */
  daysLeft: string | null;
  /** The watched board's (or template's) name; "Board unavailable" when gone. */
  watchedName: string;
  /** "0 / 1 bingo" / "Greenlog" / "2 / 3". */
  progress: string;
  /** Open the watched board; absent when there is no single board to open. */
  onOpenBoard?: () => void;
}

/**
 * The Achievement square's sheet body: the watched-board card and a gold
 * `Open ‹board›` button (no manual completion). The closest-line row is PR 4.
 *
 * @returns The body.
 */
export function AchievementBody(p: AchievementBodyProps): React.ReactElement {
  return (
    <>
      <div className={styles.watchRow}>
        <span className={styles.closedBadge}>{p.statusLabel}</span>
      </div>
      <div className={styles.watchCard}>
        <div className={styles.watchTop}>
          <span className={styles.watchEyebrow}>Watched board</span>
          {p.timeframeLabel && (
            <span className={styles.timeframeBadge}>{p.timeframeLabel}</span>
          )}
          {p.daysLeft && <span className={styles.daysLeft}>{p.daysLeft}</span>}
        </div>
        <div className={styles.watchBottom}>
          <span className={styles.watchName}>{p.watchedName}</span>
          <span className={styles.watchProgress}>{p.progress}</span>
        </div>
      </div>
      {p.onOpenBoard && (
        <RisoButton kind="gold" fullWidth onClick={p.onOpenBoard}>
          {`Open ${p.watchedName}`}
        </RisoButton>
      )}
    </>
  );
}
