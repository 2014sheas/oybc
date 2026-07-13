import { Timeframe, type CoreBoardSlot } from '@oybc/shared';
import styles from './CoreBoardsSection.module.css';

const TIMEFRAME_DISPLAY: Record<Timeframe, { icon: string; label: string }> = {
  [Timeframe.YEARLY]: { icon: '🎯', label: 'Yearly' },
  [Timeframe.MONTHLY]: { icon: '📆', label: 'Monthly' },
  [Timeframe.WEEKLY]: { icon: '🗓', label: 'Weekly' },
  [Timeframe.DAILY]: { icon: '📅', label: 'Daily' },
  [Timeframe.CUSTOM]: { icon: '📌', label: 'Custom' }, // unreachable — section only renders recurring TFs
  [Timeframe.INDEFINITE]: { icon: '♾️', label: 'Ongoing' }, // unreachable — section only renders recurring TFs
};

export interface CoreBoardsSectionProps {
  /** Output of `useCoreBoardSlots(userId)`. One entry per enabled
   *  recurring timeframe, daily-first. */
  slots: CoreBoardSlot[];
  /** Tap target for a whole row. Parent decides where it navigates —
   *  the Boards-tab consumer pushes the per-timeframe Core Board
   *  Browser; the Create-tab consumer launches the wizard for today's
   *  window of that timeframe. Either way the row is a single tap
   *  target with no competing buttons. */
  onSelect: (slot: CoreBoardSlot) => void;
}

/**
 * CoreBoardsSection — persistent home-screen section showing one row
 * per *enabled* recurring timeframe (daily/weekly/monthly/yearly).
 *
 * Each row is a single tap target — clicking anywhere on it invokes
 * `onSelect(slot)`. The Boards-tab consumer wires this to push the
 * per-timeframe browser; the Create-tab consumer wires it to launch
 * the wizard for that timeframe's current window. No competing
 * buttons inside the row.
 *
 * No dismiss affordance — per-timeframe disable lives in Board
 * Preferences. That's the only path to silence a recurring prompt.
 *
 * Returns `null` when `slots.length === 0` (no recurring timeframes
 * enabled at all) so the parent doesn't render an empty heading.
 */
export function CoreBoardsSection({
  slots,
  onSelect,
}: CoreBoardsSectionProps): React.ReactElement | null {
  if (slots.length === 0) return null;

  return (
    <section
      className={styles.section}
      aria-label="Core recurring boards"
    >
      <h2 className={styles.heading}>Core boards</h2>
      <p className={styles.subtitle}>Your standard board for each time period.</p>
      <div className={styles.cards}>
        {slots.map((slot) => {
          const display = TIMEFRAME_DISPLAY[slot.timeframe];
          return (
            <button
              key={slot.timeframe}
              type="button"
              className={styles.card}
              onClick={() => onSelect(slot)}
            >
              <div className={styles.icon} aria-hidden="true">
                {display.icon}
              </div>
              <div className={styles.label}>
                <span className={styles.timeframeLabel}>{display.label}</span>
                <span className={styles.windowLabel}>{slot.windowLabel}</span>
              </div>
              <span className={styles.chevron} aria-hidden="true">›</span>
            </button>
          );
        })}
      </div>
    </section>
  );
}
