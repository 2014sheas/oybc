import { RisoIcon } from '../riso';
import styles from './Home.module.css';

export interface StreakPillProps {
  /** Number of consecutive achieved windows (the daily greenlog streak). */
  count: number;
  /** Unit label, defaults to "day streak". */
  label?: string;
}

/**
 * Gold streak pill — flame + count + label. The count is computed by the
 * shared streaks engine (`computeStreak`) from the user's core boards.
 * Reusable on the Profile streaks surface (Phase 5).
 */
export function StreakPill({ count, label = 'day streak' }: StreakPillProps): React.ReactElement {
  return (
    <div className={styles.streakPill}>
      <span className={styles.spFlame}>
        <RisoIcon name="flame" />
      </span>
      <span className={styles.spNum}>{count}</span>
      <span className={styles.spLbl}>{label}</span>
    </div>
  );
}
