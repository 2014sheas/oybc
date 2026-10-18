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
  /** The watched board's closest unfinished line: cells in reading order, gold when done. */
  closestLine?: { done: number; cells: boolean[] };
  /** Open the watched board; absent when there is no single board to open. */
  onOpenBoard?: () => void;
  /** Beside Open ‹board› (Task Detail's Edit). */
  trailing?: React.ReactNode;
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
        {p.closestLine && (
          <div className={styles.lineRow}>
            <span className={styles.lineLabel}>{`Closest line · ${p.closestLine.done} of ${p.closestLine.cells.length}`}</span>
            <span className={styles.lineCells} aria-hidden="true">
              {p.closestLine.cells.map((on, i) => (
                <span key={i} className={`${styles.lineCell} ${on ? styles.lineCellDone : ''}`} />
              ))}
            </span>
          </div>
        )}
      </div>
      {(p.onOpenBoard || p.trailing) && (
        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          {p.onOpenBoard && (
            <div style={{ flex: 1 }}>
              <RisoButton kind="gold" fullWidth onClick={p.onOpenBoard}>
                {`Open ${p.watchedName}`}
              </RisoButton>
            </div>
          )}
          {p.trailing}
        </div>
      )}
    </>
  );
}
