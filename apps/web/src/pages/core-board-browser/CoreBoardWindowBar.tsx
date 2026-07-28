import { compactStreakLabel, Timeframe } from '@oybc/shared';
import { RisoIcon } from '../../components/riso/RisoIcon';
import styles from './CoreBoardBrowserPage.module.css';

export interface CoreBoardWindowBarProps {
  /** e.g. "Today", "Week of May 18 – 24, 2026". */
  label: string;
  onPrev: () => void;
  onNext: () => void;
  /** Opens the full vertical window browser for this timeframe. */
  onOpenList: () => void;
  /**
   * Current greenlog streak for this timeframe. 0 (or omitted) hides the
   * flame chip. The compact label ("3d", "2w", …) and VoiceOver annotation
   * are both derived from `streakCount` + `timeframe`.
   * Mirrors the `streakCount`/`streakTimeframe` props on iOS
   * `CoreBoardWindowBarView`.
   */
  streakCount?: number;
  /** Timeframe whose streak to show — controls the compact label suffix. */
  timeframe?: Timeframe;
}

/**
 * Human word for VoiceOver (e.g. "weekly"), so the chip reads
 * "3 weekly greenlog streak" rather than the letter-by-letter "3w".
 */
function streakA11yWord(timeframe: Timeframe | undefined): string {
  switch (timeframe) {
    case Timeframe.DAILY:   return 'daily';
    case Timeframe.WEEKLY:  return 'weekly';
    case Timeframe.MONTHLY: return 'monthly';
    case Timeframe.YEARLY:  return 'yearly';
    default:                return '';
  }
}

/**
 * CoreBoardWindowBar — top chrome for the per-window core-board pager:
 * ‹ prev · window label (+ optional streak chip) · List ›  · next ›.
 * Prev/next are always enabled (paging is unbounded both ways).
 *
 * The optional gold flame chip mirrors the iOS `streakChip` private view
 * on `CoreBoardWindowBarView` — shown when `streakCount >= 1`.
 */
export function CoreBoardWindowBar({
  label,
  onPrev,
  onNext,
  onOpenList,
  streakCount = 0,
  timeframe,
}: CoreBoardWindowBarProps): React.ReactElement {
  const showChip = streakCount >= 1 && timeframe !== undefined;

  return (
    <div className={styles.windowBar}>
      <button
        type="button"
        className={styles.windowNav}
        onClick={onPrev}
        aria-label="Previous window"
      >
        ‹
      </button>

      {/* Center: label + optional streak chip */}
      <div className={styles.windowBarCenter}>
        <span className={styles.windowBarLabel}>{label}</span>
        {showChip && (
          <span
            className={styles.streakChip}
            aria-label={`${streakCount} ${streakA11yWord(timeframe)} greenlog streak`}
          >
            <span className={styles.streakChipFlame} aria-hidden="true">
              <RisoIcon name="flame" size={10} />
            </span>
            <span className={styles.streakChipLabel}>
              {compactStreakLabel(streakCount, timeframe!)}
            </span>
          </span>
        )}
      </div>

      <button
        type="button"
        className={styles.windowListButton}
        onClick={onOpenList}
        aria-label="Show all windows"
      >
        ≡ List
      </button>
      <button
        type="button"
        className={styles.windowNav}
        onClick={onNext}
        aria-label="Next window"
      >
        ›
      </button>
    </div>
  );
}
