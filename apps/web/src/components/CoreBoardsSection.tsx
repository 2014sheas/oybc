import { Timeframe, type CoreBoardSlot } from '@oybc/shared';
import styles from './CoreBoardsSection.module.css';

const TIMEFRAME_DISPLAY: Record<Timeframe, { icon: string; label: string }> = {
  [Timeframe.YEARLY]: { icon: '🎯', label: 'Yearly' },
  [Timeframe.MONTHLY]: { icon: '📆', label: 'Monthly' },
  [Timeframe.WEEKLY]: { icon: '🗓', label: 'Weekly' },
  [Timeframe.DAILY]: { icon: '📅', label: 'Daily' },
  [Timeframe.CUSTOM]: { icon: '📌', label: 'Custom' }, // unreachable — section only renders recurring TFs
};

export interface CoreBoardsSectionProps {
  /** Output of `useCoreBoardSlots(userId)`. One entry per enabled
   *  recurring timeframe, daily-first. */
  slots: CoreBoardSlot[];
  /** Tap target for a Not-Yet row's Create button. Parent decides what
   *  to do — the Boards-tab consumer hops cross-tab via URL param;
   *  the Create-tab consumer enters wizard mode in place. */
  onCreate: (slot: CoreBoardSlot) => void;
  /** Tap target for a Done row's main click area. Receives the
   *  currentBoard's id. Omitted on the Create-tab caller (Create
   *  surface doesn't navigate to play — that's the Boards tab's job). */
  onPlay?: (boardId: string) => void;
  /** Tap target for the per-row Browse button → opens the per-timeframe
   *  core-board browser. Omitted on the Create-tab caller (same reason). */
  onBrowse?: (timeframe: Timeframe) => void;
}

/**
 * CoreBoardsSection — persistent home-screen section showing one row
 * per *enabled* recurring timeframe (daily/weekly/monthly/yearly).
 * Replaces the earlier "PendingCoreBoardsSection" which only rendered
 * when there were uncreated current-window boards.
 *
 * Each row shows the current window's status:
 *   - **Done** (`currentBoard != null`): timeframe label + window
 *     label + "Done" pill + clickable to open the board + Browse →.
 *   - **Not yet** (`currentBoard === null`): timeframe label + window
 *     label + "Not yet" pill + Create button + Browse →.
 *
 * No dismiss affordance — per-timeframe disable lives in Board
 * Preferences. That's the only path to silence a recurring prompt.
 *
 * Returns `null` when `slots.length === 0` (no recurring timeframes
 * enabled at all) so the parent doesn't render an empty heading.
 */
export function CoreBoardsSection({
  slots,
  onCreate,
  onPlay,
  onBrowse,
}: CoreBoardsSectionProps): React.ReactElement | null {
  if (slots.length === 0) return null;

  return (
    <section
      className={styles.section}
      aria-label="Core recurring boards"
    >
      <h2 className={styles.heading}>Core boards</h2>
      <div className={styles.cards}>
        {slots.map((slot) => {
          const display = TIMEFRAME_DISPLAY[slot.timeframe];
          const done = slot.currentBoard !== null;
          return (
            <div key={slot.timeframe} className={styles.card}>
              <div className={styles.icon} aria-hidden="true">
                {display.icon}
              </div>
              <div className={styles.label}>
                <span className={styles.timeframeLabel}>{display.label}</span>
                <span className={styles.windowLabel}>{slot.windowLabel}</span>
              </div>
              <span
                className={
                  done
                    ? `${styles.statusPill} ${styles.statusPillDone}`
                    : `${styles.statusPill} ${styles.statusPillNotYet}`
                }
              >
                {done ? 'Done' : 'Not yet'}
              </span>
              <div className={styles.actions}>
                {done ? (
                  <button
                    type="button"
                    className={styles.playButton}
                    onClick={() =>
                      slot.currentBoard && onPlay?.(slot.currentBoard.id)
                    }
                    disabled={onPlay === undefined}
                    aria-label={`Open ${display.label} board`}
                  >
                    Play
                  </button>
                ) : (
                  <button
                    type="button"
                    className={styles.createButton}
                    onClick={() => onCreate(slot)}
                  >
                    Create
                  </button>
                )}
                {onBrowse && (
                  <button
                    type="button"
                    className={styles.browseButton}
                    onClick={() => onBrowse(slot.timeframe)}
                    aria-label={`Browse ${display.label} core boards`}
                  >
                    Browse →
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}
